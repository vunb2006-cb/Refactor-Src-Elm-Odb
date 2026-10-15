import 'dart:async';

import 'package:elm_obd2/core/obd/elm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_byte_transport.dart';

void main() {
  const initSequence = ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'];

  test('connect runs the ELM327 init sequence in order and ends connected',
      () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);

    await client.connect('AA:BB');

    expect(link.written, initSequence);
    expect(client.state, Elm327State.connected);
    expect(client.isConnected, isTrue);
    expect(client.lastConnectedAddress, 'AA:BB');
  });

  test('state stream reports connecting, initializing, connected', () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);
    final states = <Elm327State>[];
    client.stateStream.listen(states.add);

    await client.connect('AA:BB');
    await Future<void>.delayed(Duration.zero);

    expect(states, [
      Elm327State.connecting,
      Elm327State.initializing,
      Elm327State.connected,
    ]);
  });

  test('sendCommand returns the reply without the > prompt, trimmed',
      () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);
    await client.connect('AA:BB');
    link.replies['010C'] = '41 0C 1A F8';

    expect(await client.sendCommand('010C'), '41 0C 1A F8');
  });

  test('commands are strictly serial: the next is written only after a reply',
      () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);
    await client.connect('AA:BB');

    link.autoRespond = false;
    link.written.clear();

    final first = client.sendCommand('010C');
    final second = client.sendCommand('010D');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(link.written, ['010C']); // second is still queued

    link.reply('41 0C 00 00');
    expect(await first, '41 0C 00 00');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(link.written, ['010C', '010D']);

    link.reply('41 0D 32');
    expect(await second, '41 0D 32');
  });

  test('link drop fails the pending command and reports disconnected',
      () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);
    await client.connect('AA:BB');

    link.autoRespond = false;
    final pending = client.sendCommand('010C');
    final pendingResult = expectLater(pending, throwsA(isA<StateError>()));

    await link.dropLink();
    await pendingResult;

    expect(client.state, Elm327State.disconnected);
    expect(client.isConnected, isFalse);
  });

  test('transport connect failure sets error state and rethrows', () async {
    final link = FakeByteTransport()..connectError = StateError('no device');
    final client = ElmClient(link);

    await expectLater(client.connect('AA:BB'), throwsA(isA<StateError>()));

    expect(client.state, Elm327State.error);
    expect(link.written, isEmpty);
  });

  test('sendCommand before connecting throws StateError', () {
    final client = ElmClient(FakeByteTransport());
    expect(() => client.sendCommand('010C'), throwsStateError);
  });

  test('disconnect closes the link and ends disconnected', () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);
    await client.connect('AA:BB');

    await client.disconnect();

    expect(link.isConnected, isFalse);
    expect(client.state, Elm327State.disconnected);
  });

  test('connect is ignored while already connected', () async {
    final link = FakeByteTransport();
    final client = ElmClient(link);
    await client.connect('AA:BB');

    await client.connect('AA:BB');

    expect(link.connectCalls, 1);
  });
}
