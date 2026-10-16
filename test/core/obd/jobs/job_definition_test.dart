import 'package:elm_obd2/core/obd/capability/capability_profile.dart';
import 'package:elm_obd2/core/obd/jobs/default_jobs.dart';
import 'package:elm_obd2/core/obd/jobs/effective_jobs.dart';
import 'package:elm_obd2/core/obd/jobs/job_definition.dart';
import 'package:elm_obd2/core/obd/pid_constants.dart';
import 'package:flutter_test/flutter_test.dart';

JobDefinition _job({
  String pid = '0C',
  int periodMs = 500,
  int priority = 0,
  int? timeoutMs,
  bool enabled = true,
}) =>
    JobDefinition(
      pid: pid,
      periodMs: periodMs,
      priority: priority,
      timeoutMs: timeoutMs,
      enabled: enabled,
    );

void main() {
  group('validate', () {
    test('a normal job is valid', () {
      expect(_job().validate(), isNull);
    });

    test('PID must be two upper-case hex digits', () {
      for (final bad in ['0c', 'C', '0C0', 'ZZ', '', ' 0C']) {
        expect(_job(pid: bad).validate(), isNotNull, reason: '"$bad"');
      }
      expect(_job(pid: 'FF').validate(), isNull);
    });

    test('period bounds', () {
      expect(_job(periodMs: 59).validate(), isNotNull);
      expect(_job(periodMs: 60).validate(), isNull);
      expect(_job(periodMs: 3600000).validate(), isNull);
      expect(_job(periodMs: 3600001).validate(), isNotNull);
    });

    test('priority bounds', () {
      expect(_job(priority: -1).validate(), isNotNull);
      expect(_job(priority: 0).validate(), isNull);
      expect(_job(priority: 9).validate(), isNull);
      expect(_job(priority: 10).validate(), isNotNull);
    });

    test('timeout is optional and bounded', () {
      expect(_job(timeoutMs: null).validate(), isNull);
      expect(_job(timeoutMs: 49).validate(), isNotNull);
      expect(_job(timeoutMs: 50).validate(), isNull);
      expect(_job(timeoutMs: 30000).validate(), isNull);
      expect(_job(timeoutMs: 30001).validate(), isNotNull);
    });

    test('requireValid throws with the reason', () {
      expect(
        () => _job(periodMs: 10).requireValid(),
        throwsA(isA<InvalidJobException>()
            .having((e) => e.message, 'message', contains('period'))),
      );
      _job().requireValid(); // does not throw
    });
  });

  group('JobDefinition', () {
    test('copyWith changes only what is given', () {
      final a = _job(periodMs: 500, priority: 2, timeoutMs: 800);
      final b = a.copyWith(periodMs: 1000);
      expect(b.periodMs, 1000);
      expect(b.priority, 2);
      expect(b.timeoutMs, 800);
      expect(b.enabled, isTrue);
    });

    test('clearTimeout removes the timeout', () {
      expect(_job(timeoutMs: 800).copyWith(clearTimeout: true).timeoutMs, isNull);
    });

    test('equality ignores the database id', () {
      expect(_job().withId(7), _job().withId(9));
      expect(_job() == _job(periodMs: 600), isFalse);
    });

    test('period is a Duration', () {
      expect(_job(periodMs: 1500).period, const Duration(milliseconds: 1500));
    });
  });

  group('defaultJobs', () {
    test('every default is valid', () {
      for (final j in defaultJobs) {
        expect(j.validate(), isNull, reason: j.toString());
      }
    });

    test('one job per PID the app can decode, no duplicates', () {
      final pids = defaultJobs.map((j) => j.pid).toList();
      expect(pids.toSet().length, pids.length);
      expect(pids.toSet(), PidConstants.names.keys.toSet());
      expect(pids.length, 21);
    });

    test('exactly the seven PIDs the app normally shows are on', () {
      final on = defaultJobs.where((j) => j.enabled).map((j) => j.pid).toSet();
      expect(on, {'0C', '0D', '11', '04', '05', '0F', '2F'});
    });

    test('RPM, speed and throttle are the fastest, highest-priority jobs', () {
      for (final pid in ['0C', '0D', '11']) {
        final j = defaultJobs.firstWhere((j) => j.pid == pid);
        expect(j.periodMs, 500);
        expect(j.priority, 2);
      }
    });

    test('no default sets a timeout (the ELM client policy applies)', () {
      expect(defaultJobs.every((j) => j.timeoutMs == null), isTrue);
    });
  });

  group('effectiveJobs', () {
    CapabilityProfile profile(Set<String> pids) => CapabilityProfile(
          vehicleKey: 'k',
          supportedPids: pids,
          probedAt: DateTime.utc(2026),
        );

    test('keeps only enabled jobs, in serving order', () {
      final pids = effectiveJobs(defaultJobs).map((j) => j.pid).toList();
      expect(pids, ['0C', '0D', '11', '04', '05', '0F', '2F']);
    });

    test('drops jobs the vehicle does not support', () {
      final pids = effectiveJobs(
        defaultJobs,
        profile: profile({'0C', '05', '2F', '0B'}), // 0B is off by default
      ).map((j) => j.pid).toList();
      expect(pids, ['0C', '05', '2F']);
    });

    test('a profile that knows no PIDs means "assume everything"', () {
      expect(
        effectiveJobs(defaultJobs, profile: profile({})).length,
        7,
      );
    });

    test('disabled jobs never run, even when supported', () {
      final all = [_job(pid: '0C', enabled: false), _job(pid: '0D')];
      expect(effectiveJobs(all).map((j) => j.pid), ['0D']);
    });

    test('order: priority, then period, then PID', () {
      final all = [
        _job(pid: '30', periodMs: 1000, priority: 1),
        _job(pid: '20', periodMs: 1000, priority: 1),
        _job(pid: '10', periodMs: 500, priority: 1),
        _job(pid: '40', periodMs: 5000, priority: 3),
      ];
      expect(effectiveJobs(all).map((j) => j.pid), ['40', '10', '20', '30']);
    });
  });
}
