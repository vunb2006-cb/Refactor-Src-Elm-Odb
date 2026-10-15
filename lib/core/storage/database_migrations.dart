import 'package:sqflite/sqflite.dart';

/// One schema step: brings the database from version N to N + 1.
typedef MigrationStep = Future<void> Function(Database db);

/// An ordered list of schema steps; `steps[0]` creates version 1, `steps[1]`
/// upgrades 1 to 2, and so on. The database version is simply the number of
/// steps, so adding a step is the only thing needed to change the schema.
///
/// Rules for new steps:
///  * never edit or remove an existing step (databases in the field already
///    ran it); add a new one at the end;
///  * `sqflite` runs a step inside a transaction, so a failing step leaves the
///    database at the previous version;
///  * one SQL statement per `db.execute` call.
class DatabaseMigrations {
  const DatabaseMigrations(this.steps);

  final List<MigrationStep> steps;

  int get version => steps.length;

  Future<void> onCreate(Database db, int version) => _run(db, 0, version);

  Future<void> onUpgrade(Database db, int oldVersion, int newVersion) =>
      _run(db, oldVersion, newVersion);

  Future<void> _run(Database db, int from, int to) async {
    for (var v = from; v < to; v++) {
      await steps[v](db);
    }
  }

  /// The migrations the app ships with.
  static final standard = DatabaseMigrations([_v1]);
}

/// Schema v1. Times are integer milliseconds since the Unix epoch, UTC.
const schemaV1Statements = <String>[
  // A vehicle is identified by its VIN, or by 'addr:<adapter address>' when it
  // does not report one.
  '''
  CREATE TABLE vehicle (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vehicle_key TEXT NOT NULL UNIQUE,
    vin TEXT,
    adapter_address TEXT,
    label TEXT,
    traccar_device_id TEXT,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE capability_profile (
    vehicle_id INTEGER PRIMARY KEY
      REFERENCES vehicle(id) ON DELETE CASCADE,
    protocol TEXT,
    supported_pids TEXT NOT NULL,
    init_profile TEXT,
    probed_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE trip (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vehicle_id INTEGER NOT NULL REFERENCES vehicle(id) ON DELETE CASCADE,
    started_at INTEGER NOT NULL,
    ended_at INTEGER,
    distance_m REAL
  )
  ''',
  'CREATE INDEX idx_trip_vehicle ON trip(vehicle_id, started_at)',
  '''
  CREATE TABLE job_def (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pid TEXT NOT NULL,
    period_ms INTEGER NOT NULL,
    priority INTEGER NOT NULL DEFAULT 0,
    timeout_ms INTEGER,
    enabled INTEGER NOT NULL DEFAULT 1
  )
  ''',
  // Raw samples: short-lived (see RetentionService).
  '''
  CREATE TABLE telemetry_sample (
    trip_id INTEGER NOT NULL REFERENCES trip(id) ON DELETE CASCADE,
    ts INTEGER NOT NULL,
    pid TEXT NOT NULL,
    value REAL NOT NULL,
    quality INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX idx_sample_trip_ts ON telemetry_sample(trip_id, ts)',
  'CREATE INDEX idx_sample_ts ON telemetry_sample(ts)',
  // A snapshot is the unit that gets uploaded: time, position and the latest
  // value of each PID.
  '''
  CREATE TABLE snapshot (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trip_id INTEGER NOT NULL REFERENCES trip(id) ON DELETE CASCADE,
    ts INTEGER NOT NULL,
    lat REAL,
    lon REAL,
    speed REAL,
    values_json TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_snapshot_trip_ts ON snapshot(trip_id, ts)',
  'CREATE INDEX idx_snapshot_ts ON snapshot(ts)',
  '''
  CREATE TABLE upload_queue (
    snapshot_id INTEGER PRIMARY KEY
      REFERENCES snapshot(id) ON DELETE CASCADE,
    state TEXT NOT NULL
      CHECK (state IN ('pending', 'in_flight', 'sent', 'failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_retry_at INTEGER,
    dedup_key TEXT NOT NULL UNIQUE
  )
  ''',
  'CREATE INDEX idx_queue_state_retry ON upload_queue(state, next_retry_at)',
  '''
  CREATE TABLE runtime_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
];

Future<void> _v1(Database db) async {
  for (final sql in schemaV1Statements) {
    await db.execute(sql);
  }
}
