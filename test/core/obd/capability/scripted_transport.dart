import 'package:elm_obd2/core/obd/obd_transport.dart';

/// [ObdTransport] answering from a fixed script, recording what was asked.
/// A command missing from the script gets "NO DATA"; a script entry that is an
/// [Exception] is thrown instead of returned.
class ScriptedTransport implements ObdTransport {
  ScriptedTransport(Map<String, Object> script) : script = Map.of(script);

  final Map<String, Object> script;
  final List<String> sent = [];

  @override
  Future<String> sendCommand(String cmd) async {
    sent.add(cmd);
    final r = script[cmd];
    if (r == null) return 'NO DATA';
    if (r is Exception) throw r;
    return r as String;
  }

  @override
  Stream<Elm327State> get stateStream => const Stream.empty();
  @override
  Elm327State get state => Elm327State.connected;
  @override
  bool get isConnected => true;
  @override
  String? get lastConnectedAddress => 'TEST';
  @override
  Future<void> disconnect() async {}
  @override
  void dispose() {}
}

String _hex2(int n) => n.toRadixString(16).toUpperCase().padLeft(2, '0');

/// Mode 09 PID 02 reply in the CAN multi-frame layout (headers off).
String canVinReply(String vin) {
  final b = [0x49, 0x02, 0x01, ...vin.codeUnits];
  String h(List<int> x) => x.map(_hex2).join();
  return '014\r0:${h(b.sublist(0, 6))}'
      '\r1:${h(b.sublist(6, 13))}'
      '\r2:${h(b.sublist(13, 20))}';
}

/// Same VIN as a J1850 / ISO 9141 style reply: one message per line.
String isoVinReply(String vin) {
  final data = [0, 0, 0, ...vin.codeUnits];
  return [
    for (var s = 0; s < 5; s++)
      '49 02 ${_hex2(s + 1)} '
          '${data.sublist(s * 4, s * 4 + 4).map(_hex2).join(' ')}',
  ].join('\r');
}
