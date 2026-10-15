import 'dart:async';

import 'package:elm_obd2/core/obd/elm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_byte_transport.dart';

// Short timeouts keep these tests fast.
const _fast = ElmTimeouts(
  command: Duration(milliseconds: 100),
  reset: Duration(milliseconds: 200),
  detect: Duration(milliseconds: 1000),
  slow: Duration(milliseconds: 150),
);

// Same commands as ElmInitProfile.standard, without the pause after ATZ.
const _quickProfile = ElmInitProfile([
  ElmInitStep('ATZ', mustSucceed: false),
  ElmInitStep('ATE0'),
  ElmInitStep('ATL0'),
  ElmInitStep('ATS0'),
  ElmInitStep('ATH0'),
  ElmInitStep('ATSP0'),
]);

/// Connects and performs one OBD command so the protocol counts as detected,
/// which means ordinary commands now use the short timeout.
Future<ElmClient> _connected(
  FakeByteTransport link, {
  ElmInitProfile profile = _quickProfile,
  Duration drain = const Duration(seconds: 4),
}) async {
  link.replies['0100'] = '41 00 BE 3E B8 11';
  final client = ElmClient(
    link,
    initProfile: profile,
    timeouts: _fast,
    drainTimeout: drain,
  );
  await client.connect('AA:BB');
  await client.sendCommand('0100');
  addTearDown(client.disconnect);
  return client;
}

void main() {
  group('late replies', () {
    test('a late reply is never attributed to the next command', () async {
      final link = FakeByteTransport();
      final client = await _connected(link);

      link.replies['010C'] = 'LATE-RPM-REPLY';
      link.replyDelay['010C'] = const Duration(milliseconds: 300);
      link.replies['010D'] = '41 0D 32';

      final a = client.sendCommand('010C');
      final b = client.sendCommand('010D');
      final aResult = expectLater(a, throwsA(isA<TimeoutException>()));

      await aResult; // times out after about 100 ms
      expect(link.written.contains('010D'), isFalse,
          reason: 'next command must wait for the late reply prompt');

      expect(await b, '41 0D 32'); // not LATE-RPM-REPLY
      expect(link.written.last, '010D');
    });

    test('adapter that never sends a prompt: pending commands fail, '
        'link closes, state is error', () async {
      final link = FakeByteTransport();
      final client =
          await _connected(link, drain: const Duration(milliseconds: 200));

      link.silent.add('010C');
      final a = client.sendCommand('010C');
      final b = client.sendCommand('010D');
      final aResult = expectLater(a, throwsA(isA<TimeoutException>()));
      final bResult = expectLater(b, throwsA(isA<StateError>()));

      await aResult;
      await bResult;

      expect(client.state, Elm327State.error);
      expect(link.isConnected, isFalse);
    });

    test('disconnect fails commands that were still pending', () async {
      final link = FakeByteTransport();
      final client = await _connected(link);

      link.autoRespond = false;
      final pending = client.sendCommand('010C');
      final pendingResult = expectLater(pending, throwsA(isA<StateError>()));

      await client.disconnect();
      await pendingResult;
    });
  });

  group('init profile', () {
    test('a required step that is not acknowledged fails connect and '
        'closes the link', () async {
      final link = FakeByteTransport()..replies['ATE0'] = '?';
      final client = ElmClient(link, initProfile: _quickProfile, timeouts: _fast);

      await expectLater(
        client.connect('AA:BB'),
        throwsA(isA<ElmInitException>()),
      );

      expect(client.state, Elm327State.error);
      expect(link.isConnected, isFalse);
    });

    test('the exception names the failing command and the reply', () async {
      final link = FakeByteTransport()..replies['ATSP0'] = '?';
      final client = ElmClient(link, initProfile: _quickProfile, timeouts: _fast);

      await expectLater(
        client.connect('AA:BB'),
        throwsA(predicate((e) =>
            e is ElmInitException &&
            e.command == 'ATSP0' &&
            e.response == '?' &&
            e.toString().contains('ATSP0'))),
      );
    });

    test('an optional step may fail without failing connect', () async {
      const profile = ElmInitProfile([
        ElmInitStep('ATZ', mustSucceed: false),
        ElmInitStep('ATE0'),
        ElmInitStep('ATST64', mustSucceed: false),
      ]);
      final link = FakeByteTransport()..replies['ATST64'] = '?';
      final client = ElmClient(link, initProfile: profile, timeouts: _fast);

      await client.connect('AA:BB');

      expect(client.state, Elm327State.connected);
      expect(client.initLog.last.command, 'ATST64');
      expect(client.initLog.last.ok, isFalse);
    });

    test('init log records every step in profile order', () async {
      final link = FakeByteTransport();
      final client = ElmClient(link, initProfile: _quickProfile, timeouts: _fast);

      await client.connect('AA:BB');

      expect(client.initLog.map((r) => r.command),
          ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']);
      expect(client.initLog.every((r) => r.ok), isTrue);
    });

    test('a custom profile is what actually gets written', () async {
      const profile = ElmInitProfile([
        ElmInitStep('ATZ', mustSucceed: false),
        ElmInitStep('ATE0'),
        ElmInitStep('ATSP6'),
      ]);
      final link = FakeByteTransport();
      final client = ElmClient(link, initProfile: profile, timeouts: _fast);

      await client.connect('AA:BB');

      expect(link.written, ['ATZ', 'ATE0', 'ATSP6']);
    });
  });

  group('timeout policy in the client', () {
    test('the first OBD command gets the long detect timeout, '
        'later ones the short one', () async {
      final link = FakeByteTransport();
      final client =
          ElmClient(link, initProfile: _quickProfile, timeouts: _fast);
      await client.connect('AA:BB');
      addTearDown(client.disconnect);

      // Slower than `command` (100 ms) but within `detect` (1000 ms).
      link.replies['0100'] = 'SEARCHING...\r41 00 BE 3E B8 11';
      link.replyDelay['0100'] = const Duration(milliseconds: 300);
      expect(await client.sendCommand('0100'), contains('41 00'));

      // Protocol is detected now, so the same delay is a timeout.
      link.replyDelay['010C'] = const Duration(milliseconds: 300);
      await expectLater(
        client.sendCommand('010C'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('DTC requests get the slow timeout', () async {
      final link = FakeByteTransport();
      final client = await _connected(link);

      // 120 ms: too slow for `command` (100 ms), fine for `slow` (150 ms).
      link.replies['03'] = '43 00';
      link.replyDelay['03'] = const Duration(milliseconds: 120);

      expect(await client.sendCommand('03'), '43 00');
    });
  });
}
