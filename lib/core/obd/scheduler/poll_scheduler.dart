import 'dart:async';
import 'dart:math' as math;

import '../bus/bus_priority.dart';
import '../jobs/job_definition.dart';
import '../models/sensor_reading.dart';
import '../obd_transport.dart';
import '../pid_constants.dart';

/// Reads one PID and returns its value, or null when the vehicle gave none.
typedef PidReader = Future<double?> Function(String pid, BusPriority priority);

/// Finds the job (period, priority) for a PID; null means "no definition".
typedef JobLookup = FutureOr<JobDefinition?> Function(String pid);

/// Tuning of the [PollScheduler].
class SchedulerConfig {
  const SchedulerConfig({
    this.maxQueriesPerSecond = 25,
    this.minGap = const Duration(milliseconds: 5),
    this.failureLimit = 5,
    this.suspendFor = const Duration(seconds: 60),
    this.fallbackPeriod = const Duration(seconds: 1),
  });

  /// Safety valve: never ask the adapter for more than this many readings per
  /// second on average (a short burst up to the same number is allowed).
  final int maxQueriesPerSecond;

  /// Pause after every reading, so the adapter is never hammered back to back.
  final Duration minGap;

  /// Consecutive failed reads of one PID before it is put on hold.
  final int failureLimit;

  /// How long a PID stays on hold before it is tried again.
  final Duration suspendFor;

  /// Period for a PID that has no job definition.
  final Duration fallbackPeriod;
}

/// A request for readings. Several can be active at once; a PID is read once
/// per period however many leases ask for it, and only while at least one does.
class PollLease {
  PollLease._(this._scheduler, this.owner);

  final PollScheduler _scheduler;
  final String owner;
  final Set<String> _pids = {};
  bool _active = true;

  bool get isActive => _active;

  /// The PID codes this lease currently asks for.
  Set<String> get pids => Set.unmodifiable(_pids);

  /// Replaces the set of PIDs this lease asks for.
  void update(Iterable<String> pids) {
    if (_active) _scheduler._updateLease(this, pids.toSet());
  }

  /// Stops asking for everything. Safe to call more than once.
  void cancel() {
    if (_active) _scheduler._cancelLease(this);
  }
}

