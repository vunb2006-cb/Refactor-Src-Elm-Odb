import 'dart:async';

import 'package:elm_obd2/core/obd/obd_transport.dart';

/// [ObdTransport] whose replies the test hands out by hand, to control exactly
/// when each command finishes. Like the real adapter client it throws at once
/// when asked to send while disconnected.
class ManualTransport implements ObdTransport {
  bool connected = true;
  final List<String> sent = [];
  final List<Completer<String>> _pending = [];
  final _state = StreamController<Elm327State>.broadcast();

  /// Commands sent but not answered yet.
  int get inFlight => _pending.length;

  /// Answers the oldest unanswered command.
  void reply(String text) => _pending.removeAt(0).complete(text);

  /// Fails the oldest unanswered command.
  void fail(Object error) => _pending.removeAt(0).completeError(error);

  /// Changes the connection state and announces it.
  void setConnected(bool value) {
    connected = value;
    _state.add(value ? Elm327State.connected : Elm327State.disconnected);
  }

  @override
  Future<String> sendCommand(String cmd) {
    if (!connected) throw StateError('ELM327 not connected');
    sent.add(cmd);
    final c = Completer<String>();
    _pending.add(c);
    return c.future;
  }

  @override
  Stream<Elm327State> get stateStream => _state.stream;
  @override
  Elm327State get state =>
      connected ? Elm327State.connected : Elm327State.disconnected;
  @override
  bool get isConnected => connected;
  @override
  String? get lastConnectedAddress => 'TEST';
  @override
  Future<void> disconnect() async {}
  @override
  void dispose() {}
}
