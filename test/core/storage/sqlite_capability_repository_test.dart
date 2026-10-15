import 'package:elm_obd2/core/obd/capability/capability_profile.dart';
import 'package:elm_obd2/core/obd/capability/elm_protocol.dart';
import 'package:elm_obd2/core/storage/local_database.dart';
import 'package:elm_obd2/core/storage/repositories/sqlite_capability_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

CapabilityProfile _profile(
  String key, {
  Set<String>? pids,
  String? adapter = 'AA:BB',
}) =>
    CapabilityProfile(
      vehicleKey: key,
      vin: key.startsWith('addr:') ? null : key,
      adapterAddress: adapter,
      protocol: ElmProtocol.fromCode('6'),
      supportedPids: pids ?? const {'0C', '0D'},
      probedAt: DateTime.utc(2026, 10, 15, 8, 30),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  late LocalDatabase db;
  late SqliteCapabilityRepository repo;

  setUp(() async {
    db = await LocalDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = SqliteCapabilityRepository(db);
  });

  tearDown(() => db.close());

  test('save then load gives back the same profile', () async {
    final saved = _profile('VIN1');
    await repo.save(saved);

    final p = (await repo.load('VIN1'))!;

    expect(p.vehicleKey, 'VIN1');
    expect(p.vin, 'VIN1');
    expect(p.adapterAddress, 'AA:BB');
    expect(p.protocol, saved.protocol);
    expect(p.supportedPids, {'0C', '0D'});
    expect(p.probedAt, saved.probedAt);
  });

  test('load of an unknown key is null', () async {
    expect(await repo.load('nope'), isNull);
  });

  test('a vehicle without a VIN is stored under its address key', () async {
    await repo.save(_profile('addr:AA:BB', pids: const {'05'}));

    final p = (await repo.load('addr:AA:BB'))!;

    expect(p.vin, isNull);
    expect(p.supportedPids, {'05'});
  });

  test('a missing protocol stays missing', () async {
    final noProtocol = CapabilityProfile(
      vehicleKey: 'VIN2',
      vin: 'VIN2',
      supportedPids: const {'0C'},
      probedAt: DateTime.utc(2026),
    );
    await repo.save(noProtocol);

    expect((await repo.load('VIN2'))!.protocol, isNull);
  });

  test('saving again replaces the profile and keeps one vehicle row',
      () async {
    await repo.save(_profile('VIN1'));
    await repo.save(_profile('VIN1', pids: const {'05'}, adapter: 'CC:DD'));

    final p = (await repo.load('VIN1'))!;

    expect(p.supportedPids, {'05'});
    expect(p.adapterAddress, 'CC:DD');
    expect(await db.db.query('vehicle'), hasLength(1));
    expect(await repo.loadAll(), hasLength(1));
  });

  test('loadAll returns every stored profile', () async {
    await repo.save(_profile('VIN1'));
    await repo.save(_profile('VIN2'));

    final keys = (await repo.loadAll()).map((p) => p.vehicleKey).toSet();

    expect(keys, {'VIN1', 'VIN2'});
  });

  test('delete removes the profile but keeps the vehicle and its trips',
      () async {
    await repo.save(_profile('VIN1'));
    final vehicleId = (await db.db.query('vehicle')).single['id']! as int;
    await db.db.insert('trip', {'vehicle_id': vehicleId, 'started_at': 1});

    await repo.delete('VIN1');

    expect(await repo.load('VIN1'), isNull);
    expect(await db.db.query('vehicle'), hasLength(1));
    expect(await db.db.query('trip'), hasLength(1));
  });

  test('saving never wipes the telemetry of an existing vehicle', () async {
    await repo.save(_profile('VIN1'));
    final vehicleId = (await db.db.query('vehicle')).single['id']! as int;
    final trip =
        await db.db.insert('trip', {'vehicle_id': vehicleId, 'started_at': 1});
    await db.db.insert(
      'telemetry_sample',
      {'trip_id': trip, 'ts': 1, 'pid': '0C', 'value': 1.0},
    );

    await repo.save(_profile('VIN1', pids: const {'05'}));

    expect(await db.db.query('telemetry_sample'), hasLength(1));
  });

  test('a damaged row counts as not found', () async {
    await repo.save(_profile('VIN1'));
    await repo.save(_profile('VIN2'));
    await db.db.update(
      'capability_profile',
      {'supported_pids': '{not json'},
      where: 'vehicle_id = (SELECT id FROM vehicle WHERE vehicle_key = ?)',
      whereArgs: ['VIN1'],
    );

    expect(await repo.load('VIN1'), isNull);
    expect((await repo.loadAll()).map((p) => p.vehicleKey), ['VIN2']);
  });
}
