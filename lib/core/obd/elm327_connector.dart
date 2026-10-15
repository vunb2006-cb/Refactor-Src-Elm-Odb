import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'elm_client.dart';
import 'transport/spp_byte_transport.dart';

export 'elm_client.dart';
export 'obd_transport.dart';

/// Bluetooth SPP flavour of [ElmClient].
///
/// Kept as a thin subclass so existing code (`connect_provider.dart`,
/// `connect_screen.dart`) compiles unchanged: it still exposes
/// `connect(address)` and `getBondedDevices()`.
///
/// To use another link type, build an [ElmClient] with a different
/// `ByteTransport` instead of touching this class. The init profile, timeouts
/// and drain window can be overridden per adapter type.
class Elm327Connector extends ElmClient {
  Elm327Connector({
    ByteTransport? link,
    super.initProfile,
    super.timeouts,
    super.drainTimeout,
  }) : super(link ?? SppByteTransport());

  /// Returns all bonded Bluetooth devices (UI filters by name).
  Future<List<BluetoothDevice>> getBondedDevices() =>
      SppByteTransport.getBondedDevices();
}
