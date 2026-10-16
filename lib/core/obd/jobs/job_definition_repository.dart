import 'default_jobs.dart';
import 'effective_jobs.dart';
import 'job_definition.dart';

/// Where job definitions are kept. One job per PID.
abstract class JobDefinitionRepository {
  /// Every job, in serving order (see `compareJobs`).
  Future<List<JobDefinition>> loadAll();

  Future<JobDefinition?> load(String pid);

  /// Inserts the job, or updates the one with the same PID. Throws
  /// [InvalidJobException] (and stores nothing) for invalid values.
  Future<void> save(JobDefinition job);

  /// Adds the default jobs that are missing and returns how many were added.
  /// Rows that already exist are never touched, so user edits survive.
  Future<int> seedDefaults();

  /// Puts one PID back to its default values. Throws [InvalidJobException]
  /// when the PID has no default.
  Future<void> resetToDefault(String pid);

  /// Throws [InvalidJobException] when there is no job for [pid].
  Future<void> setEnabled(String pid, bool enabled);

  Future<void> delete(String pid);
}

class InMemoryJobDefinitionRepository implements JobDefinitionRepository {
  InMemoryJobDefinitionRepository({List<JobDefinition> defaults = defaultJobs})
      : _defaults = defaults;

  final List<JobDefinition> _defaults;
  final Map<String, JobDefinition> _jobs = {};
  int _nextId = 1;

  @override
  Future<List<JobDefinition>> loadAll() async =>
      _jobs.values.toList()..sort(compareJobs);

  @override
  Future<JobDefinition?> load(String pid) async => _jobs[pid];

  @override
  Future<void> save(JobDefinition job) async {
    job.requireValid();
    final id = _jobs[job.pid]?.id ?? _nextId++;
    _jobs[job.pid] = job.withId(id);
  }

  @override
  Future<int> seedDefaults() async {
    var added = 0;
    for (final d in _defaults) {
      d.requireValid();
      if (_jobs.containsKey(d.pid)) continue;
      _jobs[d.pid] = d.withId(_nextId++);
      added++;
    }
    return added;
  }

  @override
  Future<void> resetToDefault(String pid) async {
    final d = _defaults.where((j) => j.pid == pid);
    if (d.isEmpty) throw InvalidJobException('No default job for PID $pid');
    await save(d.first);
  }

  @override
  Future<void> setEnabled(String pid, bool enabled) async {
    final job = _jobs[pid];
    if (job == null) throw InvalidJobException('No job for PID $pid');
    _jobs[pid] = job.copyWith(enabled: enabled);
  }

  @override
  Future<void> delete(String pid) async {
    _jobs.remove(pid);
  }
}
