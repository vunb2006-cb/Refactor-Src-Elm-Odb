import 'dart:async';
import 'dart:math' as math;

import '../elm_client.dart';
import 'reconnect_policy.dart';
import 'reconnect_status.dart';

/// Reconnects an [ElmClient] after a lost link, with backoff.
///
/// It only reacts to a link that WAS connected: a first connection that fails
/// is reported to the user as before, never retried behind their back. It
/// stops for good when `disconnect()` is called, when the policy says the
/// error is not retriable, or when the policy's time budget runs out.
///
/// It does not touch the polling code. Readers just see the transport come
/// back (`isConnected`) and carry on.
class ReconnectSupervisor {
  ReconnectSupervisor(
    this._client, {
    this.policy = const ReconnectPolicy(),
    this.onReconnected,
    DateTime Function()? clock,
    math.Random? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? math.Random();

  final ElmClient _client;
  final ReconnectPolicy policy;

  /// Called after every successful reconnect with the adapter address. Meant
  /// for checks such as "is this still the same vehicle?" (compare the VIN and
  /// probe again). Errors thrown by it are ignored.
  final FutureOr<void> Function(String address)? onReconnected;

  final DateTime Function() _clock;
  final math.Random _random;

  StreamSubscription<Elm327State>? _sub;
  final _statusController = StreamController<ReconnectStatus>.broadcast();
  ReconnectStatus _status = const ReconnectStatus();

  bool _armed = false; // a connection existed and was not closed on purpose
  bool _loopActive = false;
  int _loopSeq = 0;
  int _requestSnapshot = 0;
  Timer? _sleepTimer;
  Completer<void>? _sleepCompleter;

  ReconnectStatus get status => _status;
  Stream<ReconnectStatus> get statusStream => _statusController.stream;

  /// Starts watching the client. Safe to call more than once.
  void start() {
    _sub ??= _client.stateStream.listen(_onState);
    if (_client.state == Elm327State.connected) _armed = true;
  }

  /// Stops any pending reconnect and forgets the current connection.
  void cancel() {
    _armed = false;
    _abortLoop();
  }

  /// Starts an attempt right away, for a "Reconnect" button after giving up.
  void retryNow() {
    _abortLoop();
    _armed = true;
    _startLoop(immediate: true);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _abortLoop(report: false);
    _statusController.close();
  }

  // ---- reacting to the client ------------------------------------------

  void _onState(Elm327State s) {
    switch (s) {
      case Elm327State.connected:
        _armed = true;
      case Elm327State.connecting:
      case Elm327State.initializing:
        // A connect we did not start: someone else (the user) is taking over.
        if (_loopActive && _status.phase != ReconnectPhase.attempting) {
          _abortLoop();
        }
      case Elm327State.disconnected:
      case Elm327State.error:
        if (_loopActive) {
          // Our own attempt decides, unless the user asked to disconnect.
          if (_client.disconnectRequestCount != _requestSnapshot) {
            _armed = false;
            _abortLoop();
          }
          return;
        }
        if (!_armed) return;
        final reason = _client.lastDisconnectReason;
        if (reason == ElmDisconnectReason.requested) {
          _armed = false;
          return;
        }
        if (!policy.isRetriable(reason, _client.lastError)) {
          _armed = false;
          _setStatus(ReconnectStatus(
            phase: ReconnectPhase.gaveUp,
            giveUpReason: ReconnectGiveUpReason.fatalError,
            lastError: _client.lastError,
          ));
          return;
        }
        _startLoop(immediate: false);
    }
  }

  // ---- the reconnect loop ----------------------------------------------

  void _startLoop({required bool immediate}) {
    final address = _client.lastConnectedAddress;
    if (address == null) {
      _armed = false;
      _setStatus(const ReconnectStatus(
        phase: ReconnectPhase.gaveUp,
        giveUpReason: ReconnectGiveUpReason.noAddress,
      ));
      return;
    }
    _loopActive = true;
    _requestSnapshot = _client.disconnectRequestCount;
    unawaited(_runLoop(++_loopSeq, address, immediate));
  }

  Future<void> _runLoop(int seq, String address, bool immediate) async {
    final started = _clock();
    var attempt = 0;
    Object? lastError;

    bool live() => _loopActive && _loopSeq == seq;
    bool userRequested() => _client.disconnectRequestCount != _requestSnapshot;

    while (live()) {
      attempt++;

      if (_clock().difference(started) >= policy.giveUpAfter) {
        _giveUp(ReconnectGiveUpReason.timeExpired, lastError);
        return;
      }

      final Duration wait;
      if (immediate && attempt == 1) {
        wait = Duration.zero;
      } else {
        final n = immediate ? attempt - 1 : attempt;
        wait = policy.delayFor(n, _random.nextDouble());
      }
      _setStatus(ReconnectStatus(
        phase: ReconnectPhase.waiting,
        attempt: attempt,
        nextAttemptAt: _clock().add(wait),
        lastError: lastError,
      ));
      if (wait > Duration.zero) await _sleep(wait);
      if (!live()) return;
      if (userRequested()) {
        _armed = false;
        _endLoop();
        return;
      }

      _setStatus(ReconnectStatus(
        phase: ReconnectPhase.attempting,
        attempt: attempt,
        lastError: lastError,
      ));
      try {
        await _client.connect(address);
      } catch (e) {
        lastError = e;
      }
      if (!live()) return;
      if (userRequested()) {
        _armed = false;
        _endLoop();
        return;
      }

      if (_client.isConnected) {
        _armed = true;
        _endLoop();
        _notifyReconnected(address);
        return;
      }
      lastError = _client.lastError ?? lastError;
      if (!policy.isRetriable(_client.lastDisconnectReason, _client.lastError)) {
        _giveUp(ReconnectGiveUpReason.fatalError, lastError);
        return;
      }
    }
  }

  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    _sleepCompleter = c;
    _sleepTimer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final c = _sleepCompleter;
    _sleepCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Ends the loop without further status changes by the loop itself.
  void _abortLoop({bool report = true}) {
    final wasActive = _loopActive;
    _loopActive = false;
    _wake();
    if (wasActive && report) _setStatus(const ReconnectStatus());
  }

  void _endLoop() {
    _loopActive = false;
    _setStatus(const ReconnectStatus());
  }

  void _giveUp(ReconnectGiveUpReason reason, Object? error) {
    _loopActive = false;
    _armed = false;
    _setStatus(ReconnectStatus(
      phase: ReconnectPhase.gaveUp,
      giveUpReason: reason,
      lastError: error,
    ));
  }

  void _notifyReconnected(String address) {
    final cb = onReconnected;
    if (cb == null) return;
    unawaited(
      Future.sync(() => cb(address)).catchError((Object _) {}),
    );
  }

  void _setStatus(ReconnectStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }
}
