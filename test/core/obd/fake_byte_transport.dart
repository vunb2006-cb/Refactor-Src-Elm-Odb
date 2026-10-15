import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:elm_obd2/core/obd/transport/byte_transport.dart';

/// In-memory [ByteTransport] standing in for a dongle.
///
/// With [autoRespond] on, every command written is answered like a clean
/// ELM327 would ("OK" unless [replies] says otherwise). Faults can be injected
/// per command: [replyDelay] (late reply) and [silent] (no reply at all). With
/// [autoRespond] off, the test drives replies by hand via [reply].
class FakeByteTransport implements ByteTransport {
  FakeByteTransport({this.autoRespond = true});

  bool autoRespond;
  final Map<String, String> replies = {};
  final Map<String, Duration> replyDelay = {};
  final Set<String> silent = {};
  final List<String> written = [];
  Object? connectError;
  int connectCalls = 0;
  int disconnectCalls = 0;

  StreamController<Uint8List>? _incoming;
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get incoming => _incoming!.stream;

  @override
  Future<void> connect(String address) async {
    connectCalls++;
    if (connectError != null) throw connectError!;
    _incoming = StreamController<Uint8List>();
    _connected = true;
  }

  @override
  void write(Uint8List data) {
    final cmd = utf8.decode(data).replaceAll('\r', '');
    written.add(cmd);
    if (!autoRespond || silent.contains(cmd)) return;
    final text = replies[cmd] ?? 'OK';
    final delay = replyDelay[cmd];
    if (delay == null) {
      scheduleMicrotask(() => reply(text));
    } else {
      Timer(delay, () => reply(text));
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = false;
    final c = _incoming;
    _incoming = null;
    if (c != null && !c.isClosed) await c.close();
  }

  /// Emit one adapter reply followed by the '>' prompt.
  void reply(String text) {
    _incoming?.add(Uint8List.fromList(utf8.encode('$text\r\r>')));
  }

  /// Simulate the link dropping (Bluetooth out of range, dongle unplugged).
  Future<void> dropLink() async {
    _connected = false;
    final c = _incoming;
    _incoming = null;
    await c?.close();
  }
}
