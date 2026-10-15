import 'package:elm_obd2/core/storage/local_database.dart';
import 'package:elm_obd2/core/storage/retention_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _now = DateTime.utc(2026, 10, 15, 12);

int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

Future<LocalDatabase> _open() => LocalDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );

Future<int> _addTrip(LocalDatabase d) async {
  final vehicle =
      await d.db.insert('vehicle', {'vehicle_key': 'VIN1', 'created_at': 1});
  return d.db.insert('trip', {'vehicle_id': vehicle, 'started_at': 1});
}

/// Inserts a snapshot; [state] null means "never queued".
Future<int> _addSnapshot(
  LocalDatabase d,
  int trip,
  int ts,
  String? state, {
  int jsonSize = 10,
}) async {
  final id = await d.db.insert('snapshot', {
    'trip_id': trip,
    'ts': ts,
    'values_json': 'x' * jsonSize,
  });
  if (state != null) {
    await d.db.insert('upload_queue', {
      'snapshot_id': id,
      'state': state,
      'dedup_key': 'k$id',
    });
  }
  return id;
}

Future<int> _count(LocalDatabase d, String table, [String? where]) async {
  final rows = await d.db.rawQuery(
    'SELECT COUNT(*) FROM $table${where == null ? '' : ' WHERE $where'}',
  );
  return rows.first.values.first! as int;
}

Future<List<int>> _ids(LocalDatabase d, String where) async => [
      for (final r in await d.db.query(
        'snapshot',
        columns: ['id'],
        where: where,
        orderBy: 'id',
      ))
        r['id']! as int,
    ];

void main() {
  setUpAll(sqfliteFfiInit);

  RetentionService service(LocalDatabase d, {RetentionPolicy? policy}) =>
      RetentionService(
        d,
        policy: policy ?? const RetentionPolicy(),
        clock: () => _now,
      );

  group('by age', () {
    test('raw samples older than 6 hours are deleted, newer kept', () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      await d.insertBatch('telemetry_sample', [
        {
          'trip_id': trip,
          'ts': _ago(const Duration(hours: 7)),
          'pid': '0C',
          'value': 1.0,
        },
        {
          'trip_id': trip,
          'ts': _ago(const Duration(hours: 5)),
          'pid': '0C',
          'value': 2.0,
        },
      ]);

      final result = await service(d).run();

      expect(result.expiredSamples, 1);
      expect(await _count(d, 'telemetry_sample'), 1);
    });

    test('sent snapshots older than 7 days go, with their queue rows',
        () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      await _addSnapshot(d, trip, _ago(const Duration(days: 8)), 'sent');
      final recent =
          await _addSnapshot(d, trip, _ago(const Duration(days: 2)), 'sent');

      final result = await service(d).run();

      expect(result.expiredSentSnapshots, 1);
      expect(await _ids(d, '1 = 1'), [recent]);
      expect(await _count(d, 'upload_queue'), 1);
    });

    test('unsent snapshots survive past 7 days, up to 30', () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      final ts = _ago(const Duration(days: 10));
      await _addSnapshot(d, trip, ts, 'pending');
      await _addSnapshot(d, trip, ts, 'in_flight');
      await _addSnapshot(d, trip, ts, 'failed');
      await _addSnapshot(d, trip, ts, null); // never queued

      final result = await service(d).run();

      expect(result.deletedAnything, isFalse);
      expect(await _count(d, 'snapshot'), 4);
    });

    test('unsent snapshots older than 30 days are deleted', () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      await _addSnapshot(d, trip, _ago(const Duration(days: 31)), 'pending');
      await _addSnapshot(d, trip, _ago(const Duration(days: 31)), null);
      final kept =
          await _addSnapshot(d, trip, _ago(const Duration(days: 29)), 'pending');

      final result = await service(d).run();

      expect(result.expiredUnsentSnapshots, 2);
      expect(await _ids(d, '1 = 1'), [kept]);
    });

    test('running twice deletes nothing the second time', () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      await _addSnapshot(d, trip, _ago(const Duration(days: 8)), 'sent');

      await service(d).run();
      final second = await service(d).run();

      expect(second.deletedAnything, isFalse);
    });
  });

  group('size cap', () {
    test('trims raw samples first and leaves snapshots alone', () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      for (var i = 0; i < 5; i++) {
        await _addSnapshot(d, trip, _ago(const Duration(minutes: 5)), 'sent');
      }
      await d.insertBatch('telemetry_sample', [
        for (var i = 0; i < 20000; i++)
          {
            'trip_id': trip,
            'ts': _ago(const Duration(hours: 1)) + i,
            'pid': '0C',
            'value': i.toDouble(),
          },
      ]);
      const cap = 200 * 1024;
      expect(await d.usedBytes(), greaterThan(cap));

      final result = await service(
        d,
        policy: const RetentionPolicy(softCapBytes: cap, trimBatch: 1000),
      ).run();

      expect(await d.usedBytes(), lessThanOrEqualTo(cap));
      expect(result.trimmedSamples, greaterThan(0));
      expect(result.trimmedSentSnapshots, 0);
      expect(await _count(d, 'snapshot'), 5);
    });

    test('then trims the OLDEST sent snapshots, never unsent ones', () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      for (var i = 0; i < 20; i++) {
        await _addSnapshot(
          d,
          trip,
          _ago(const Duration(hours: 3)) + i, // ascending: id order = age order
          'sent',
          jsonSize: 50000,
        );
      }
      for (var i = 0; i < 5; i++) {
        await _addSnapshot(
          d,
          trip,
          _ago(const Duration(hours: 1)) + i,
          'pending',
          jsonSize: 50000,
        );
      }
      const cap = 400 * 1024;
      expect(await d.usedBytes(), greaterThan(cap));

      final result = await service(
        d,
        policy: const RetentionPolicy(softCapBytes: cap, trimBatch: 1),
      ).run();

      expect(await d.usedBytes(), lessThanOrEqualTo(cap));
      expect(result.trimmedSentSnapshots, greaterThan(0));
      expect(await _count(d, 'upload_queue', "state = 'pending'"), 5);

      final remainingSent = await _ids(
        d,
        "id IN (SELECT snapshot_id FROM upload_queue WHERE state = 'sent')",
      );
      expect(remainingSent.length, lessThan(20));
      // Oldest first: what is left is the newest run of ids, with no gaps.
      for (var i = 0; i < remainingSent.length; i++) {
        expect(remainingSent[i], 20 - remainingSent.length + 1 + i);
      }
    });

    test('unsent snapshots are kept even if they alone exceed the cap',
        () async {
      final d = await _open();
      addTearDown(d.close);
      final trip = await _addTrip(d);
      for (var i = 0; i < 20; i++) {
        await _addSnapshot(
          d,
          trip,
          _ago(const Duration(hours: 1)) + i,
          'pending',
          jsonSize: 50000,
        );
      }
      const cap = 100 * 1024;

      final result = await service(
        d,
        policy: const RetentionPolicy(softCapBytes: cap),
      ).run();

      expect(await d.usedBytes(), greaterThan(cap));
      expect(result.trimmedSentSnapshots, 0);
      expect(await _count(d, 'snapshot'), 20);
    });
  });
}
