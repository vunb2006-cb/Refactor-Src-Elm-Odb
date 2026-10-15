import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'byte_transport.dart';

/// Classic Bluetooth SPP (RFCOMM) link, via `flutter_bluetooth_serial`.
///
/// Moved out of the old `Elm327Connector` without behaviour changes:
/// a failed first attempt is retried once after 1.5 s because Android's RFCOMM
/// stack needs about a second to release a socket orphaned when the app was
/// killed.
class SppByteTransport implements ByteTransport {
  SppByteTransport({
    this.attempts = 2,
    this.retryDelay = const Duration(milliseconds: 1500),
  }) : assert(attempts > 0);

  final int attempts;
  final Duration retryDelay;

  BluetoothConnection? _connection;

  /// Bonded (paired) devices; the UI filters them by name.
  static Future<List<BluetoothDevice>> getBondedDevices() =>
      FlutterBluetoothSerial.instance.getBondedDevices();

  @override
  bool get isConnected => _connection?.isConnected ?? false;

  @override
  Stream<Uint8List> get incoming =>
      _connection?.input ?? const Stream<Uint8List>.empty();

  @override
  Future<void> connect(String address) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        _connection = await BluetoothConnection.toAddress(address);
        return;
      } catch (_) {
        if (attempt == attempts - 1) rethrow;
        await Future.delayed(retryDelay);
      }
    }
  }

  @override
  void write(Uint8List data) {
    _connection?.output.add(data);
  }

  @override
  Future<void> disconnect() async {
    final c = _connection;
    _connection = null; // drop the reference first, even if close() throws
    try {
      await c?.close();
    } catch (_) {}
  }
}
