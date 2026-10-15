import 'dart:async';

import 'package:elm_obd2/core/obd/elm_client.dart';
import 'package:elm_obd2/core/obd/reconnect/reconnect_policy.dart';
import 'package:elm_obd2/core/obd/reconnect/reconnect_status.dart';
import 'package:elm_obd2/core/obd/reconnect/reconnect_supervisor.dart';
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

const _tiny = ReconnectPolicy(
  delays: [Duration(milliseconds: 10), Duration(milliseconds: 20)],
  jitter: 0,
  giveUpAfter: Duration(seconds: 5),
);

class _Rig {
  _Rig(this.link, this.client, this.sup);
  final FakeByteTransport link;
  final ElmClient client;
  final ReconnectSupervisor sup;
}

_Rig _rig({
  ReconnectPolicy policy = _tiny,
  FutureOr<void> Function(String)? onReconnected,
  Duration drain = const Duration(seconds: 4),
}) {
  final link = FakeByteTransport();
  final client = ElmClient(
    link,
    initProfile: _quick,
    timeouts: _fast,
    drainTimeout: drain,
  );
  final sup = ReconnectSupervisor(
    client,
    policy: policy,
    onReconnected: onReconnected,
  )..start();
  addTearDown(() async {
    sup.dispose();
    await client.disconnect();
  });
  return _Rig(link, client, sup);
}

