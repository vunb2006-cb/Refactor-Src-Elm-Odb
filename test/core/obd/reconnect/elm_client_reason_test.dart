import 'package:elm_obd2/core/obd/elm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_byte_transport.dart';

const _fast = ElmTimeouts(
  command: Duration(milliseconds: 100),
  reset: Duration(milliseconds: 200),
  detect: Duration(milliseconds: 1000),
  slow: Duration(milliseconds: 150),
);

const _quick = ElmInitProfile([
  ElmInitStep('ATZ', mustSucceed: false),
  ElmInitStep('ATE0'),
  ElmInitStep('ATL0'),
  ElmInitStep('ATS0'),
  ElmInitStep('ATH0'),
  ElmInitStep('ATSP0'),
]);

ElmClient _client(FakeByteTransport link, {Duration? drain}) => ElmClient(
      link,
      initProfile: _quick,
      timeouts: _fast,
      drainTimeout: drain ?? const Duration(seconds: 4),
    );

void main() {
  test('a fresh client has no reason; a successful connect clears it',
      () async {
    final link = FakeByteTransport();
    final client = _client(link);
    expect(client.lastDisconnectReason, isNull);

    await client.connect('AA:BB');
    await client.disconnect();
    expect(client.lastDisconnectReason, ElmDisconnectReason.requested);

    await client.connect('AA:BB');
    expect(client.lastDisconnectReason, isNull);
    expect(client.lastError, isNull);
  });

  test('disconnect() is recorded as requested and counted', () async {
    final client = _client(FakeByteTransport());
    await client.connect('AA:BB');
    expect(client.disconnectRequestCount, 0);

    await client.disconnect();

    expect(client.lastDisconnectReason, ElmDisconnectReason.requested);
    expect(client.disconnectRequestCount, 1);
  });

  test('a dropped link is linkLost, and does not count as a request',
      () async {
    final link = FakeByteTransport();
    final client = _client(link);
    await client.connect('AA:BB');

    await link.dropLink();
    await Future<void>.delayed(Duration.zero);

    expect(client.lastDisconnectReason, ElmDisconnectReason.linkLost);
    expect(client.state, Elm327State.disconnected);
    expect(client.disconnectRequestCount, 0);
  });

  test('an adapter that stops answering is stalled', () async {
    final link = FakeByteTransport();
    link.replies['0100'] = '41 00 BE 3E B8 11';
    final client = _client(link, drain: const Duration(milliseconds: 100));
    await client.connect('AA:BB');
    await client.sendCommand('0100'); // protocol counts as detected now

    link.silent.add('010C');
    await expectLater(
      client.sendCommand('010C'),
      throwsA(isA<Exception>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(client.lastDisconnectReason, ElmDisconnectReason.stalled);
    expect(client.state, Elm327State.error);
  });

  test('a link that cannot be opened is connectFailed with its error',
      () async {
    final link = FakeByteTransport()..connectError = StateError('no device');
    final client = _client(link);

    await expectLater(client.connect('AA:BB'), throwsA(isA<StateError>()));

    expect(client.lastDisconnectReason, ElmDisconnectReason.connectFailed);
    expect(client.lastError, isA<StateError>());
  });

  test('a rejected init step is initFailed with the ElmInitException',
      () async {
    final link = FakeByteTransport()..replies['ATE0'] = '?';
    final client = _client(link);

    await expectLater(
      client.connect('AA:BB'),
      throwsA(isA<ElmInitException>()),
    );

    expect(client.lastDisconnectReason, ElmDisconnectReason.initFailed);
    expect(client.lastError, isA<ElmInitException>());
  });
}
