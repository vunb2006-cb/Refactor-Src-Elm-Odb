import 'dart:async';

import 'package:elm_obd2/core/obd/bus/bus_priority.dart';
import 'package:elm_obd2/core/obd/bus/obd_command_bus.dart';
import 'package:elm_obd2/core/obd/obd_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'manual_transport.dart';

/// Lets queued microtasks (the bus sending the next command) run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late ManualTransport t;
  late ObdCommandBus bus;

  setUp(() {
    t = ManualTransport();
    bus = ObdCommandBus(t);
  });

  test('sends a command and returns the reply', () async {
    final f = bus.send('010C');
    expect(t.sent, ['010C']);

    t.reply('41 0C 1A F8');

    expect(await f, '41 0C 1A F8');
    expect(bus.completedCount, 1);
  });

  test('only one command is in flight; the next goes out after the reply',
      () async {
    final a = bus.send('A');
    final b = bus.send('B');
    expect(t.sent, ['A']);
    expect(bus.queueLength, 1);

    t.reply('ra');
    await a;
    await _settle();

    expect(t.sent, ['A', 'B']);
    t.reply('rb');
    expect(await b, 'rb');
  });

  test('urgent commands overtake, and equal levels stay first in first out',
      () async {
    final futures = <Future<String>>[
      bus.send('first'), // goes out at once
      bus.send('low1', priority: BusPriority.low),
      bus.send('normal1'),
      bus.send('high1', priority: BusPriority.high),
      bus.send('critical1', priority: BusPriority.critical),
      bus.send('high2', priority: BusPriority.high),
      bus.send('low2', priority: BusPriority.low),
    ];

    for (var i = 0; i < futures.length; i++) {
      t.reply('ok');
      await _settle();
    }
    await Future.wait(futures);

    expect(t.sent, [
      'first',
      'critical1',
      'high1',
      'high2',
      'normal1',
      'low1',
      'low2',
    ]);
  });

  test('a full queue refuses new commands and keeps the waiting ones',
      () async {
    final small = ObdCommandBus(t, maxQueue: 3);
    final inFlight = small.send('a');
    final waiting = [small.send('b'), small.send('c'), small.send('d')];

    await expectLater(small.send('e'), throwsA(isA<BusQueueFullException>()));

    expect(small.queueLength, 3);
    expect(small.rejectedCount, 1);

    for (var i = 0; i < 4; i++) {
      t.reply('ok');
      await _settle();
    }
    await Future.wait([inFlight, ...waiting]);
    expect(t.sent, ['a', 'b', 'c', 'd']);
  });

  test('a command that waits too long fails and is never sent late',
      () async {
    final quick = ObdCommandBus(
      t,
      waitTimeouts: {BusPriority.low: const Duration(milliseconds: 50)},
    );
    final blocker = quick.send('blocker'); // never answered for now
    final late = quick.send('late', priority: BusPriority.low);

    await expectLater(late, throwsA(isA<TimeoutException>()));
    t.reply('done');
    await blocker;
    await _settle();

    expect(t.sent, ['blocker']);
    expect(quick.expiredCount, 1);
    expect(quick.queueLength, 0);
  });

  test('fails at once when the transport is not connected', () async {
    t.connected = false;

    await expectLater(bus.send('010C'), throwsA(isA<StateError>()));

    expect(t.sent, isEmpty);
    expect(bus.queueLength, 0);
  });

  test('an error fails only the command it belongs to', () async {
    final a = bus.send('A');
    final b = bus.send('B');
    final aResult = expectLater(a, throwsA(isA<StateError>()));

    t.fail(StateError('boom'));
    await aResult;
    await _settle();
    t.reply('rb');

    expect(await b, 'rb');
    expect(bus.failedCount, 1);
  });

  test('losing the connection fails the commands still waiting', () async {
    final a = bus.send('A');
    final b = bus.send('B');
    final aResult = expectLater(a, throwsA(isA<StateError>()));
    final bResult = expectLater(b, throwsA(isA<StateError>()));

    t.connected = false; // B will be refused when its turn comes
    t.fail(StateError('link lost'));

    await aResult;
    await bResult;
  });

  test('it is an ObdTransport: sendCommand and connection info pass through',
      () async {
    final f = bus.sendCommand('010D');
    expect(t.sent, ['010D']);
    t.reply('41 0D 32');
    expect(await f, '41 0D 32');

    expect(bus.isConnected, isTrue);
    expect(bus.lastConnectedAddress, 'TEST');
    t.connected = false;
    expect(bus.isConnected, isFalse);
  });

  test('dispose fails waiting commands but leaves the transport alone',
      () async {
    final a = bus.send('A');
    final b = bus.send('B');
    final bResult = expectLater(b, throwsA(isA<StateError>()));

    bus.dispose();

    await bResult;
    expect(bus.queueLength, 0);
    await expectLater(bus.send('C'), throwsA(isA<StateError>()));
    t.reply('ra'); // the command already out still completes
    expect(await a, 'ra');
  });

  test('average latency appears after the first command', () async {
    expect(bus.averageLatency, isNull);

    final f = bus.send('A');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    t.reply('ra');
    await f;

    expect(bus.averageLatency, isNotNull);
    expect(bus.averageLatency! >= Duration.zero, isTrue);
  });

  group('ObdService passes the priority on', () {
    test('fault codes overtake one-off reads, which overtake polling',
        () async {
      final service = ObdService(bus);

      final running = service.readPID('0C'); // goes out first
      final polling = service.readPID('0D', priority: BusPriority.low);
      final oneOff = service.readPID('0F');
      final codes = service.readDTCs();

      t.reply('41 0C 1A F8');
      await running;
      await _settle();
      t.reply('43 00 00'); // fault codes, sent next
      await codes;
      await _settle();
      t.reply('41 0F 50');
      await oneOff;
      await _settle();
      t.reply('41 0D 32');
      await polling;

      expect(t.sent, ['010C', '03', '010F', '010D']);
    });
  });
}
