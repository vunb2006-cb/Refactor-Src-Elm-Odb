import 'dart:async';

import 'package:elm_obd2/core/obd/bus/bus_priority.dart';
import 'package:elm_obd2/core/obd/jobs/job_definition.dart';
import 'package:elm_obd2/core/obd/models/sensor_reading.dart';
import 'package:elm_obd2/core/obd/scheduler/poll_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import '../bus/manual_transport.dart';

/// Virtual time: sleeping advances the clock instantly, so a minute of
/// scheduling runs in a blink and the results are exact.
class _Clock {
  int t = 0;
  int now() => t;
  Future<void> sleep(Duration d) async {
    t += d.inMilliseconds;
    await Future<void>.delayed(Duration.zero);
  }
}

class _Read {
  _Read(this.pid, this.startedAt, this.priority);
  final String pid;
  final int startedAt;
  final BusPriority priority;
}

const _noLimits = SchedulerConfig(
  maxQueriesPerSecond: 1000,
  minGap: Duration.zero,
);

class _Rig {
  _Rig({
    Map<String, JobDefinition> jobs = const {},
    this.latencyMs = 0,
    SchedulerConfig config = _noLimits,
    this.values = const {},
    this.onRead,
    this.script,
  }) {
    transport = ManualTransport();
    scheduler = PollScheduler(
      read: _read,
      transport: transport,
      lookupJob: (pid) => jobs[pid],
      config: config,
      nowMs: clock.now,
      sleep: clock.sleep,
    );
    addTearDown(scheduler.dispose);
  }

  final clock = _Clock();
  final int latencyMs;

  /// pid to value; a pid mapped to null (or a thrown error) fails.
  final Map<String, double?> values;
  final void Function(String pid)? onRead;

  /// Replaces [values] when given: decides each read (return a value, return
  /// null for "no data", or throw).
  final Future<double?> Function(String pid)? script;
  late final ManualTransport transport;
  late final PollScheduler scheduler;
  final List<_Read> log = [];

  Future<double?> _read(String pid, BusPriority priority) async {
    log.add(_Read(pid, clock.t, priority));
    onRead?.call(pid);
    clock.t += latencyMs;
    await Future<void>.delayed(Duration.zero);
    if (script != null) return script!(pid);
    return values.containsKey(pid) ? values[pid] : 1.0;
  }

  List<int> times(String pid) =>
      [for (final r in log) if (r.pid == pid) r.startedAt];

