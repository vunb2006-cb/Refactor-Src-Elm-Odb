import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../obd/capability/capability_profile.dart';
import '../../obd/capability/capability_repository.dart';
import '../../obd/capability/elm_protocol.dart';
import '../local_database.dart';

/// Capability profiles in SQLite: one `vehicle` row per vehicle and one
/// `capability_profile` row with what it supports.
///
/// Replaces the Hive implementation behind the same [CapabilityRepository]
/// interface. Profiles saved by the Hive version are not migrated: those
/// vehicles are simply probed again.
class SqliteCapabilityRepository implements CapabilityRepository {
  SqliteCapabilityRepository(this._database);

  final LocalDatabase _database;

  Database get _db => _database.db;

  static const _selectSql = '''
    SELECT v.vehicle_key, v.vin, v.adapter_address,
           c.protocol, c.supported_pids, c.probed_at
    FROM capability_profile c
    JOIN vehicle v ON v.id = c.vehicle_id
  ''';

  @override
  Future<CapabilityProfile?> load(String vehicleKey) async {
    final rows = await _db.rawQuery(
      '$_selectSql WHERE v.vehicle_key = ?',
      [vehicleKey],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<List<CapabilityProfile>> loadAll() async {
    final rows = await _db.rawQuery(_selectSql);
    return [
      for (final row in rows)
        if (_fromRow(row) case final p?) p,
    ];
  }

  @override
  Future<void> save(CapabilityProfile profile) async {
    await _db.transaction((txn) async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final existing = await txn.query(
        'vehicle',
        columns: ['id'],
        where: 'vehicle_key = ?',
        whereArgs: [profile.vehicleKey],
        limit: 1,
      );

      // Not INSERT OR REPLACE: replacing the vehicle row would cascade-delete
      // its trips and telemetry.
      final int vehicleId;
      if (existing.isEmpty) {
        vehicleId = await txn.insert('vehicle', {
          'vehicle_key': profile.vehicleKey,
          'vin': profile.vin,
          'adapter_address': profile.adapterAddress,
          'created_at': now,
        });
      } else {
        vehicleId = existing.first['id']! as int;
        await txn.update(
          'vehicle',
          {'vin': profile.vin, 'adapter_address': profile.adapterAddress},
          where: 'id = ?',
          whereArgs: [vehicleId],
        );
      }

      await txn.insert(
        'capability_profile',
        {
          'vehicle_id': vehicleId,
          'protocol': profile.protocol?.code,
          'supported_pids': jsonEncode(profile.supportedPids.toList()..sort()),
          'init_profile': null,
          'probed_at': profile.probedAt.toUtc().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Removes the stored profile only. The vehicle row stays, because trips
  /// and telemetry hang off it.
  @override
  Future<void> delete(String vehicleKey) async {
    await _db.delete(
      'capability_profile',
      where: 'vehicle_id IN (SELECT id FROM vehicle WHERE vehicle_key = ?)',
      whereArgs: [vehicleKey],
    );
  }

  /// A damaged row counts as "not found": the vehicle is probed again.
  CapabilityProfile? _fromRow(Map<String, Object?> row) {
    try {
      final pids = (jsonDecode(row['supported_pids']! as String) as List)
          .map((p) => (p as String).toUpperCase())
          .toSet();
      final code = row['protocol'] as String?;
      return CapabilityProfile(
        vehicleKey: row['vehicle_key']! as String,
        vin: row['vin'] as String?,
        adapterAddress: row['adapter_address'] as String?,
        protocol: code == null ? null : ElmProtocol.fromCode(code),
        supportedPids: pids,
        probedAt: DateTime.fromMillisecondsSinceEpoch(
          row['probed_at']! as int,
          isUtc: true,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
