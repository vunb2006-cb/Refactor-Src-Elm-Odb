import 'package:elm_obd2/core/obd/elm_client.dart';
import 'package:elm_obd2/core/obd/reconnect/reconnect_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = ReconnectPolicy();

  group('delayFor', () {
    test('follows the schedule and repeats the last value', () {
      expect(policy.delayFor(1), const Duration(seconds: 1));
      expect(policy.delayFor(2), const Duration(seconds: 2));
      expect(policy.delayFor(3), const Duration(seconds: 4));
      expect(policy.delayFor(4), const Duration(seconds: 8));
      expect(policy.delayFor(5), const Duration(seconds: 15));
      expect(policy.delayFor(6), const Duration(seconds: 30));
      expect(policy.delayFor(7), const Duration(seconds: 30));
      expect(policy.delayFor(50), const Duration(seconds: 30));
    });

    test('jitter stays within plus or minus 20 percent', () {
      expect(policy.delayFor(3, 0.0), const Duration(milliseconds: 3200));
      expect(policy.delayFor(3, 0.5), const Duration(milliseconds: 4000));
      expect(policy.delayFor(3, 1.0), const Duration(milliseconds: 4800));
    });

    test('no jitter when jitter is zero', () {
      const p = ReconnectPolicy(jitter: 0);
      expect(p.delayFor(2, 0.0), const Duration(seconds: 2));
      expect(p.delayFor(2, 1.0), const Duration(seconds: 2));
    });
  });

  group('isRetriable', () {
    test('never after the user disconnected, or with no reason', () {
      expect(policy.isRetriable(ElmDisconnectReason.requested, null), isFalse);
      expect(policy.isRetriable(null, null), isFalse);
    });

    test('ordinary outages are retried', () {
      expect(policy.isRetriable(ElmDisconnectReason.linkLost, null), isTrue);
      expect(policy.isRetriable(ElmDisconnectReason.stalled, null), isTrue);
      expect(
        policy.isRetriable(ElmDisconnectReason.connectFailed, StateError('x')),
        isTrue,
      );
    });

    test('a rejected init step is fatal, other init errors are not', () {
      expect(
        policy.isRetriable(
          ElmDisconnectReason.initFailed,
          ElmInitException('ATE0', '?'),
        ),
        isFalse,
      );
      expect(
        policy.isRetriable(ElmDisconnectReason.initFailed, StateError('x')),
        isTrue,
      );
    });
  });
}
