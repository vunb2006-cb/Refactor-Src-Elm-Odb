import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'database_migrations.dart';

/// The app's SQLite database (telemetry, snapshots, upload queue, vehicles).
///
/// Hive keeps handling diagnostic sessions, intake and settings; this database
/// is for data that is written often and queried by time.
class LocalDatabase {
  LocalDatabase._(this.db, this.path);

  /// Open handle. Repositories take a [LocalDatabase] and use this.
  final Database db;
  final String path;

  static const fileName = 'elm_obd2.db';

  /// Opens (and creates or upgrades) the database.
  ///
  /// [path], [factory] and [migrations] exist for tests: pass
  /// `inMemoryDatabasePath` with the `sqflite_common_ffi` factory to run on a
  /// desktop machine.
  ///
  /// A database whose version is NEWER than the app (a downgrade) fails to
  /// open instead of being silently modified.
  static Future<LocalDatabase> open({
    String? path,
    DatabaseFactory? factory,
    DatabaseMigrations? migrations,
  }) async {
    final f = factory ?? databaseFactory;
    final m = migrations ?? DatabaseMigrations.standard;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), fileName);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: m.version,
        onConfigure: _configure,
        onCreate: m.onCreate,
        onUpgrade: m.onUpgrade,
        onDowngrade: (db, oldVersion, newVersion) async {
          throw StateError(
            'The database is version $oldVersion but this app only knows '
            'version $newVersion. Refusing to open it.',
          );
        },
      ),
    );
    return LocalDatabase._(db, dbPath);
  }

  static Future<void> _configure(Database db) async {
    // SQLite ignores foreign keys unless asked, on every connection.
    await db.execute('PRAGMA foreign_keys = ON');
    // Write-ahead logging makes frequent small writes cheaper. Optional: some
    // setups refuse it, and the database works without.
    try {
      await db.rawQuery('PRAGMA journal_mode = WAL');
    } catch (_) {}
  }

  Future<void> close() => db.close();

  /// Inserts all [rows] into [table] in ONE transaction: either every row is
  /// stored or none is (a constraint failure rolls the whole batch back).
  Future<void> insertBatch(
    String table,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(table, row);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Bytes of database pages in use (the file size minus pages freed by
  /// deletes, which SQLite reuses before growing the file).
  Future<int> usedBytes() async {
    final pageSize =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_size')) ?? 4096;
    final pageCount =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_count')) ?? 0;
    final free =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA freelist_count')) ?? 0;
    return (pageCount - free) * pageSize;
  }
}