Future<void> _until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _pause([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('reconnects by itself after the link is lost', () async {
    final r = _rig();
    await r.client.connect('AA:BB');

    await r.link.dropLink();

    await _until(() =>
        r.client.isConnected &&
        r.link.connectCalls == 2 &&
        r.sup.status.phase == ReconnectPhase.idle);
  });

  test('does not reconnect after the user disconnects', () async {
    final r = _rig();
    await r.client.connect('AA:BB');

    await r.client.disconnect();
    await _pause();

    expect(r.link.connectCalls, 1);
    expect(r.sup.status.phase, ReconnectPhase.idle);
  });

  test('a first connection that fails never starts a reconnect loop',
      () async {
    final r = _rig();
    r.link.connectError = StateError('no device');

    await expectLater(r.client.connect('AA:BB'), throwsA(isA<StateError>()));
    await _pause();

    expect(r.link.connectCalls, 1);
    expect(r.sup.status.phase, ReconnectPhase.idle);
  });

  test('keeps retrying while attempts fail, then succeeds', () async {
    final r = _rig();
    await r.client.connect('AA:BB');
    r.link.connectError = StateError('no link');

    await r.link.dropLink();
    await _until(() => r.link.connectCalls >= 5);
    expect(r.sup.status.phase, isNot(ReconnectPhase.idle));
    expect(r.sup.status.phase, isNot(ReconnectPhase.gaveUp));

    r.link.connectError = null;
    await _until(() => r.client.isConnected);
    await _until(() => r.sup.status.phase == ReconnectPhase.idle);
  });

  test('gives up when the time budget runs out and then stops trying',
      () async {
    final r = _rig(
      policy: const ReconnectPolicy(
        delays: [Duration(milliseconds: 10)],
        jitter: 0,
        giveUpAfter: Duration(milliseconds: 120),
      ),
    );
    await r.client.connect('AA:BB');
    r.link.connectError = StateError('no link');

    await r.link.dropLink();
    await _until(() => r.sup.status.phase == ReconnectPhase.gaveUp);

    expect(r.sup.status.giveUpReason, ReconnectGiveUpReason.timeExpired);
    final calls = r.link.connectCalls;
    await _pause();
    expect(r.link.connectCalls, calls);
  });

  test('retryNow starts again after giving up', () async {
    final r = _rig(
      policy: const ReconnectPolicy(
        delays: [Duration(milliseconds: 10)],
        jitter: 0,
        giveUpAfter: Duration(milliseconds: 80),
      ),
    );
    await r.client.connect('AA:BB');
    r.link.connectError = StateError('no link');
    await r.link.dropLink();
    await _until(() => r.sup.status.phase == ReconnectPhase.gaveUp);

    r.link.connectError = null;
    r.sup.retryNow();

    await _until(() => r.client.isConnected);
    await _until(() => r.sup.status.phase == ReconnectPhase.idle);
  });

  test('a rejected init step is fatal: one attempt, then gives up', () async {
    final r = _rig();
    await r.client.connect('AA:BB');
    r.link.replies['ATE0'] = '?';

    await r.link.dropLink();
    await _until(() => r.sup.status.phase == ReconnectPhase.gaveUp);
    await _pause(80);

    expect(r.sup.status.giveUpReason, ReconnectGiveUpReason.fatalError);
    expect(r.sup.status.lastError, isA<ElmInitException>());
    expect(r.link.connectCalls, 2); // the first connect plus one attempt
  });

  test('an adapter that stops answering also triggers a reconnect', () async {
    final r = _rig(drain: const Duration(milliseconds: 100));
    r.link.replies['0100'] = '41 00 BE 3E B8 11';
    await r.client.connect('AA:BB');
    await r.client.sendCommand('0100'); // protocol counts as detected

    r.link.silent.add('010C');
    await expectLater(
      r.client.sendCommand('010C'),
      throwsA(isA<TimeoutException>()),
    );
    r.link.silent.clear();

    await _until(() => r.link.connectCalls == 2 && r.client.isConnected);
  });

  test('a disconnect while waiting cancels the loop', () async {
    final r = _rig(
      policy: const ReconnectPolicy(
        delays: [Duration(milliseconds: 300)],
        jitter: 0,
        giveUpAfter: Duration(seconds: 5),
      ),
    );
    await r.client.connect('AA:BB');
    await r.link.dropLink();
    await _until(() => r.sup.status.phase == ReconnectPhase.waiting);

    await r.client.disconnect();
    await _pause(450);

    expect(r.link.connectCalls, 1);
    expect(r.sup.status.phase, ReconnectPhase.idle);
  });

  test('a manual connect while waiting takes over from the loop', () async {
    final r = _rig(
      policy: const ReconnectPolicy(
        delays: [Duration(milliseconds: 300)],
        jitter: 0,
        giveUpAfter: Duration(seconds: 5),
      ),
    );
    await r.client.connect('AA:BB');
    await r.link.dropLink();
    await _until(() => r.sup.status.phase == ReconnectPhase.waiting);

    await r.client.connect('AA:BB');
    await _pause(450);

    expect(r.link.connectCalls, 2); // first connect + the manual one only
    expect(r.client.isConnected, isTrue);
    expect(r.sup.status.phase, ReconnectPhase.idle);
  });

  test('onReconnected is called once with the adapter address', () async {
    final calls = <String>[];
    final r = _rig(onReconnected: calls.add);
    await r.client.connect('AA:BB');

    await r.link.dropLink();
    await _until(() => calls.isNotEmpty);
    await _pause(80);

    expect(calls, ['AA:BB']);
  });

  test('an error thrown by onReconnected is ignored', () async {
    final r = _rig(onReconnected: (_) => throw StateError('boom'));
    await r.client.connect('AA:BB');

    await r.link.dropLink();

    await _until(() =>
        r.client.isConnected &&
        r.link.connectCalls == 2 &&
        r.sup.status.phase == ReconnectPhase.idle);
  });

  test('a second outage after a successful reconnect is handled too',
      () async {
    final r = _rig();
    await r.client.connect('AA:BB');
    await r.link.dropLink();
    await _until(() => r.link.connectCalls == 2 && r.client.isConnected);
    await _until(() => r.sup.status.phase == ReconnectPhase.idle);

    await r.link.dropLink();

    await _until(() => r.link.connectCalls == 3 && r.client.isConnected);
  });
}
