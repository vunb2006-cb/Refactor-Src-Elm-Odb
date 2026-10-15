import 'dart:async';
import 'dart:math';

import '../obd_transport.dart';
import '../pid_constants.dart';
import 'fault_profile.dart';
import 'virtual_ecu.dart';

/// A protocol-accurate stand-in for [Elm327Connector] that talks to a
/// [VirtualEcu] instead of real Bluetooth hardware.
///
/// Encodes responses in the exact byte layout `PidDecoder`/`DtcDecoder`
/// expect, so everything above [ObdService] — test executor, condition
/// evaluator, live monitor, the Gemini agent loop — runs unmodified against
/// either this or the real connector.
class SimulatedElm327Connector implements ObdTransport {
  final VirtualEcu ecu;
  final _rand = Random();

  final _stateController = StreamController<Elm327State>.broadcast();
  Elm327State _state = Elm327State.disconnected;

  SimulatedElm327Connector({FaultProfile fault = FaultProfile.healthy})
      : ecu = VirtualEcu(fault: fault);

  @override
  Stream<Elm327State> get stateStream => _stateController.stream;
  @override
  Elm327State get state => _state;
  @override
  bool get isConnected => _state == Elm327State.connected;
  @override
  String? get lastConnectedAddress =>
      isConnected || _state != Elm327State.disconnected
          ? 'SIMULATED-ECU'
          : null;

  Future<void> connect() async {
    if (_state == Elm327State.connecting ||
        _state == Elm327State.initializing ||
        _state == Elm327State.connected) {
      return;
    }
    _setState(Elm327State.connecting);
    await Future.delayed(const Duration(milliseconds: 350));
    _setState(Elm327State.initializing);
    ecu.start();
    await Future.delayed(const Duration(milliseconds: 400));
    _setState(Elm327State.connected);
  }

  @override
  Future<void> disconnect() async {
    ecu.dispose();
    _setState(Elm327State.disconnected);
  }

  @override
  void dispose() {
    ecu.dispose();
    _stateController.close();
  }

