import '../obd_transport.dart';
import 'capability_profile.dart';
import 'elm_protocol.dart';
import 'supported_pids.dart';
import 'vin_decoder.dart';

/// Asks the vehicle what it supports. Works against any [ObdTransport]
/// (real adapter or simulator). Every step tolerates failure: a missing VIN
/// or protocol never prevents the PID list from being read.
class CapabilityProbe {
  CapabilityProbe(this._transport, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final ObdTransport _transport;
  final DateTime Function() _clock;

  /// Highest range base worth asking for: 01 E0 covers PIDs 0xE1..0x100.
  static const _lastBase = 0xE0;

  /// Reads the supported-PID masks as a chain: `01 00`, then `01 20`, `01 40`,
  /// ... for as long as bit 0 says the next range has PIDs. Stops at the first
  /// failure or missing answer and returns what was collected so far.
  Future<Set<String>> readSupportedPids() async {
    final out = <String>{};
    var base = 0;
    while (base <= _lastBase) {
      final String reply;
      try {
        reply = await _transport.sendCommand('01${_hex2(base)}');
      } catch (_) {
        break;
      }
      final range = SupportedPidsParser.parse(reply, base: base);
      if (range == null) break;
      out.addAll(range.pids);
      if (!range.hasNextRange) break;
      base += 0x20;
    }
    return out;
  }

  /// Protocol the adapter settled on. Ask only after at least one OBD command
  /// succeeded, otherwise the adapter has not detected anything yet.
  Future<ElmProtocol?> readProtocol() async {
    try {
      return ElmProtocol.parseDpn(await _transport.sendCommand('ATDPN'));
    } catch (_) {
      return null;
    }
  }

  /// VIN via mode 09. Checks `09 00` first and only asks for `09 02` when the
  /// vehicle says it supports it.
  Future<String?> readVin() async {
    try {
      final support = await _transport.sendCommand('0900');
      final range =
          SupportedPidsParser.parse(support, base: 0, mode: '09');
      if (range == null || !range.pids.contains('02')) return null;
      return VinDecoder.decode(await _transport.sendCommand('0902'));
    } catch (_) {
      return null;
    }
  }

  /// Full probe. Pass [knownVin] with [vinAlreadyRead] when the VIN was
  /// already read (see `CapabilityService`) to avoid asking twice.
  Future<CapabilityProfile> run({
    String? adapterAddress,
    String? knownVin,
    bool vinAlreadyRead = false,
  }) async {
    final pids = await readSupportedPids();
    final protocol = await readProtocol();
    final vin = vinAlreadyRead ? knownVin : await readVin();
    return CapabilityProfile(
      vehicleKey:
          CapabilityProfile.keyFor(vin: vin, adapterAddress: adapterAddress),
      vin: vin,
      protocol: protocol,
      adapterAddress: adapterAddress,
      supportedPids: pids,
      probedAt: _clock().toUtc(),
    );
  }

  static String _hex2(int n) =>
      n.toRadixString(16).toUpperCase().padLeft(2, '0');
}
