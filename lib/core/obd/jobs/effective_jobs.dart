import '../capability/capability_profile.dart';
import 'job_definition.dart';

/// Order in which due jobs are served: higher priority first, then the one
/// that must run more often, then by PID so the order is stable.
int compareJobs(JobDefinition a, JobDefinition b) {
  final byPriority = b.priority.compareTo(a.priority);
  if (byPriority != 0) return byPriority;
  final byPeriod = a.periodMs.compareTo(b.periodMs);
  if (byPeriod != 0) return byPeriod;
  return a.pid.compareTo(b.pid);
}

/// The jobs that should actually run for one vehicle: switched on AND
/// supported by it, in serving order.
///
/// With no [profile], or a profile that knows no PIDs yet, every enabled job
/// counts (an unknown vehicle is assumed to support everything, as
/// `ObdService` does).
List<JobDefinition> effectiveJobs(
  Iterable<JobDefinition> all, {
  CapabilityProfile? profile,
}) {
  final out = all
      .where((j) => j.enabled && (profile?.supports(j.pid) ?? true))
      .toList()
    ..sort(compareJobs);
  return out;
}
