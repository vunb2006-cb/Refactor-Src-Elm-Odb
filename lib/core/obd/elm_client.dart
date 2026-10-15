import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'elm_init_profile.dart';
import 'elm_response.dart';
import 'elm_timeouts.dart';
import 'obd_transport.dart';
import 'transport/byte_transport.dart';

export 'elm_init_profile.dart';
export 'elm_response.dart';
export 'elm_timeouts.dart';
export 'obd_transport.dart';
export 'transport/byte_transport.dart';

/// Why an [ElmClient] last left the connected state. A reconnect supervisor
/// uses it to decide whether trying again makes sense.
enum ElmDisconnectReason {
  /// `disconnect()` was called (the user, or app shutdown).
  requested,

  /// The Bluetooth link closed or errored.
  linkLost,

  /// The adapter stopped answering (see the drain rules below).
  stalled,

  /// The link could not be opened.
  connectFailed,

  /// The link opened but the init sequence failed.
  initFailed,
}

/// ELM327 command layer: strictly serial command queue, `>` prompt framing,
/// per-command timeouts, a data-driven initialisation sequence and connection
/// state. It talks to the adapter only through a [ByteTransport] and
/// implements [ObdTransport], so `ObdService` and everything above it are
/// unchanged.
///
/// Reliability rules (group 4):
///  * After a command times out the adapter may still send its reply. The next
///    command is NOT written until that reply's `>` prompt arrives (or the
///    drain window [drainTimeout] expires), so a late reply can never be
///    mistaken for the answer to a later command.
///  * If no prompt arrives within [drainTimeout] the adapter is considered
///    stuck: pending commands fail, the link is closed and the state becomes
///    [Elm327State.error].
///  * Required init steps must be acknowledged with "OK"; a failed init closes
///    the link instead of leaving it open.
///  * Timeouts depend on the command (see [ElmTimeouts]).
///  * Disconnecting fails any pending commands instead of leaving them hanging.
class ElmClient implements ObdTransport {
  ElmClient(
    this._link, {
    this.initProfile = ElmInitProfile.standard,
    this.timeouts = const ElmTimeouts(),
    this.drainTimeout = const Duration(seconds: 4),
  });

  final ByteTransport _link;
  final ElmInitProfile initProfile;
  final ElmTimeouts timeouts;

  /// How long to wait for a late reply's prompt after a command timed out.
  final Duration drainTimeout;

  StreamSubscription<Uint8List>? _inputSub;

  final _stateController = StreamController<Elm327State>.broadcast();
  Elm327State _state = Elm327State.disconnected;

  // Strictly serial command queue.
  final _queue = Queue<_Cmd>();
  bool _busy = false;
  _Cmd? _active;
  final _buffer = StringBuffer();

  // Late-reply protection.
  bool _draining = false;
  Timer? _drainTimer;

  // False until an OBD (non-AT) command has returned without a protocol error;
  // the first one gets the long "detect" timeout.
  bool _protocolDetected = false;

  final _initLog = <ElmInitResult>[];

  String? _lastConnectedAddress;

  ElmDisconnectReason? _lastDisconnectReason;
  Object? _lastError;
  int _disconnectRequests = 0;

  @override
  Stream<Elm327State> get stateStream => _stateController.stream;
  @override
  Elm327State get state => _state;
  @override
  bool get isConnected => _state == Elm327State.connected;

  /// The address of the device we are currently (or were last) connected to.
  @override
  String? get lastConnectedAddress => _lastConnectedAddress;

  /// What the adapter answered to each init step of the last connection.
  List<ElmInitResult> get initLog => List.unmodifiable(_initLog);

  /// Why the client last left the connected state; null after a successful
  /// connect.
  ElmDisconnectReason? get lastDisconnectReason => _lastDisconnectReason;

  /// The error behind [lastDisconnectReason], when there was one.
  Object? get lastError => _lastError;

  /// How many times `disconnect()` has been called. A supervisor compares this
  /// with a snapshot to learn that someone asked to disconnect meanwhile.
  int get disconnectRequestCount => _disconnectRequests;

  /// Connects to [address] and runs the init profile.
  ///
  /// Safe to call after the app restarts: cleans up any stale link first.
  /// Retrying a failed link attempt is the transport's job. Throws
  /// [ElmInitException] when a required init step is not acknowledged.
  Future<void> connect(String address) async {
    if (_state == Elm327State.connecting ||
        _state == Elm327State.initializing ||
        _state == Elm327State.connected) {
      return;
    }

    _lastDisconnectReason = null;
    _lastError = null;
    final requestsAtStart = _disconnectRequests;

    // Tear down any stale link before opening a fresh one.
    await _forceCleanup();

    _lastConnectedAddress = address;
    _setState(Elm327State.connecting);

    try {
      await _link.connect(address);
    } catch (e) {
      if (_disconnectRequests == requestsAtStart) {
        _lastDisconnectReason = ElmDisconnectReason.connectFailed;
        _lastError = e;
      }
      _setState(Elm327State.error);
      rethrow;
    }

    try {
      _setState(Elm327State.initializing);
      _buffer.clear();
      _queue.clear();
      _busy = false;
      _active = null;
      _protocolDetected = false;
      _cancelDrain();

      _inputSub?.cancel();
      _inputSub = _link.incoming.listen(
        _onBytes,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
        cancelOnError: false,
      );

      await _init();
      _setState(Elm327State.connected);
    } catch (e) {
      await _forceCleanup(); // do not leave a half-initialised link open
      if (_disconnectRequests == requestsAtStart) {
        _lastDisconnectReason = ElmDisconnectReason.initFailed;
        _lastError = e;
      }
      _setState(Elm327State.error);
      rethrow;
    }
  }

