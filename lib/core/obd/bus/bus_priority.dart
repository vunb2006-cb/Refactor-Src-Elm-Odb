/// How urgent a command is when several are waiting for the adapter.
///
/// Higher [rank] is sent first; commands of the same level go first-in,
/// first-out. A command that is already being sent is never interrupted.
enum BusPriority {
  /// Background polling.
  low(1, Duration(seconds: 10)),

  /// Probing the vehicle, diagnostic tests, one-off reads.
  normal(2, Duration(seconds: 20)),

  /// Things the user asked for and is waiting on: fault codes, freeze frame.
  high(3, Duration(seconds: 30)),

  /// Clearing fault codes, resetting. Reserved: nothing uses it yet.
  critical(4, Duration(seconds: 60));

  const BusPriority(this.rank, this.defaultWaitTimeout);

  final int rank;

  /// How long a command of this level may wait in the queue before it is
  /// failed instead of sent. Less urgent commands give up sooner.
  final Duration defaultWaitTimeout;
}
