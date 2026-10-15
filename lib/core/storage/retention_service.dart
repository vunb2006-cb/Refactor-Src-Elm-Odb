import 'local_database.dart';

/// How long data is kept, and how big the database may grow.
class RetentionPolicy {
  const RetentionPolicy({
    this.rawSamples = const Duration(hours: 6),
    this.sentSnapshots = const Duration(days: 7),
    this.unsentSnapshots = const Duration(days: 30),
    this.softCapBytes = 200 * 1024 * 1024,
    this.trimBatch = 2000,
  });

  /// Raw telemetry samples older than this are deleted.
  final Duration rawSamples;

  /// Snapshots already uploaded ('sent') older than this are deleted.
  final Duration sentSnapshots;

  /// Snapshots NOT uploaded (pending, in flight, failed, or never queued) are
  /// kept this long; after it they are deleted even though they never left
  /// the phone.
  final Duration unsentSnapshots;

  /// Soft ceiling for the database size. When exceeded, the oldest raw samples
  /// go first, then the oldest sent snapshots. Unsent snapshots that have not
  /// expired are NEVER deleted for size, so the database can stay above the
  /// cap if they alone exceed it.
  final int softCapBytes;

  /// Rows deleted per step while trimming for size.
  final int trimBatch;
}

class RetentionResult {
  const RetentionResult({
    this.expiredSamples = 0,
    this.expiredSentSnapshots = 0,
    this.expiredUnsentSnapshots = 0,
    this.trimmedSamples = 0,
    this.trimmedSentSnapshots = 0,
  });

  final int expiredSamples;
  final int expiredSentSnapshots;
  final int expiredUnsentSnapshots;
  final int trimmedSamples;
  final int trimmedSentSnapshots;

  bool get deletedAnything =>
      expiredSamples +
          expiredSentSnapshots +
          expiredUnsentSnapshots +
          trimmedSamples +
          trimmedSentSnapshots >
      0;
}

/// Deletes old data according to a [RetentionPolicy]. Nothing calls it yet:
/// run it at app start and now and then while the app is open.
class RetentionService {
  RetentionService(
    this._database, {
    this.policy = const RetentionPolicy(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase _database;
  final RetentionPolicy policy;
  final DateTime Function() _clock;

  Future<RetentionResult> run() async {
    final db = _database.db;
    final now = _clock().toUtc().millisecondsSinceEpoch;

    final expiredSamples = await db.rawDelete(
      'DELETE FROM telemetry_sample WHERE ts < ?',
      [now - policy.rawSamples.inMilliseconds],
    );

    // Deleting a snapshot also deletes its queue row (ON DELETE CASCADE).
    final expiredSent = await db.rawDelete(
      'DELETE FROM snapshot WHERE ts < ? AND id IN '
      '(SELECT snapshot_id FROM upload_queue WHERE state = ?)',
      [now - policy.sentSnapshots.inMilliseconds, 'sent'],
    );

    // Sent ones older than this are already gone, so what remains is unsent.
    final expiredUnsent = await db.rawDelete(
      'DELETE FROM snapshot WHERE ts < ?',
      [now - policy.unsentSnapshots.inMilliseconds],
    );

    var trimmedSamples = 0;
    var trimmedSent = 0;
    while (await _database.usedBytes() > policy.softCapBytes) {
      final samples = await db.rawDelete(
        'DELETE FROM telemetry_sample WHERE rowid IN '
        '(SELECT rowid FROM telemetry_sample ORDER BY ts LIMIT ?)',
        [policy.trimBatch],
      );
      if (samples > 0) {
        trimmedSamples += samples;
        continue;
      }
      final sent = await db.rawDelete(
        'DELETE FROM snapshot WHERE id IN '
        '(SELECT s.id FROM snapshot s '
        'JOIN upload_queue q ON q.snapshot_id = s.id '
        'WHERE q.state = ? ORDER BY s.ts LIMIT ?)',
        ['sent', policy.trimBatch],
      );
      if (sent > 0) {
        trimmedSent += sent;
        continue;
      }
      break; // only unsent data is left: keep it
    }

    return RetentionResult(
      expiredSamples: expiredSamples,
      expiredSentSnapshots: expiredSent,
      expiredUnsentSnapshots: expiredUnsent,
      trimmedSamples: trimmedSamples,
      trimmedSentSnapshots: trimmedSent,
    );
  }
}
