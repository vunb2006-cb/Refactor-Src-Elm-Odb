import 'dart:async';

import 'package:elm_obd2/core/obd/capability/capability_probe.dart';
import 'package:elm_obd2/core/obd/capability/capability_profile.dart';
import 'package:elm_obd2/core/obd/capability/capability_repository.dart';
import 'package:elm_obd2/core/obd/capability/capability_service.dart';
import 'package:elm_obd2/core/obd/obd_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_transport.dart';

const _vin = '1HGCM82633A004352';

/// A vehicle with two PID ranges, a VIN and protocol 6.
Map<String, Object> _vehicle({bool vin = true}) => {
      '0100': '41 00 BE 3E B8 11', // bit 0 set: ask 0120
      '0120': '41 20 80 00 00 00', // bit 0 clear: stop
      'ATDPN': 'A6',
      if (vin) '0900': '49 00 40 00 00 00',
      if (vin) '0902': canVinReply(_vin),
    };

void main() {
  group('CapabilityProbe.readSupportedPids', () {
    test('follows the chain only while bit 0 says there is more', () async {
      final t = ScriptedTransport(_vehicle());
      final pids = await CapabilityProbe(t).readSupportedPids();

      expect(t.sent, ['0100', '0120']);
      expect(pids, containsAll(['01', '0C', '0D', '21']));
    });

    test('keeps going through three ranges', () async {
      final t = ScriptedTransport({
        '0100': '41 00 80 00 00 01',
        '0120': '41 20 80 00 00 01',
        '0140': '41 40 40 00 00 00', // PID 0x42
      });
      final pids = await CapabilityProbe(t).readSupportedPids();

      expect(t.sent, ['0100', '0120', '0140']);
      expect(pids, containsAll(['01', '21', '42']));
    });

    test('stops on NO DATA and keeps what it already has', () async {
      final t = ScriptedTransport({'0100': '41 00 80 00 00 01'});
      final pids = await CapabilityProbe(t).readSupportedPids();

      expect(t.sent, ['0100', '0120']);
      expect(pids, containsAll(['01', '20']));
    });

    test('a failure on the first range gives an empty set', () async {
      final t = ScriptedTransport({'0100': TimeoutException('x')});
      expect(await CapabilityProbe(t).readSupportedPids(), isEmpty);
      expect(t.sent, ['0100']);
    });
  });

  group('CapabilityProbe.readVin', () {
    test('asks for 0902 only after 0900 says it is supported', () async {
      final t = ScriptedTransport({'0900': '49 00 00 00 00 00'});
      expect(await CapabilityProbe(t).readVin(), isNull);
      expect(t.sent, ['0900']);
    });

    test('reads a CAN VIN', () async {
      final t = ScriptedTransport(_vehicle());
      expect(await CapabilityProbe(t).readVin(), _vin);
    });

    test('an error is just "no VIN"', () async {
      final t = ScriptedTransport({'0900': StateError('gone')});
      expect(await CapabilityProbe(t).readVin(), isNull);
    });
  });

  group('CapabilityProbe.run', () {
    test('builds a full profile', () async {
      final t = ScriptedTransport(_vehicle());
      final now = DateTime.utc(2026, 10, 15, 8);
      final p = await CapabilityProbe(t, clock: () => now)
          .run(adapterAddress: 'AA:BB');

      expect(p.vin, _vin);
      expect(p.vehicleKey, _vin);
      expect(p.protocol!.code, '6');
      expect(p.adapterAddress, 'AA:BB');
      expect(p.hasPidInfo, isTrue);
      expect(p.supports('0C'), isTrue);
      expect(p.supports('62'), isFalse);
      expect(p.probedAt, now);
    });

    test('reads the protocol after the PID chain, not before', () async {
      final t = ScriptedTransport(_vehicle());
      await CapabilityProbe(t).run();
      expect(t.sent.indexOf('ATDPN'), greaterThan(t.sent.indexOf('0100')));
    });

    test('without a VIN the key falls back to the adapter address', () async {
      final t = ScriptedTransport(_vehicle(vin: false));
      final p = await CapabilityProbe(t).run(adapterAddress: 'AA:BB');

      expect(p.vin, isNull);
      expect(p.vehicleKey, 'addr:AA:BB');
    });
  });

  group('CapabilityProfile', () {
    test('JSON round trip', () async {
      final t = ScriptedTransport(_vehicle());
      final p = await CapabilityProbe(t, clock: () => DateTime.utc(2026, 1, 2))
          .run(adapterAddress: 'AA:BB');

      final back = CapabilityProfile.fromJson(p.toJson());

      expect(back.vehicleKey, p.vehicleKey);
      expect(back.vin, p.vin);
      expect(back.protocol, p.protocol);
      expect(back.adapterAddress, p.adapterAddress);
      expect(back.supportedPids, p.supportedPids);
      expect(back.probedAt, p.probedAt);
    });

    test('unknown schema version is rejected', () {
      expect(
        () => CapabilityProfile.fromJson({
          'v': 99,
          'vehicleKey': 'x',
          'probedAt': '2026-01-01T00:00:00Z',
        }),
        throwsFormatException,
      );
    });

    test('empty PID set means unknown, so everything counts as supported', () {
      final p = CapabilityProfile(
        vehicleKey: 'k',
        supportedPids: const {},
        probedAt: DateTime.utc(2026),
      );
      expect(p.hasPidInfo, isFalse);
      expect(p.supports('0C'), isTrue);
    });
  });

  group('CapabilityService', () {
    late DateTime now;
    late InMemoryCapabilityRepository repo;

    setUp(() {
      now = DateTime.utc(2026, 10, 15);
      repo = InMemoryCapabilityRepository();
    });

    CapabilityService service(ScriptedTransport t) =>
        CapabilityService(t, repo, clock: () => now);

    test('first load probes and stores; second load reuses the profile',
        () async {
      final t = ScriptedTransport(_vehicle());
      final s = service(t);

      final first = await s.load(adapterAddress: 'AA:BB');
      expect(t.sent, contains('0120'));
      expect(await repo.load(_vin), isNotNull);

      t.sent.clear();
      now = now.add(const Duration(days: 1));
      final second = await s.load(adapterAddress: 'AA:BB');

      expect(t.sent, ['0900', '0902']); // only the VIN was asked
      expect(second.vehicleKey, first.vehicleKey);
      expect(second.supportedPids, first.supportedPids);
    });

    test('forceRefresh probes again', () async {
      final t = ScriptedTransport(_vehicle());
      final s = service(t);
      await s.load();
      t.sent.clear();

      await s.load(forceRefresh: true);

      expect(t.sent, contains('0120'));
    });

    test('a stored profile older than maxAge is probed again', () async {
      final t = ScriptedTransport(_vehicle());
      final s = service(t);
      await s.load();
      t.sent.clear();

      now = now.add(const Duration(days: 31));
      await s.load();

      expect(t.sent, contains('0120'));
    });

    test('without a VIN the vehicle is always probed again', () async {
      final t = ScriptedTransport(_vehicle(vin: false));
      final s = service(t);
      await s.load(adapterAddress: 'AA:BB');
      t.sent.clear();

      await s.load(adapterAddress: 'AA:BB');

      expect(t.sent, contains('0100'));
    });

    test('a probe that learned no PIDs does not overwrite a good profile',
        () async {
      final good = ScriptedTransport(_vehicle());
      await service(good).load();
      final stored = await repo.load(_vin);

      // Same VIN, but the PID chain fails this time.
      final flaky = ScriptedTransport({
        ..._vehicle(),
        '0100': TimeoutException('x'),
      });
      now = now.add(const Duration(days: 40)); // stale: forces a new probe
      final result = await service(flaky).load();

      expect(result.hasPidInfo, isFalse);
      final after = await repo.load(_vin);
      expect(after!.supportedPids, stored!.supportedPids);
    });
  });

  group('ObdService integration', () {
    test('readSupportedPIDs returns a sorted list and fills the cache',
        () async {
      final svc = ObdService(ScriptedTransport(_vehicle()));

      final pids = await svc.readSupportedPIDs();

      expect(pids, orderedEquals([...pids]..sort()));
      expect(svc.isPidSupported('0C'), isTrue);
      expect(svc.isPidSupported('62'), isFalse);
    });

    test('before any read, every PID counts as supported', () {
      final svc = ObdService(ScriptedTransport({}));
      expect(svc.isPidSupported('62'), isTrue);
    });

    test('probeCapabilities sets the profile; reset clears it', () async {
      final svc = ObdService(ScriptedTransport(_vehicle()));

      final p = await svc.probeCapabilities(adapterAddress: 'AA:BB');
      expect(svc.capability, same(p));
      expect(svc.supportedPids, p.supportedPids);

      svc.resetSupportedPids();
      expect(svc.capability, isNull);
      expect(svc.supportedPids, isEmpty);
    });

    test('applyCapability adopts a stored profile', () {
      final svc = ObdService(ScriptedTransport({}));
      final p = CapabilityProfile(
        vehicleKey: _vin,
        supportedPids: const {'0C', '0D'},
        probedAt: DateTime.utc(2026),
      );

      svc.applyCapability(p);

      expect(svc.isPidSupported('0C'), isTrue);
      expect(svc.isPidSupported('05'), isFalse);
    });
  });
}