  /// Lets the scheduler run until [done] holds.
  Future<void> until(bool Function() done, {int maxTurns = 400000}) async {
    for (var i = 0; i < maxTurns && !done(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (!done()) fail('the expected state was not reached');
  }

  Future<void> turns(int n) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

JobDefinition _job(String pid, int periodMs, {int priority = 0}) =>
    JobDefinition(pid: pid, periodMs: periodMs, priority: priority);

void main() {
  test('reads every PID on its own period', () async {
    final r = _Rig(jobs: {'0C': _job('0C', 100), '05': _job('05', 500)});
    r.scheduler.request({'0C', '05'});

    await r.until(() => r.clock.t >= 1000);

    expect(r.times('0C').take(5), [0, 100, 200, 300, 400]);
    expect(r.times('05').take(2), [0, 500]);
  });

  test('polling reads go out at low priority', () async {
    final r = _Rig(jobs: {'0C': _job('0C', 100)});
    r.scheduler.request({'0C'});

    await r.until(() => r.log.length >= 3);

    expect(r.log.every((e) => e.priority == BusPriority.low), isTrue);
  });

  test('when jobs are due together, the higher priority goes first', () async {
    final r = _Rig(jobs: {
      '0C': _job('0C', 1000, priority: 0),
      '0D': _job('0D', 1000, priority: 5),
    });
    r.scheduler.request({'0C', '0D'}); // asked for in this order

    await r.until(() => r.log.length >= 2);

    expect(r.log.map((e) => e.pid).take(2), ['0D', '0C']);
  });

  test('a PID that falls behind skips missed cycles instead of catching up',
      () async {
    final r = _Rig(jobs: {'0C': _job('0C', 100)}, latencyMs: 250);
    r.scheduler.request({'0C'});

    await r.until(() => r.times('0C').length >= 4);

    expect(r.times('0C').take(4), [0, 300, 600, 900]);
  });

  test('a PID without a job definition is read once a second', () async {
    final r = _Rig(jobs: const {});
    r.scheduler.request({'7A'});

    await r.until(() => r.times('7A').length >= 3);

    expect(r.times('7A').take(3), [0, 1000, 2000]);
  });

  test('publishes each value as a SensorReading', () async {
    final r = _Rig(jobs: {'0C': _job('0C', 100)}, values: {'0C': 1500.0});
    final got = <SensorReading>[];
    r.scheduler.readings.listen(got.add);
    r.scheduler.request({'0C'});

    await r.until(() => got.length >= 2);

    expect(got.first.pid, '0C');
    expect(got.first.value, 1500.0);
    expect(got.first.unit, 'RPM');
    expect(got.first.timestamp.millisecondsSinceEpoch, 0);
    expect(r.scheduler.readCount, greaterThanOrEqualTo(2));
  });

  group('leases', () {
    test('cancelling the only lease stops the scheduler', () async {
      final r = _Rig(jobs: {'0C': _job('0C', 100)});
      final lease = r.scheduler.request({'0C'});
      await r.until(() => r.log.length >= 3);

      lease.cancel();
      await r.until(() => !r.scheduler.isRunning);
      final seen = r.log.length;
      await r.turns(200);

      expect(r.log.length, seen);
      expect(r.scheduler.activePids, isEmpty);
      expect(lease.isActive, isFalse);
    });

    test('two leases for one PID read it once per period, and it stops only '
        'after both cancel', () async {
      final r = _Rig(jobs: {'0C': _job('0C', 100)});
      final a = r.scheduler.request({'0C'}, owner: 'a');
      final b = r.scheduler.request({'0C'}, owner: 'b');

      await r.until(() => r.times('0C').length >= 4);
      expect(r.times('0C').take(4), [0, 100, 200, 300]); // not doubled

      a.cancel();
      final afterA = r.times('0C').length;
      await r.until(() => r.times('0C').length >= afterA + 2);
      expect(r.scheduler.isRunning, isTrue);

      b.cancel();
      await r.until(() => !r.scheduler.isRunning);
    });

    test('update swaps the PIDs being read', () async {
      final r = _Rig(jobs: {'0C': _job('0C', 100), '0D': _job('0D', 100)});
      final lease = r.scheduler.request({'0C'});
      await r.until(() => r.times('0C').length >= 3);

      lease.update({'0D'});
      await r.until(() => r.times('0D').length >= 3);
      final cCount = r.times('0C').length;
      await r.turns(300);

      expect(r.times('0C').length, cCount); // no more 0C
      expect(lease.pids, {'0D'});
    });

    test('requesting after dispose gives an inactive lease', () async {
      final r = _Rig(jobs: {'0C': _job('0C', 100)});
      r.scheduler.dispose();

      final lease = r.scheduler.request({'0C'});
      await r.turns(50);

      expect(lease.isActive, isFalse);
      expect(r.log, isEmpty);
    });
  });

  group('connection', () {
    test('pauses while disconnected and resumes by itself', () async {
      final r = _Rig(jobs: {'0C': _job('0C', 100)});
      r.scheduler.request({'0C'});
      await r.until(() => r.log.length >= 3);

      r.transport.setConnected(false);
      await r.turns(30); // an in-flight read may still finish
      final paused = r.log.length;
      await r.turns(500);
      expect(r.log.length, paused);
      expect(r.scheduler.isRunning, isTrue); // paused, not stopped

      r.transport.setConnected(true);
      await r.until(() => r.log.length > paused + 2);
    });

    test('a failure while the link is down is not held against the PID',
        () async {
      late _Rig r;
      r = _Rig(
        jobs: {'0C': _job('0C', 100)},
        values: {'0C': null},
        onRead: (_) => r.transport.setConnected(false), // link drops mid-read
      );
      r.scheduler.request({'0C'});

      await r.until(() => r.log.isNotEmpty);
      await r.turns(50);

      expect(r.scheduler.failureCount, 0);
    });
  });

  group('failing PIDs', () {
    test('five failures in a row put the PID on hold for a minute, '
        'others keep going', () async {
      final r = _Rig(
        jobs: {'0A': _job('0A', 100), '0C': _job('0C', 100)},
        values: {'0A': null}, // the vehicle never answers 0A
      );
      r.scheduler.request({'0A', '0C'});

      await r.until(() => r.times('0A').length >= 6);

      final a = r.times('0A');
      expect(a.take(5), [0, 100, 200, 300, 400]);
      expect(a[5], 400 + 60000); // back after the hold
      expect(r.scheduler.suspensionCount, 1);
      // 0C was read all along, about every 100 ms for those 60 seconds.
      expect(r.times('0C').where((t) => t > 1000 && t < 59000).length,
          greaterThan(500));
    });

    test('an error counts as a failure too', () async {
      final r = _Rig(
        jobs: {'0A': _job('0A', 100)},
        script: (pid) async => throw StateError('no answer'),
      );
      r.scheduler.request({'0A'});

      await r.until(() => r.scheduler.suspensionCount == 1);

      expect(r.scheduler.isSuspended('0A'), isTrue);
      expect(r.scheduler.failureCount, 5);
    });

    test('a PID that answers again is not put on hold', () async {
      // Four failures, then it answers: it never reaches the limit of five.
      final answers = <double?>[null, null, null, null];
      final r = _Rig(
        jobs: {'0A': _job('0A', 100)},
        script: (pid) async => answers.isEmpty ? 7.0 : answers.removeAt(0),
      );
      r.scheduler.request({'0A'});

      await r.until(() => r.log.length >= 10);

      expect(r.scheduler.failureCount, 4);
      expect(r.scheduler.suspensionCount, 0);
      expect(r.scheduler.isSuspended('0A'), isFalse);
    });

    test('the failure count restarts after a success', () async {
      // null x4, ok, null x4, ok: nine failures but never five in a row.
      final answers = <double?>[
        null, null, null, null, 1.0, null, null, null, null, 1.0,
      ];
      final r = _Rig(
        jobs: {'0A': _job('0A', 100)},
        script: (pid) async => answers.isEmpty ? 1.0 : answers.removeAt(0),
      );
      r.scheduler.request({'0A'});

      await r.until(() => r.log.length >= 14);

      expect(r.scheduler.suspensionCount, 0);
    });
  });

  group('pacing', () {
    test('a short gap follows every read', () async {
      final r = _Rig(
        jobs: {'0C': _job('0C', 1000), '0D': _job('0D', 1000)},
        config: const SchedulerConfig(
          maxQueriesPerSecond: 1000,
          minGap: Duration(milliseconds: 5),
        ),
      );
      r.scheduler.request({'0C', '0D'});

      await r.until(() => r.log.length >= 2);

      expect(r.log.map((e) => e.startedAt).take(2), [0, 5]);
    });

    test('the overall rate is capped', () async {
      final jobs = {for (final p in ['01', '02', '03', '04', '05']) p: _job(p, 60)};
      final r = _Rig(
        jobs: jobs,
        config: const SchedulerConfig(
          maxQueriesPerSecond: 10,
          minGap: Duration.zero,
        ),
      );
      r.scheduler.request(jobs.keys);

      await r.until(() => r.clock.t >= 1000);

      final inFirstSecond = r.log.where((e) => e.startedAt <= 1000).length;
      expect(inFirstSecond, lessThanOrEqualTo(21)); // 10 burst + 10 refill
      expect(inFirstSecond, greaterThanOrEqualTo(15));
    });
  });

  test('dispose stops everything and closes the stream', () async {
    final r = _Rig(jobs: {'0C': _job('0C', 100)});
    var closed = false;
    r.scheduler.readings.listen((_) {}, onDone: () => closed = true);
    r.scheduler.request({'0C'});
    await r.until(() => r.log.length >= 3);

    r.scheduler.dispose();
    await r.until(() => !r.scheduler.isRunning);
    final seen = r.log.length;
    await r.turns(200);

    expect(r.log.length, seen);
    expect(closed, isTrue);
  });
}
