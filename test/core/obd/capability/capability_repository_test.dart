import 'dart:io';

import 'package:elm_obd2/core/obd/capability/capability_profile.dart';
import 'package:elm_obd2/core/obd/capability/capability_repository.dart';
import 'package:elm_obd2/core/obd/capability/elm_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

CapabilityProfile _profile(String key, {Set<String>? pids}) =>
    CapabilityProfile(
      vehicleKey: key,
      vin: key.startsWith('addr:') ? null : key,
      protocol: ElmProtocol.fromCode('6'),
      supportedPids: pids ?? const {'0C', '0D'},
      probedAt: DateTime.utc(2026, 10, 15),
    );

/// Behaviour every implementation must have.
void _repositoryContract(Future<CapabilityRepository> Function() make) {
  late CapabilityRepository repo;
  setUp(() async => repo = await make());

  test('save then load', () async {
    await repo.save(_profile('VIN1'));
    final p = await repo.load('VIN1');
    expect(p!.supportedPids, {'0C', '0D'});
    expect(p.protocol!.code, '6');
  });

  test('load of an unknown key is null', () async {
    expect(await repo.load('nope'), isNull);
  });

  test('save replaces the previous profile of the same vehicle', () async {
    await repo.save(_profile('VIN1'));
    await repo.save(_profile('VIN1', pids: const {'05'}));
    expect((await repo.load('VIN1'))!.supportedPids, {'05'});
    expect(await repo.loadAll(), hasLength(1));
  });

  test('loadAll and delete', () async {
    await repo.save(_profile('VIN1'));
    await repo.save(_profile('VIN2'));
    expect((await repo.loadAll()).map((p) => p.vehicleKey).toSet(),
        {'VIN1', 'VIN2'});

    await repo.delete('VIN1');
    expect(await repo.load('VIN1'), isNull);
    expect(await repo.loadAll(), hasLength(1));
  });
}

void main() {
  group('InMemoryCapabilityRepository', () {
    _repositoryContract(() async => InMemoryCapabilityRepository());
  });

  group('HiveCapabilityRepository', () {
    late Directory dir;
    late Box<String> box;

    setUpAll(() {
      dir = Directory.systemTemp.createTempSync('hive_capability_');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    _repositoryContract(() async {
      box = await Hive.openBox<String>('caps_${DateTime.now().microsecondsSinceEpoch}');
      return HiveCapabilityRepository(box);
    });

    test('a damaged entry counts as not found', () async {
      final b = await Hive.openBox<String>('caps_damaged');
      final repo = HiveCapabilityRepository(b);
      await b.put('VIN1', '{not json');
      await b.put('VIN2', '{"v": 99, "vehicleKey": "VIN2"}');

      expect(await repo.load('VIN1'), isNull);
      expect(await repo.load('VIN2'), isNull);
      expect(await repo.loadAll(), isEmpty);
    });
  });
}
