/// OBD protocol the adapter settled on, as reported by `ATDPN`.
class ElmProtocol {
  const ElmProtocol(this.code, this.name);

  /// One hex digit, `1`..`C`, as defined by the ELM327 command set.
  final String code;
  final String name;

  static const _names = <String, String>{
    '1': 'SAE J1850 PWM',
    '2': 'SAE J1850 VPW',
    '3': 'ISO 9141-2',
    '4': 'ISO 14230-4 KWP (5 baud init)',
    '5': 'ISO 14230-4 KWP (fast init)',
    '6': 'ISO 15765-4 CAN (11 bit ID, 500 kbaud)',
    '7': 'ISO 15765-4 CAN (29 bit ID, 500 kbaud)',
    '8': 'ISO 15765-4 CAN (11 bit ID, 250 kbaud)',
    '9': 'ISO 15765-4 CAN (29 bit ID, 250 kbaud)',
    'A': 'SAE J1939 CAN (29 bit ID, 250 kbaud)',
    'B': 'USER1 CAN',
    'C': 'USER2 CAN',
  };

  static ElmProtocol? fromCode(String code) {
    final c = code.toUpperCase();
    final name = _names[c];
    return name == null ? null : ElmProtocol(c, name);
  }

  /// Parses an `ATDPN` reply: `A6` (automatic, protocol 6) or `6` (fixed).
  /// `A0` means "automatic, nothing detected yet" and returns null.
  static ElmProtocol? parseDpn(String reply) {
    final lines = reply
        .toUpperCase()
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final line = lines.last;
    if (line.length == 2 && line.startsWith('A')) return fromCode(line[1]);
    if (line.length == 1) return fromCode(line);
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ElmProtocol && other.code == code && other.name == name;

  @override
  int get hashCode => Object.hash(code, name);

  @override
  String toString() => 'ElmProtocol($code, $name)';
}
