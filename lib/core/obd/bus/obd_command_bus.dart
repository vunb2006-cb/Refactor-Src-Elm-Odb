import 'dart:async';

import '../obd_transport.dart';
import 'bus_priority.dart';

/// The queue was full, so the command was refused (the adapter cannot keep up).
class BusQueueFullException implements Exception {
  BusQueueFullException(this.maxQueue);

  final int maxQueue;

  @override
  String toString() =>
      'BusQueueFullException: $maxQueue commands are already waiting';
}

/// One door to the adapter for every part of the app.
///
/// Wraps an [ObdTransport] and sends ONE command at a time, always picking the
/// most urgent waiting one ([BusPriority]). It is itself an [ObdTransport], so
/// code that only knows `sendCommand` keeps working (at normal priority);
/// code that cares calls [send] with a priority.
///
/// The queue is bounded: when [maxQueue] commands are waiting, new ones are
/// refused with [BusQueueFullException]. A command that waits longer than its
/// level allows fails with a [TimeoutException] and is never sent late.
///
/// The bus does not own the transport: [dispose] fails the waiting commands
/// but leaves the transport alone.
class ObdCommandBus implements ObdTransport {
  ObdCommandBus(
    this._transport, {
    this.maxQueue = 100,
    Map<BusPriority, Duration>? waitTimeouts,
  }) : _waitTimeouts = {
          for (final p in BusPriority.values)
            p: waitTimeouts?[p] ?? p.defaultWaitTimeout,
        };

  final ObdTransport _transport;
  final int maxQueue;
  final Map<BusPriority, Duration> _waitTimeouts;

  final List<_Request> _queue = [];
  bool _draining = false;
  bool _disposed = false;
  int _seq = 0;

  Duration? _averageLatency;
  int _completed = 0;
  int _failed = 0;
  int _rejected = 0;
  int _expired = 0;

  /// Commands waiting (not counting the one being sent).
  int get queueLength => _queue.length;

  /// Moving average of the time the adapter takes to answer a command; null
  /// until the first one finishes.
  Duration? get averageLatency => _averageLatency;

  int get completedCount => _completed;
  int get failedCount => _failed;
  int get rejectedCount => _rejected;
  int get expiredCount => _expired;

  /// Sends [cmd] when it is its turn and returns the adapter's reply.
  ///
  /// Fails at once if the transport is not connected, so nothing piles up
  /// during an outage.
  Future<String> send(
    String cmd, {
    BusPriority priority = BusPriority.normal,
    Duration? waitTimeout,
  }) {
    if (_disposed) return Future.error(StateError('ELM327 bus disposed'));
    if (!_transport.isConnected) {
      return Future.error(StateError('ELM327 not connected'));
    }
    if (_queue.length >= maxQueue) {
      _rejected++;
      return Future.error(BusQueueFullException(maxQueue));
    }

    final request = _Request(cmd, priority, _seq++);
    final limit = waitTimeout ?? _waitTimeouts[priority]!;
    request.timer = Timer(limit, () => _expire(request, limit));
    _insert(request);
    _drain();
    return request.completer.future;
  }

  void _insert(_Request request) {
    // After everything of the same or higher rank: urgent first, FIFO within.
    var i = _queue.length;
    while (i > 0 && _queue[i - 1].priority.rank < request.priority.rank) {
      i--;
    }
    _queue.insert(i, request);
  }

  void _expire(_Request request, Duration limit) {
    if (!_queue.remove(request)) return; // already being sent
    _expired++;
    request.completer.completeError(
      TimeoutException(
        'ELM327 bus: "${request.cmd}" waited ${limit.inMilliseconds} ms '
        'in the queue',
        limit,
      ),
    );
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final request = _queue.removeAt(0);
        request.timer?.cancel();
        final watch = Stopwatch()..start();
        try {
          final reply = await _transport.sendCommand(request.cmd);
          _noteLatency(watch.elapsed);
          _completed++;
          request.completer.complete(reply);
        } catch (e, st) {
          _failed++;
          request.completer.completeError(e, st);
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _noteLatency(Duration sample) {
    final previous = _averageLatency;
    _averageLatency = previous == null
        ? sample
        : Duration(
            microseconds:
                (previous.inMicroseconds * 0.8 + sample.inMicroseconds * 0.2)
                    .round(),
          );
  }

  // ---- ObdTransport: everything else is the wrapped transport -----------

  @override
  Future<String> sendCommand(String cmd) => send(cmd);

  @override
  Stream<Elm327State> get stateStream => _transport.stateStream;

  @override
  Elm327State get state => _transport.state;

  @override
  bool get isConnected => _transport.isConnected;

  @override
  String? get lastConnectedAddress => _transport.lastConnectedAddress;

  @override
  Future<void> disconnect() => _transport.disconnect();

  /// Fails every waiting command. Does NOT dispose the wrapped transport.
  @override
  void dispose() {
    _disposed = true;
    for (final request in _queue) {
      request.timer?.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(StateError('ELM327 bus disposed'));
      }
    }
    _queue.clear();
  }
}

class _Request {
  _Request(this.cmd, this.priority, this.seq);

  final String cmd;
  final BusPriority priority;
  final int seq;
  final completer = Completer<String>();
  Timer? timer;
}
