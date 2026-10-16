/// A reading job: which PID to read, how often, how urgently, and whether it
/// is switched on. Pure data; the scheduler (a later group) acts on it.
class JobDefinition {
  const JobDefinition({
    this.id,
    required this.pid,
    required this.periodMs,
    this.priority = 0,
    this.timeoutMs,
    this.enabled = true,
  });

  static const minPeriodMs = 60;
  static const maxPeriodMs = 60 * 60 * 1000;
  static const minPriority = 0;
  static const maxPriority = 9;
  static const minTimeoutMs = 50;
  static const maxTimeoutMs = 30000;

  static final _pidPattern = RegExp(r'^[0-9A-F]{2}$');

  /// Database row id; null until stored.
  final int? id;

  /// Mode 01 PID, two upper-case hex digits.
  final String pid;

  /// Wanted time between reads.
  final int periodMs;

  /// Higher is served first when several jobs are due at once. This ranks
  /// polling jobs among themselves only; it is unrelated to the priority of
  /// commands such as clearing codes.
  final int priority;

  /// Null means "use the timeout policy of the ELM client".
  final int? timeoutMs;

  final bool enabled;

  Duration get period => Duration(milliseconds: periodMs);

  /// Why this job is not acceptable, or null when it is.
  String? validate() {
    if (!_pidPattern.hasMatch(pid)) {
      return 'PID must be two upper-case hex digits (got "$pid")';
    }
    if (periodMs < minPeriodMs || periodMs > maxPeriodMs) {
      return 'period must be $minPeriodMs..$maxPeriodMs ms (got $periodMs)';
    }
    if (priority < minPriority || priority > maxPriority) {
      return 'priority must be $minPriority..$maxPriority (got $priority)';
    }
    final t = timeoutMs;
    if (t != null && (t < minTimeoutMs || t > maxTimeoutMs)) {
      return 'timeout must be $minTimeoutMs..$maxTimeoutMs ms (got $t)';
    }
    return null;
  }

  /// Throws [InvalidJobException] unless [validate] returns null.
  void requireValid() {
    final problem = validate();
    if (problem != null) throw InvalidJobException(problem);
  }

  JobDefinition withId(int id) => JobDefinition(
        id: id,
        pid: pid,
        periodMs: periodMs,
        priority: priority,
        timeoutMs: timeoutMs,
        enabled: enabled,
      );

  JobDefinition copyWith({
    int? periodMs,
    int? priority,
    int? timeoutMs,
    bool clearTimeout = false,
    bool? enabled,
  }) =>
      JobDefinition(
        id: id,
        pid: pid,
        periodMs: periodMs ?? this.periodMs,
        priority: priority ?? this.priority,
        timeoutMs: clearTimeout ? null : (timeoutMs ?? this.timeoutMs),
        enabled: enabled ?? this.enabled,
      );

  /// Equality of the configuration; [id] is ignored.
  @override
  bool operator ==(Object other) =>
      other is JobDefinition &&
      other.pid == pid &&
      other.periodMs == periodMs &&
      other.priority == priority &&
      other.timeoutMs == timeoutMs &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(pid, periodMs, priority, timeoutMs, enabled);

  @override
  String toString() => 'JobDefinition($pid, ${periodMs}ms, prio $priority'
      '${timeoutMs == null ? '' : ', timeout ${timeoutMs}ms'}'
      '${enabled ? '' : ', off'})';
}

/// A job was rejected because its values are invalid or its PID is unknown.
class InvalidJobException implements Exception {
  InvalidJobException(this.message);

  final String message;

  @override
  String toString() => 'InvalidJobException: $message';
}