/// Reads the requested PIDs on their schedule and publishes the values.
///
/// Rules:
///  * One reading at a time, always through [read] (the app passes the
///    command bus at low priority), so polling never blocks anything urgent.
///  * Each PID is read every `periodMs` of its job. Jobs that are due are
///    served by priority, then by how long they have been waiting. Fixed rate:
///    a PID that falls behind skips the cycles it missed instead of catching
///    up, and a PID never has more than one read outstanding, so nothing can
///    pile up.
///  * Pace: a short gap after every read and an overall cap on reads/second.
///  * A PID that fails [SchedulerConfig.failureLimit] times in a row (no data
///    or an error) is put on hold for a while and then tried again.
///  * When the transport disconnects the scheduler PAUSES (it does not stop)
///    and carries on by itself once the transport is connected again.
///
/// Time and sleeping are injectable so tests can run on a virtual clock.
class PollScheduler {
  PollScheduler({
    required this.read,
    required this.transport,
    required this.lookupJob,
    this.config = const SchedulerConfig(),
    int Function()? nowMs,
    Future<void> Function(Duration)? sleep,
  })  : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)) {
    _tokens = config.maxQueriesPerSecond.toDouble();
    _lastRefill = _nowMs();
    _stateSub = transport.stateStream.listen((_) => _poke());
  }

  final PidReader read;
  final ObdTransport transport;
  final JobLookup lookupJob;
  final SchedulerConfig config;

  final int Function() _nowMs;
  final Future<void> Function(Duration) _sleep;

  /// Longest single sleep, so a wake-up that is missed costs at most this.
  static const _maxSleep = Duration(seconds: 1);

  final _readings = StreamController<SensorReading>.broadcast();
  final _tasks = <String, _Task>{};
  final _leases = <PollLease>{};
  StreamSubscription<Elm327State>? _stateSub;
  Completer<void> _wakeup = Completer<void>();
  bool _running = false;
  bool _disposed = false;

  late double _tokens;
  late int _lastRefill;

  int _readCount = 0;
  int _failureCount = 0;
  int _suspensionCount = 0;

  /// Every successful reading, from every active lease.
  Stream<SensorReading> get readings => _readings.stream;

  bool get isRunning => _running;
  int get readCount => _readCount;
  int get failureCount => _failureCount;
  int get suspensionCount => _suspensionCount;

  /// PID codes currently being polled.
  Set<String> get activePids => Set.unmodifiable(_tasks.keys);

  bool isSuspended(String pid) {
    final t = _tasks[pid];
    return t != null && t.suspendedUntil > _nowMs();
  }

  /// Starts polling [pids] (PID codes such as '0C') for as long as the lease
  /// stays active.
  PollLease request(Iterable<String> pids, {String owner = ''}) {
    final lease = PollLease._(this, owner);
    if (_disposed) {
      lease._active = false;
      return lease;
    }
    _leases.add(lease);
    _updateLease(lease, pids.toSet());
    return lease;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final lease in _leases) {
      lease._active = false;
      lease._pids.clear();
    }
    _leases.clear();
    _tasks.clear();
    _stateSub?.cancel();
    _stateSub = null;
    _poke();
    _readings.close();
  }

  // ---- leases and tasks ---------------------------------------------------

  void _updateLease(PollLease lease, Set<String> wanted) {
    final added = wanted.difference(lease._pids);
    final removed = lease._pids.difference(wanted);
    lease._pids
      ..clear()
      ..addAll(wanted);
    for (final pid in added) {
      _addRef(pid);
    }
    for (final pid in removed) {
      _release(pid);
    }
    _poke();
    _ensureRunning();
  }

  void _cancelLease(PollLease lease) {
    _updateLease(lease, const {});
    lease._active = false;
    _leases.remove(lease);
  }

  void _addRef(String pid) {
    final task = _tasks.putIfAbsent(pid, () {
      final t = _Task(pid);
      unawaited(_resolve(t));
      return t;
    });
    task.refs++;
  }

  void _release(String pid) {
    final task = _tasks[pid];
    if (task == null) return;
    task.refs--;
    if (task.refs <= 0) _tasks.remove(pid);
  }

  Future<void> _resolve(_Task task) async {
    JobDefinition? job;
    try {
      job = await lookupJob(task.pid);
    } catch (_) {}
    job ??= JobDefinition(
      pid: task.pid,
      periodMs: config.fallbackPeriod.inMilliseconds,
    );
    if (_tasks[task.pid] != task) return; // released while looking it up
    task.job = job;
    task.nextDue = _nowMs();
    _poke();
  }

  // ---- the loop -----------------------------------------------------------

  void _ensureRunning() {
    if (_running || _disposed || _tasks.isEmpty) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      while (!_disposed && _tasks.isNotEmpty) {
        if (_wakeup.isCompleted) _wakeup = Completer<void>();

        if (!transport.isConnected) {
          await _wakeup.future; // paused until the link changes
          continue;
        }

        final now = _nowMs();
        _refill(now);

        _Task? pick;
        int? nextEvent;
        for (final t in _tasks.values) {
          if (t.job == null) continue; // still being looked up: poke will come
          final ready = math.max(t.nextDue, t.suspendedUntil);
          if (ready <= now) {
            if (pick == null || _serveBefore(t, pick)) pick = t;
          } else {
            nextEvent = nextEvent == null ? ready : math.min(nextEvent, ready);
          }
        }

        if (pick == null) {
          if (nextEvent == null) {
            await _wakeup.future;
          } else {
            await _sleepOrWake(Duration(milliseconds: nextEvent - now));
          }
          continue;
        }

        if (_tokens < 1) {
          await _sleepOrWake(const Duration(milliseconds: 2));
          continue;
        }
        _tokens -= 1;

        await _readOnce(pick);

        if (config.minGap > Duration.zero) await _sleepOrWake(config.minGap);
      }
    } finally {
      _running = false;
    }
  }

  /// Priority first, then the one that has waited longest, then the faster
  /// job, then PID, so the order is always the same.
  bool _serveBefore(_Task a, _Task b) {
    final pa = a.job!.priority;
    final pb = b.job!.priority;
    if (pa != pb) return pa > pb;
    if (a.nextDue != b.nextDue) return a.nextDue < b.nextDue;
    final fa = a.job!.periodMs;
    final fb = b.job!.periodMs;
    if (fa != fb) return fa < fb;
    return a.pid.compareTo(b.pid) < 0;
  }

  void _refill(int now) {
    final rate = config.maxQueriesPerSecond.toDouble();
    final earned = (now - _lastRefill) / 1000.0 * rate;
    _tokens = math.min(rate, _tokens + earned);
    _lastRefill = now;
  }

  Future<void> _readOnce(_Task task) async {
    final job = task.job!;
    double? value;
    var failed = false;
    try {
      value = await read(task.pid, BusPriority.low);
      failed = value == null;
    } catch (_) {
      failed = true;
    }
    final finished = _nowMs();

    if (_tasks[task.pid] != task) return; // released while reading

    if (!failed) {
      task.failures = 0;
      _readCount++;
      if (!_readings.isClosed) {
        _readings.add(SensorReading(
          pid: task.pid,
          value: value!,
          unit: PidConstants.unitFor(task.pid),
          timestamp: DateTime.fromMillisecondsSinceEpoch(finished),
        ));
      }
    } else if (transport.isConnected) {
      // With the link down the failure is the link's, not this PID's.
      task.failures++;
      _failureCount++;
      if (task.failures >= config.failureLimit) {
        task.failures = 0;
        task.suspendedUntil = finished + config.suspendFor.inMilliseconds;
        _suspensionCount++;
      }
    }

    task.nextDue = _nextDue(task.nextDue, job.periodMs, finished);
  }

  /// Fixed rate: the next slot after [now] on the grid `due + n * period`.
  static int _nextDue(int due, int period, int now) {
    final next = due + period;
    if (next > now) return next;
    final missed = (now - due) ~/ period;
    return due + (missed + 1) * period;
  }

  Future<void> _sleepOrWake(Duration wait) async {
    if (wait <= Duration.zero) return;
    final d = wait > _maxSleep ? _maxSleep : wait;
    await Future.any<void>([_sleep(d), _wakeup.future]);
  }

  void _poke() {
    if (!_wakeup.isCompleted) _wakeup.complete();
  }
}

class _Task {
  _Task(this.pid);

  final String pid;
  JobDefinition? job;
  int refs = 0;
  int nextDue = 0;
  int suspendedUntil = 0;
  int failures = 0;
}
