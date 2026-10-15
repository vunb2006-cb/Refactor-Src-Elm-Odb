import 'dart:typed_data';

/// Byte-level link to an ELM327-class adapter (Bluetooth SPP, BLE, TCP, ...).
///
/// This is the ONLY layer that knows how bytes physically reach the adapter.
/// Command framing, the `>` prompt, timeouts and ELM327 initialisation live in
/// `ElmClient`, so supporting a new link type means writing one class that
/// implements this interface and nothing else.
///
/// Contract:
///  * [connect] opens the link (it may retry internally). It throws if the link
///    cannot be opened.
///  * [incoming] is the raw byte stream of the CURRENT connection. It must
///    complete (onDone) or emit an error when the link drops.
///  * [write] sends raw bytes; it must not throw when the link is gone.
///  * [disconnect] is idempotent and never throws.
abstract class ByteTransport {
  bool get isConnected;
  Stream<Uint8List> get incoming;

  Future<void> connect(String address);
  void write(Uint8List data);
  Future<void> disconnect();
}
