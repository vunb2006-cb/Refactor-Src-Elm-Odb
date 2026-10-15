enum ReconnectPhase {
  /// Nothing to do: connected, or never was, or the user disconnected.
  idle,

  /// Waiting before the next attempt; see [ReconnectStatus.nextAttemptAt].
  waiting,

  /// An attempt is in progress.
  attempting,

  /// Stopped trying; see [ReconnectStatus.giveUpReason].
  gaveUp,
}

enum ReconnectGiveUpReason {
  /// An error that retrying will not fix (a failed init step).
  fatalError,

  /// The policy's total time budget ran out.
  timeExpired,

  /// There was no remembered adapter address to reconnect to.
  noAddress,
}

/// What the reconnect supervisor is doing, for display and logging.
class ReconnectStatus {
  const ReconnectStatus({
    this.phase = ReconnectPhase.idle,
    this.attempt = 0,
    this.nextAttemptAt,
    this.giveUpReason,
    this.lastError,
  });

  final ReconnectPhase phase;

  /// 1-based number of the current or upcoming attempt in this outage.
  final int attempt;

  /// When the next attempt starts (only while [phase] is waiting).
  final DateTime? nextAttemptAt;

  final ReconnectGiveUpReason? giveUpReason;

  /// The error behind the last failed attempt or the give-up, if any.
  final Object? lastError;

  @override
  String toString() => 'ReconnectStatus($phase, attempt: $attempt'
      '${giveUpReason == null ? '' : ', $giveUpReason'})';
}
