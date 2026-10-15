import 'dart:io';

import 'package:elm_obd2/core/storage/database_migrations.dart';
import 'package:elm_obd2/core/storage/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<LocalDatabase> _openMemory({DatabaseMigrations? migrations}) =>
    LocalDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
      migrations: migrations,
    );

int _firstInt(List<Map<String, Object?>> rows) =>
    rows.first.values.first! as int;

Future<int> _addVehicle(LocalDatabase d, {String key = 'VIN1'}) =>
    d.db.insert('vehicle', {'vehicle_key': key, 'created_at': 1});

Future<int> _addTrip(LocalDatabase d, int vehicleId) =>
    d.db.insert('trip', {'vehicle_id': vehicleId, 'started_at': 1});

Future<int> _count(LocalDatabase d, String table) async =>
    _firstInt(await d.db.rawQuery('SELECT COUNT(*) FROM $table'));

void main() {
  setUpAll(sqfliteFfiInit);

  group('schema v1', () {
    test('creates every table', () async {
      final d = await _openMemory();
      addTearDown(d.close);

      final rows = await d.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      );
      expect(rows.map((r) => r['name']).toSet(), {
        'vehicle',
        'capability_profile',
        'trip',
        'job_def',
        'telemetry_sample',
        'snapshot',
        'upload_queue',
        'runtime_state',
      });
    });

    test('creates the indexes the queries rely on', () async {
      final d = await _openMemory();
      addTearDown(d.close);

      final rows = await d.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      final names = rows.map((r) => r['name']).toSet();
      expect(
        names,
        containsAll([
          'idx_sample_trip_ts',
          'idx_sample_ts',
          'idx_snapshot_trip_ts',
          'idx_queue_state_retry',
        ]),
      );
    });

    test('enforces foreign keys', () async {
      final d = await _openMemory();
      addTearDown(d.close);

      await expectLater(
        d.db.insert('telemetry_sample', {
          'trip_id': 999,
          'ts': 1,
          'pid': '0C',
          'value': 1.0,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('upload_queue only accepts the four known states', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      final trip = await _addTrip(d, await _addVehicle(d));
      final snap = await d.db.insert(
        'snapshot',
        {'trip_id': trip, 'ts': 1, 'values_json': '{}'},
      );

      await expectLater(
        d.db.insert('upload_queue', {
          'snapshot_id': snap,
          'state': 'bogus',
          'dedup_key': 'k1',
        }),
        throwsA(isA<DatabaseException>()),
      );
      for (final state in ['pending', 'in_flight', 'sent', 'failed']) {
        final s = await d.db.insert(
          'snapshot',
          {'trip_id': trip, 'ts': 2, 'values_json': '{}'},
        );
        await d.db.insert('upload_queue', {
          'snapshot_id': s,
          'state': state,
          'dedup_key': 'k-$state',
        });
      }
      expect(await _count(d, 'upload_queue'), 4);
    });

    test('dedup_key is unique', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      final trip = await _addTrip(d, await _addVehicle(d));
      final a = await d.db
          .insert('snapshot', {'trip_id': trip, 'ts': 1, 'values_json': '{}'});
      final b = await d.db
          .insert('snapshot', {'trip_id': trip, 'ts': 2, 'values_json': '{}'});
      await d.db.insert(
        'upload_queue',
        {'snapshot_id': a, 'state': 'pending', 'dedup_key': 'same'},
      );

      await expectLater(
        d.db.insert(
          'upload_queue',
          {'snapshot_id': b, 'state': 'pending', 'dedup_key': 'same'},
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('vehicle_key is unique', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      await _addVehicle(d);

      await expectLater(_addVehicle(d), throwsA(isA<DatabaseException>()));
    });

    test('deleting a vehicle removes everything that hangs off it', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      final vehicle = await _addVehicle(d);
      final trip = await _addTrip(d, vehicle);
      await d.db.insert('capability_profile', {
        'vehicle_id': vehicle,
        'supported_pids': '[]',
        'probed_at': 1,
      });
      await d.db.insert(
        'telemetry_sample',
        {'trip_id': trip, 'ts': 1, 'pid': '0C', 'value': 1.0},
      );
      final snap = await d.db
          .insert('snapshot', {'trip_id': trip, 'ts': 1, 'values_json': '{}'});
      await d.db.insert(
        'upload_queue',
        {'snapshot_id': snap, 'state': 'pending', 'dedup_key': 'k'},
      );

      await d.db.delete('vehicle', where: 'id = ?', whereArgs: [vehicle]);

      for (final table in [
        'capability_profile',
        'trip',
        'telemetry_sample',
        'snapshot',
        'upload_queue',
      ]) {
        expect(await _count(d, table), 0, reason: table);
      }
    });
  });

  group('insertBatch', () {
    test('stores every row', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      final trip = await _addTrip(d, await _addVehicle(d));

      await d.insertBatch('telemetry_sample', [
        for (var i = 0; i < 5000; i++)
          {'trip_id': trip, 'ts': i, 'pid': '0C', 'value': i.toDouble()},
      ]);

      expect(await _count(d, 'telemetry_sample'), 5000);
    });

    test('is all or nothing when one row breaks a constraint', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      final trip = await _addTrip(d, await _addVehicle(d));

      await expectLater(
        d.insertBatch('telemetry_sample', [
          {'trip_id': trip, 'ts': 1, 'pid': '0C', 'value': 1.0},
          {'trip_id': 999, 'ts': 2, 'pid': '0C', 'value': 2.0}, // no such trip
          {'trip_id': trip, 'ts': 3, 'pid': '0C', 'value': 3.0},
        ]),
        throwsA(isA<DatabaseException>()),
      );

      expect(await _count(d, 'telemetry_sample'), 0);
    });

    test('an empty list does nothing', () async {
      final d = await _openMemory();
      addTearDown(d.close);
      await d.insertBatch('telemetry_sample', const []);
      expect(await _count(d, 'telemetry_sample'), 0);
    });
  });

  group('persistence and migrations', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('elm_obd2_db_');
      path = '${dir.path}/test.db';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<LocalDatabase> openFile({DatabaseMigrations? migrations}) =>
        LocalDatabase.open(
          path: path,
          factory: databaseFactoryFfi,
          migrations: migrations,
        );

    test('data survives closing and reopening the database', () async {
      var d = await openFile();
      await _addVehicle(d, key: 'VIN-KEPT');
      await d.close();

      d = await openFile();
      addTearDown(d.close);

      final rows = await d.db.query('vehicle');
      expect(rows.single['vehicle_key'], 'VIN-KEPT');
    });

    test('a new migration step upgrades an existing database in place',
        () async {
      var d = await openFile();
      await _addVehicle(d, key: 'VIN-OLD');
      await d.close();

      final v2 = DatabaseMigrations([
        ...DatabaseMigrations.standard.steps,
        (db) => db.execute('ALTER TABLE vehicle ADD COLUMN notes TEXT'),
      ]);
      d = await openFile(migrations: v2);
      addTearDown(d.close);

      final version = _firstInt(await d.db.rawQuery('PRAGMA user_version'));
      expect(version, 2);
      final rows = await d.db.query('vehicle');
      expect(rows.single['vehicle_key'], 'VIN-OLD'); // old data kept
      await d.db.update('vehicle', {'notes': 'ok'}); // new column works
      expect((await d.db.query('vehicle')).single['notes'], 'ok');
    });

    test('a fresh database runs every step', () async {
      final v2 = DatabaseMigrations([
        ...DatabaseMigrations.standard.steps,
        (db) => db.execute('ALTER TABLE vehicle ADD COLUMN notes TEXT'),
      ]);
      final d = await openFile(migrations: v2);
      addTearDown(d.close);

      expect(_firstInt(await d.db.rawQuery('PRAGMA user_version')), 2);
      await d.db.insert(
        'vehicle',
        {'vehicle_key': 'K', 'created_at': 1, 'notes': 'x'},
      );
    });

    test('opening a database that is newer than the app fails', () async {
      final v2 = DatabaseMigrations([
        ...DatabaseMigrations.standard.steps,
        (db) => db.execute('ALTER TABLE vehicle ADD COLUMN notes TEXT'),
      ]);
      final newer = await openFile(migrations: v2);
      await newer.close();

      await expectLater(openFile(), throwsA(isA<Object>()));
    });
  });

  test('usedBytes reports a positive size that grows with data', () async {
    final d = await _openMemory();
    addTearDown(d.close);
    final before = await d.usedBytes();
    expect(before, greaterThan(0));

    final trip = await _addTrip(d, await _addVehicle(d));
    await d.insertBatch('telemetry_sample', [
      for (var i = 0; i < 20000; i++)
        {'trip_id': trip, 'ts': i, 'pid': '0C', 'value': i.toDouble()},
    ]);

    expect(await d.usedBytes(), greaterThan(before));
  });
}
