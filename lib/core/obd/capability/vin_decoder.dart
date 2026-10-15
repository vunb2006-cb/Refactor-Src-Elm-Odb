/// Decodes the reply to mode 09 PID 02 (vehicle identification number).
///
/// Handles both layouts the ELM327 produces with headers off:
///  * CAN (ISO 15765-4): a length line, then indexed lines
///    `014` / `0:490201...` / `1:...` / `2:...`
///  * J1850 / ISO 9141 / KWP: one message per line, `49 02 <seq> <4 bytes>`
class VinDecoder {
  VinDecoder._();

  // A VIN never contains I, O or Q. The check digit is NOT verified: it is
  // mandatory in North America only.
  static final _validVin = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

  static bool isValid(String vin) => _validVin.hasMatch(vin);

  /// Returns the VIN, or null if the reply holds no valid one.
  static String? decode(String response) {
    final lines = response
        .toUpperCase()
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.replaceAll(RegExp(r'\s'), ''))
        .where((l) => l.isNotEmpty)
        .toList();

    final indexed = <int, String>{};
    for (final line in lines) {
      final m = RegExp(r'^([0-9A-F]):([0-9A-F]+)$').firstMatch(line);
      if (m != null) indexed[int.parse(m.group(1)!, radix: 16)] = m.group(2)!;
    }

    // CAN replies start with a line holding the total byte count (3 hex
    // digits, e.g. "014" = 20). Frames can carry padding past that count.
    int? declaredLength;
    for (final line in lines) {
      if (RegExp(r'^[0-9A-F]{3}$').hasMatch(line)) {
        declaredLength = int.parse(line, radix: 16);
        break;
      }
    }

    List<int> bytes;
    if (indexed.isNotEmpty) {
      // Frame labels are sorted, not assumed to start at 0 (some adapters
      // label from 1).
      final hex = (indexed.keys.toList()..sort()).map((k) => indexed[k]!).join();
      var all = _hexToBytes(hex);
      if (declaredLength != null &&
          declaredLength >= 3 &&
          declaredLength <= all.length) {
        all = all.sublist(0, declaredLength);
      }
      final at = _indexOfHeader(all);
      if (at < 0 || all.length < at + 3) return null;
      bytes = all.sublist(at + 3); // skip 49 02 and the item-count byte
    } else {
      final frames = <int, List<int>>{};
      for (final line in lines) {
        final at = line.indexOf('4902');
        if (at < 0) continue;
        final b = _hexToBytes(line.substring(at + 4));
        if (b.length < 2) continue;
        frames[b[0]] = b.sublist(1); // b[0] is the message sequence number
      }
      if (frames.isEmpty) return null;
      bytes = [
        for (final k in (frames.keys.toList()..sort())) ...frames[k]!,
      ];
    }

    // Keep printable ASCII only: drops 0x00 / 0xFF padding.
    final chars = String.fromCharCodes(
      bytes.where((b) => b >= 0x20 && b <= 0x7E),
    );
    if (chars.length < 17) return null;
    final first = chars.substring(0, 17);
    if (isValid(first)) return first;
    final last = chars.substring(chars.length - 17);
    return isValid(last) ? last : null;
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final v = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (v == null) return const [];
      out.add(v);
    }
    return out;
  }

  static int _indexOfHeader(List<int> b) {
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 0x49 && b[i + 1] == 0x02) return i;
    }
    return -1;
  }
}
