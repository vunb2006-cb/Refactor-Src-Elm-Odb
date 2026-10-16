import 'package:elm_obd2/core/obd/jobs/default_jobs.dart';
import 'package:elm_obd2/core/obd/jobs/job_definition.dart';
import 'package:elm_obd2/core/obd/jobs/job_definition_repository.dart';
import 'package:elm_obd2/core/storage/local_database.dart';
import 'package:elm_obd2/core/storage/repositories/sqlite_job_definition_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef _Make = Future<JobDefinitionRepository> Function(
  List<JobDefinition> defaults,
);

JobDefinition _default(String pid) =>
    defaultJobs.firstWhere((j) => j.pid == pid);

/// Behaviour every implementation must have.
void _contract(_Make make) {
  test('seedDefaults on an empty repository adds every default', () async {
    final repo = await make(defaultJobs);

    expect(await repo.seedDefaults(), 21);
    expect(await repo.loadAll(), hasLength(21));
  });

  test('seedDefaults twice adds nothing the second time', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();

    expect(await repo.seedDefaults(), 0);
    expect(await repo.loadAll(), hasLength(21));
  });

  test('loadAll is in serving order', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();

    final first = (await repo.loadAll()).take(4).map((j) => j.pid);

    expect(first, ['0C', '0D', '11', '04']);
  });

  test('seedDefaults never overwrites a job the user changed', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();
    await repo.save(_default('0C').copyWith(periodMs: 1000, enabled: false));

    expect(await repo.seedDefaults(), 0);

    final j = (await repo.load('0C'))!;
    expect(j.periodMs, 1000);
    expect(j.enabled, isFalse);
  });

  test('seedDefaults restores only a PID that was deleted', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();
    await repo.save(_default('0C').copyWith(periodMs: 1000));
    await repo.delete('05');

    expect(await repo.seedDefaults(), 1);

    expect(await repo.load('05'), _default('05'));
    expect((await repo.load('0C'))!.periodMs, 1000);
  });

  test('resetToDefault puts one PID back to its defaults', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();
    await repo.save(
      _default('0C').copyWith(periodMs: 1500, priority: 5, enabled: false),
    );

    await repo.resetToDefault('0C');

    expect(await repo.load('0C'), _default('0C'));
  });

  test('resetToDefault of a PID with no default is rejected', () async {
    final repo = await make(defaultJobs);
    await expectLater(
      repo.resetToDefault('77'),
      throwsA(isA<InvalidJobException>()),
    );
  });

  test('save inserts a new job and gives it an id', () async {
    final repo = await make(defaultJobs);

    await repo.save(const JobDefinition(pid: '77', periodMs: 3000));

    final j = (await repo.load('77'))!;
    expect(j.id, isNotNull);
    expect(j.periodMs, 3000);
  });

  test('save updates the job of the same PID instead of adding another',
      () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();

    await repo.save(_default('0D').copyWith(periodMs: 800));

    expect(await repo.loadAll(), hasLength(21));
    expect((await repo.load('0D'))!.periodMs, 800);
  });

  test('save rejects invalid values and stores nothing', () async {
    final repo = await make(defaultJobs);

    await expectLater(
      repo.save(const JobDefinition(pid: '0C', periodMs: 10)),
      throwsA(isA<InvalidJobException>()),
    );

    expect(await repo.load('0C'), isNull);
  });

  test('the timeout can be set and cleared', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();

    await repo.save(_default('0C').copyWith(timeoutMs: 1500));
    expect((await repo.load('0C'))!.timeoutMs, 1500);

    await repo.save((await repo.load('0C'))!.copyWith(clearTimeout: true));
    expect((await repo.load('0C'))!.timeoutMs, isNull);
  });

  test('setEnabled switches a job on and off', () async {
    final repo = await make(defaultJobs);
    await repo.seedDefaults();

    await repo.setEnabled('0B', true);
    expect((await repo.load('0B'))!.enabled, isTrue);

    await repo.setEnabled('0B', false);
    expect((await repo.load('0B'))!.enabled, isFalse);
  });

  test('setEnabled on an unknown PID is rejected', () async {
    final repo = await make(defaultJobs);
    await expectLater(
      repo.setEnabled('77', true),
      throwsA(isA<InvalidJobException>()),
    );
  });

  test('a custom defaults list is what gets seeded and reset', () async {
    const custom = [
      JobDefinition(pid: 'A1', periodMs: 1000),
      JobDefinition(pid: 'A2', periodMs: 2000, enabled: false),
    ];
    final repo = await make(custom);

    expect(await repo.seedDefaults(), 2);
    await repo.resetToDefault('A2');
    await expectLater(
      repo.resetToDefault('0C'),
      throwsA(isA<InvalidJobException>()),
    );
  });
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('InMemoryJobDefinitionRepository', () {
    _contract((defaults) async =>
        InMemoryJobDefinitionRepository(defaults: defaults));
  });

  group('SqliteJobDefinitionRepository', () {
    _contract((defaults) async {
      final db = await LocalDatabase.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      return SqliteJobDefinitionRepository(db, defaults: defaults);
    });

    test('the database itself refuses a second job for the same PID',
        () async {
      final (database, repo) = await _openSqlite();
      await repo.save(const JobDefinition(pid: '0C', periodMs: 500));

      await expectLater(
        database.db.insert('job_def', {'pid': '0C', 'period_ms': 1000}),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('stores the flags as integers and the timeout as NULL when unset',
        () async {
      final (database, repo) = await _openSqlite();
      await repo.save(
        const JobDefinition(pid: '0C', periodMs: 500, enabled: false),
      );

      final row = (await database.db.query('job_def')).single;

      expect(row['enabled'], 0);
      expect(row['timeout_ms'], isNull);
    });

    test('a manual edit of the table is picked up by loadAll', () async {
      final (database, repo) = await _openSqlite();
      await repo.seedDefaults();

      await database.db.update(
        'job_def',
        {'period_ms': 4321},
        where: 'pid = ?',
        whereArgs: ['0C'],
      );

      expect((await repo.load('0C'))!.periodMs, 4321);
    });
  });
}

Future<(LocalDatabase, SqliteJobDefinitionRepository)> _openSqlite() async {
  final db = await LocalDatabase.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfi,
  );
  addTearDown(db.close);
  return (db, SqliteJobDefinitionRepository(db));
}
