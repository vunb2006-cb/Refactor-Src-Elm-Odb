/// Answer to one "supported PIDs" request (`01 00`, `01 20`, `01 40`, ...).
class SupportedPidsRange {
  const SupportedPidsRange(this.base, this.pids, this.hasNextRange);

  /// First PID of the range minus one: 0x00, 0x20, 0x40, ...
  final int base;

  /// Two-digit upper-case hex PIDs. Like the app did before, this includes the
  /// range PIDs themselves (0x20, 0x40, ...) when the ECU reports them.
  final Set<String> pids;

  /// Bit 0 of the mask: the ECU supports at least one PID in the next range,
  /// so the next request is worth sending.
  final bool hasNextRange;
}

class SupportedPidsParser {
  SupportedPidsParser._();

  /// Parses the reply to `<mode><base>`; [mode] is '01' (live data) or '09'
  /// (vehicle info). Returns null when no line of [response] carries a mask.
  ///
  /// With several ECUs answering, each line is one ECU; the masks are OR-ed so
  /// the profile covers the whole vehicle, not just the first responder.
  static SupportedPidsRange? parse(
    String response, {
    required int base,
    String mode = '01',
  }) {
    final replyMode = (int.parse(mode, radix: 16) + 0x40)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(2, '0');
    final header = '$replyMode${_hex2(base)}';

    var mask = 0;
    var found = false;
    for (final raw in response.split(RegExp(r'[\r\n]+'))) {
      final line = raw.replaceAll(RegExp(r'[\s>]'), '').toUpperCase();
      final idx = line.indexOf(header);
      if (idx == -1) continue;
      final start = idx + header.length;
      if (line.length < start + 8) continue;
      final value = int.tryParse(line.substring(start, start + 8), radix: 16);
      if (value == null) continue;
      mask |= value;
      found = true;
    }
    if (!found) return null;

    final pids = <String>{};
    for (var bit = 31; bit >= 0; bit--) {
      if ((mask >> bit) & 1 == 1) pids.add(_hex2(base + (32 - bit)));
    }
    return SupportedPidsRange(base, pids, (mask & 1) == 1);
  }

  static String _hex2(int n) =>
      n.toRadixString(16).toUpperCase().padLeft(2, '0');
}