  /// Tears down the subscription and the link; fails any pending commands.
  Future<void> _forceCleanup() async {
    _inputSub?.cancel();
    _inputSub = null;
    _cancelDrain();
    _failAll(StateError('ELM327 disconnected'));
    await _link.disconnect();
  }

  /// Send [cmd] to the ELM327 and return the response (everything before '>').
  @override
  Future<String> sendCommand(String cmd) => _enqueue(cmd, null);

  Future<String> _enqueue(String cmd, Duration? timeout) {
    if (!_link.isConnected) {
      throw StateError('ELM327 not connected');
    }
    final c = _Cmd(cmd, timeout);
    _queue.add(c);
    _pump();
    return c.completer.future;
  }

  void _pump() {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    final cmd = _queue.removeFirst();
    _active = cmd;
    _buffer.clear();
    _write('${cmd.cmd}\r');

    final limit = cmd.timeout ??
        timeouts.forCommand(cmd.cmd, protocolDetected: _protocolDetected);
    cmd.timer = Timer(limit, () {
      if (!identical(_active, cmd)) return;
      if (!cmd.completer.isCompleted) {
        cmd.completer.completeError(
          TimeoutException('ELM327 timeout: ${cmd.cmd}', limit),
        );
      }
      _active = null;
      _startDrain(); // stay busy until the late reply's prompt arrives
    });
  }

  void _onBytes(Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);

    if (_draining) {
      // Everything up to and including the prompt belongs to the command that
      // already timed out: throw it away.
      if (text.contains('>')) _endDrain();
      return;
    }

    _buffer.write(text);
    final raw = _buffer.toString();
    if (!raw.contains('>')) return;

    final response = raw.replaceAll('>', '').trim();
    _buffer.clear();

    final a = _active;
    if (a != null) {
      a.timer?.cancel();
      if (!a.isAt &&
          !_protocolDetected &&
          replyShowsProtocolUp(classifyElmReply(response))) {
        _protocolDetected = true;
      }
      if (!a.completer.isCompleted) a.completer.complete(response);
      _active = null;
    }
    _busy = false;
    _pump();
  }

  void _write(String s) {
    _link.write(Uint8List.fromList(utf8.encode(s)));
  }

  Future<void> _init() async {
    _initLog.clear();
    for (final step in initProfile.steps) {
      final response = await _enqueue(step.command, step.timeout);
      final ok = classifyElmReply(response) == ElmReplyKind.ok;
      _initLog.add(ElmInitResult(step.command, response, ok));
      if (step.mustSucceed && !ok) {
        throw ElmInitException(step.command, response);
      }
      if (step.delayAfter > Duration.zero) {
        await Future.delayed(step.delayAfter);
      }
    }
  }

  // ---- late-reply drain -------------------------------------------------

  void _startDrain() {
    _draining = true;
    _drainTimer?.cancel();
    _drainTimer = Timer(drainTimeout, _onStall);
  }

  void _endDrain() {
    _cancelDrain();
    _buffer.clear();
    _busy = false;
    _pump();
  }

  void _cancelDrain() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _draining = false;
  }

  /// No prompt after a timeout: the adapter is stuck. Fail loudly instead of
  /// risking a mismatched reply; the caller can reconnect.
  void _onStall() {
    if (!_draining) return;
    _cancelDrain();
    _inputSub?.cancel();
    _inputSub = null;
    _failAll(StateError('ELM327 stopped responding'));
    unawaited(_link.disconnect());
    _lastDisconnectReason = ElmDisconnectReason.stalled;
    _setState(Elm327State.error);
  }

  // ---- failure / lifecycle ----------------------------------------------

  void _failAll(Object error) {
    final a = _active;
    a?.timer?.cancel();
    if (a != null && !a.completer.isCompleted) a.completer.completeError(error);
    _active = null;
    for (final c in _queue) {
      if (!c.completer.isCompleted) c.completer.completeError(error);
    }
    _queue.clear();
    _busy = false;
  }

  void _handleDisconnect() {
    _inputSub?.cancel();
    _inputSub = null;
    _cancelDrain();
    _failAll(StateError('Bluetooth disconnected'));
    unawaited(_link.disconnect()); // drop the stale link reference
    _lastDisconnectReason = ElmDisconnectReason.linkLost;
    _setState(Elm327State.disconnected);
  }

  @override
  Future<void> disconnect() async {
    _disconnectRequests++;
    await _forceCleanup();
    _lastDisconnectReason = ElmDisconnectReason.requested;
    _lastError = null;
    _setState(Elm327State.disconnected);
  }

  void _setState(Elm327State s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  @override
  void dispose() {
    disconnect();
    _stateController.close();
  }
}

class _Cmd {
  _Cmd(this.cmd, this.timeout);

  final String cmd;
  final Duration? timeout;
  final completer = Completer<String>();
  Timer? timer;

  bool get isAt => cmd.trim().toUpperCase().startsWith('AT');
}
