/// How long to wait for an ELM327 reply, by kind of command.
///
/// One fixed timeout is wrong in both directions: the first OBD command after
/// `ATSP0` makes the adapter search for the protocol ("SEARCHING...") and can
/// legitimately take several seconds, while an ordinary PID read that takes
/// more than ~2.5 s means something is wrong.
class ElmTimeouts {
  const ElmTimeouts({
    this.command = const Duration(milliseconds: 2500),
    this.reset = const Duration(seconds: 5),
    this.detect = const Duration(seconds: 10),
    this.slow = const Duration(seconds: 5),
  });

  /// Ordinary AT commands and PID reads.
  final Duration command;

  /// `ATZ` / `ATWS` (adapter restart).
  final Duration reset;

  /// First OBD command after connecting: protocol auto-detection.
  final Duration detect;

  /// Multi-frame or slow requests: DTCs (modes 03, 07, 0A) and mode 09 (VIN).
  final Duration slow;

  Duration forCommand(String cmd, {required bool protocolDetected}) {
    final c = cmd.replaceAll(' ', '').toUpperCase();
    if (c == 'ATZ' || c == 'ATWS') return reset;
    if (c.startsWith('AT')) return command;
    if (!protocolDetected) return detect;
    if (c.startsWith('03') ||
        c.startsWith('07') ||
        c.startsWith('0A') ||
        c.startsWith('09')) {
      return slow;
    }
    return command;
  }
}
