import 'package:sqflite/sqflite.dart';

import '../../obd/jobs/default_jobs.dart';
import '../../obd/jobs/effective_jobs.dart';
import '../../obd/jobs/job_definition.dart';
import '../../obd/jobs/job_definition_repository.dart';
import '../local_database.dart';

/// Job definitions in the `job_def` table (one row per PID, enforced by a
/// unique index since schema v2).
class SqliteJobDefinitionRepository implements JobDefinitionRepository {
  SqliteJobDefinitionRepository(
    this._database, {
    List<JobDefinition> defaults = defaultJobs,
  }) : _defaults = defaults;

  final LocalDatabase _database;
  final List<JobDefinition> _defaults;

  Database get _db => _database.db;

  @override
  Future<List<JobDefinition>> loadAll() async {
    final rows = await _db.query('job_def');
    return rows.map(_fromRow).toList()..sort(compareJobs);
  }

  @override
  Future<JobDefinition?> load(String pid) async {
    final rows = await _db.query(
      'job_def',
      where: 'pid = ?',
      whereArgs: [pid],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<void> save(JobDefinition job) async {
    job.requireValid();
    await _db.transaction((txn) => _upsert(txn, job));
  }

  @override
  Future<int> seedDefaults() async {
    for (final d in _defaults) {
      d.requireValid();
    }
    return _db.transaction((txn) async {
      var added = 0;
      for (final d in _defaults) {
        final existing = await txn.query(
          'job_def',
          columns: ['id'],
          where: 'pid = ?',
          whereArgs: [d.pid],
          limit: 1,
        );
        if (existing.isNotEmpty) continue;
        await txn.insert('job_def', _toRow(d));
        added++;
      }
      return added;
    });
  }

  @override
  Future<void> resetToDefault(String pid) async {
    final d = _defaults.where((j) => j.pid == pid);
    if (d.isEmpty) throw InvalidJobException('No default job for PID $pid');
    await save(d.first);
  }

  @override
  Future<void> setEnabled(String pid, bool enabled) async {
    final changed = await _db.update(
      'job_def',
      {'enabled': enabled ? 1 : 0},
      where: 'pid = ?',
      whereArgs: [pid],
    );
    if (changed == 0) throw InvalidJobException('No job for PID $pid');
  }

  @override
  Future<void> delete(String pid) async {
    await _db.delete('job_def', where: 'pid = ?', whereArgs: [pid]);
  }

  Future<void> _upsert(Transaction txn, JobDefinition job) async {
    final changed = await txn.update(
      'job_def',
      _toRow(job),
      where: 'pid = ?',
      whereArgs: [job.pid],
    );
    if (changed == 0) await txn.insert('job_def', _toRow(job));
  }

  Map<String, Object?> _toRow(JobDefinition j) => {
        'pid': j.pid,
        'period_ms': j.periodMs,
        'priority': j.priority,
        'timeout_ms': j.timeoutMs,
        'enabled': j.enabled ? 1 : 0,
      };

  JobDefinition _fromRow(Map<String, Object?> row) => JobDefinition(
        id: row['id']! as int,
        pid: row['pid']! as String,
        periodMs: row['period_ms']! as int,
        priority: row['priority']! as int,
        timeoutMs: row['timeout_ms'] as int?,
        enabled: (row['enabled']! as int) != 0,
      );
}
