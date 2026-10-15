import 'elm_protocol.dart';

/// What a particular vehicle supports, probed once and reused afterwards.
class CapabilityProfile {
  const CapabilityProfile({
    required this.vehicleKey,
    required this.supportedPids,
    required this.probedAt,
    this.vin,
    this.protocol,
    this.adapterAddress,
  });

  static const schemaVersion = 1;

  /// Identity used to store and find the profile: the VIN when the vehicle
  /// reports one, otherwise `addr:<adapter address>`.
  final String vehicleKey;
  final String? vin;
  final ElmProtocol? protocol;
  final String? adapterAddress;

  /// Mode 01 PIDs the vehicle supports (two-digit upper-case hex). Empty means
  /// "unknown", matching `ObdService`: assume everything is supported.
  final Set<String> supportedPids;
  final DateTime probedAt;

  bool get hasPidInfo => supportedPids.isNotEmpty;

  bool supports(String pid) =>
      supportedPids.isEmpty || supportedPids.contains(pid.toUpperCase());

  static String keyFor({String? vin, String? adapterAddress}) =>
      vin ?? 'addr:${adapterAddress ?? 'unknown'}';

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'vehicleKey': vehicleKey,
        'vin': vin,
        'protocol': protocol?.code,
        'adapterAddress': adapterAddress,
        'supportedPids': (supportedPids.toList()..sort()),
        'probedAt': probedAt.toUtc().toIso8601String(),
      };

  /// Throws [FormatException] for unknown schema versions or missing fields.
  factory CapabilityProfile.fromJson(Map<String, dynamic> json) {
    if (json['v'] != schemaVersion) {
      throw FormatException('Unsupported capability schema: ${json['v']}');
    }
    final key = json['vehicleKey'];
    final probedAt = json['probedAt'];
    if (key is! String || probedAt is! String) {
      throw const FormatException('Capability profile is missing fields');
    }
    final code = json['protocol'];
    return CapabilityProfile(
      vehicleKey: key,
      vin: json['vin'] as String?,
      protocol: code is String ? ElmProtocol.fromCode(code) : null,
      adapterAddress: json['adapterAddress'] as String?,
      supportedPids: {
        for (final p in (json['supportedPids'] as List? ?? const []))
          (p as String).toUpperCase(),
      },
      probedAt: DateTime.parse(probedAt),
    );
  }
}
