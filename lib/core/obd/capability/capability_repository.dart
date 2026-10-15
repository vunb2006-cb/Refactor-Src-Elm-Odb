import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'capability_profile.dart';

/// Where capability profiles are kept. Today Hive (same approach as the other
/// repositories); the SQLite migration can replace it behind this interface.
abstract class CapabilityRepository {
  Future<CapabilityProfile?> load(String vehicleKey);
  Future<void> save(CapabilityProfile profile);
  Future<List<CapabilityProfile>> loadAll();
  Future<void> delete(String vehicleKey);
}

class InMemoryCapabilityRepository implements CapabilityRepository {
  final Map<String, CapabilityProfile> _items = {};

  @override
  Future<CapabilityProfile?> load(String vehicleKey) async =>
      _items[vehicleKey];

  @override
  Future<void> save(CapabilityProfile profile) async {
    _items[profile.vehicleKey] = profile;
  }

  @override
  Future<List<CapabilityProfile>> loadAll() async => _items.values.toList();

  @override
  Future<void> delete(String vehicleKey) async {
    _items.remove(vehicleKey);
  }
}

/// Stores each profile as one JSON string in a Hive `Box<String>`. A damaged
/// or outdated entry counts as "not found" (the vehicle is simply probed
/// again) instead of crashing the app.
class HiveCapabilityRepository implements CapabilityRepository {
  HiveCapabilityRepository(this._box);

  static const boxName = 'capability_profiles';

  static Future<HiveCapabilityRepository> open() async =>
      HiveCapabilityRepository(await Hive.openBox<String>(boxName));

  final Box<String> _box;

  @override
  Future<CapabilityProfile?> load(String vehicleKey) async =>
      _decode(_box.get(vehicleKey));

  @override
  Future<void> save(CapabilityProfile profile) =>
      _box.put(profile.vehicleKey, jsonEncode(profile.toJson()));

  @override
  Future<List<CapabilityProfile>> loadAll() async => [
        for (final raw in _box.values)
          if (_decode(raw) case final p?) p,
      ];

  @override
  Future<void> delete(String vehicleKey) => _box.delete(vehicleKey);

  CapabilityProfile? _decode(String? raw) {
    if (raw == null) return null;
    try {
      return CapabilityProfile.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}