  void _setState(Elm327State s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  @override
  Future<String> sendCommand(String cmd) async {
    // Mimic real Bluetooth SPP round-trip latency so timing-sensitive code
    // (progress bars, condition polling) behaves like it would on hardware.
    await Future.delayed(Duration(milliseconds: 25 + _rand.nextInt(45)));

    final c = cmd.trim().toUpperCase();

    if (c.startsWith('AT')) return _handleAt(c);
    if (c == '03') return _dtcResponse('43');
    if (c == '07') return 'NO DATA';
    if (c.startsWith('02') && c.length >= 4) return _freezeFrameResponse(c);
    if (RegExp(r'^01(00|20|40|60|80|A0|C0|E0)$').hasMatch(c)) {
      return _supportedPidsResponse(c);
    }
    if (c == '0900') return '490040000000'; // mode 09: PID 02 (VIN) supported
    if (c == '0902') return _vinResponse();
    if (c.startsWith('01') && c.length == 4) return _pidResponse(c.substring(2));

    return 'NO DATA';
  }

  String _handleAt(String cmd) {
    if (cmd == 'ATZ') return 'ELM327 v2.1';
    if (cmd == 'ATI') return 'ELM327 v2.1';
    if (cmd == 'ATDPN') return 'A6'; // automatic, ISO 15765-4 CAN 11/500
    return 'OK';
  }

  String _dtcResponse(String header) {
    final codes = ecu.fault.dtcCodes;
    if (codes.isEmpty) return 'NO DATA';
    return header + codes.map(_dtcToHex).join();
  }

  String _dtcToHex(String code) {
    const systems = ['P', 'C', 'B', 'U'];
    final systemBits = systems.indexOf(code[0]);
    final firstDigit = int.parse(code[1]);
    final secondDigit = int.parse(code[2], radix: 16);
    final thirdDigit = int.parse(code[3], radix: 16);
    final fourthDigit = int.parse(code[4], radix: 16);
    final byte1 = (systemBits << 6) | (firstDigit << 4) | secondDigit;
    final byte2 = (thirdDigit << 4) | fourthDigit;
    return _hex(byte1) + _hex(byte2);
  }

  String _freezeFrameResponse(String cmd) {
    final pid = cmd.substring(2, 4);
    final value = ecu.valueFor(pid);
    if (value == null) return 'NO DATA';
    return '42${pid.toUpperCase()}00${_encodePid(pid, value)}';
  }

  String _pidResponse(String pid) {
    final value = ecu.valueFor(pid);
    if (value == null) return 'NO DATA';
    return '41${pid.toUpperCase()}${_encodePid(pid, value)}';
  }

  static final Set<int> _allSupportedPidNumbers = PidConstants.nameToCode.values
      .map((hex) => int.parse(hex, radix: 16))
      .toSet();

  String _supportedPidsResponse(String cmd) {
    final pidBase = int.parse(cmd.substring(2), radix: 16);
    var mask = 0;
    for (var bit = 31; bit >= 1; bit--) {
      final pidNum = pidBase + (32 - bit);
      if (_allSupportedPidNumbers.contains(pidNum)) {
        mask |= 1 << bit;
      }
    }
    // Bit 0 = "the next range has supported PIDs", exactly like a real ECU.
    final nextRangeStart = pidBase + 0x20;
    if (_allSupportedPidNumbers.any((n) => n >= nextRangeStart)) {
      mask |= 1;
    }
    final header = '41${cmd.substring(2).toUpperCase()}';
    return header + mask.toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  /// VIN the simulator reports (obviously fake, but a valid 17-character VIN).
  static const simulatedVin = 'ZZZ00000000000001';

  /// Mode 09 PID 02 reply in the CAN multi-frame layout the real adapter
  /// produces with headers off: a length line, then indexed frames.
  String _vinResponse() {
    final bytes = [0x49, 0x02, 0x01, ...simulatedVin.codeUnits]; // 20 bytes
    String h(List<int> b) => b.map(_hex).join();
    return '014\r0:${h(bytes.sublist(0, 6))}'
        '\r1:${h(bytes.sublist(6, 13))}'
        '\r2:${h(bytes.sublist(13, 20))}';
  }

  /// Encodes [value] for [pid] as the exact inverse of `PidDecoder._apply`.
  String _encodePid(String pid, double value) {
    final p = pid.toUpperCase();
    switch (p) {
      case PidConstants.rpm:
        return _hex16((value * 4).round());
      case PidConstants.maf:
        return _hex16((value * 100).round());
      case PidConstants.engineRunTime:
      case PidConstants.distanceMilOn:
        return _hex16(value.round());
      case PidConstants.coolantTemp:
      case PidConstants.intakeAirTemp:
      case PidConstants.oilTemp:
        return _hex((value + 40).round());
      case PidConstants.engineLoad:
      case PidConstants.throttlePos:
      case PidConstants.fuelLevel:
      case PidConstants.egrCommanded:
        return _hex((value * 255 / 100).round());
      case PidConstants.stftB1:
      case PidConstants.ltftB1:
      case PidConstants.stftB2:
      case PidConstants.ltftB2:
        return _hex((value * 128 / 100 + 128).round());
      case PidConstants.fuelPressure:
        return _hex((value / 3).round());
      case PidConstants.o2B1S1:
      case PidConstants.o2B1S2:
        return _hex((value * 200).round());
      case PidConstants.map:
      case PidConstants.speed:
      case PidConstants.baroPressure:
        return _hex(value.round());
      default:
        return _hex(value.round());
    }
  }

  String _hex(int byte) => byte.clamp(0, 255).toRadixString(16).padLeft(2, '0').toUpperCase();

  String _hex16(int raw) {
    final v = raw.clamp(0, 65535);
    return _hex(v >> 8) + _hex(v & 0xFF);
  }
}
