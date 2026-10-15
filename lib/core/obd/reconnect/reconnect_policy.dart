import '../elm_client.dart';

/// How and when to reconnect after a lost link.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
    this.jitter = 0.2,
    this.giveUpAfter = const Duration(minutes: 10),
  }) : assert(jitter >= 0 && jitter < 1);

  /// Wait before attempt 1, 2, 3, ...; the last value repeats.
  final List<Duration> delays;

  /// Random spread of each delay, as a fraction (0.2 = plus or minus 20%), so
  /// several phones do not hit an adapter at the same instant.
  final double jitter;

  /// Total time budget per outage; after it the supervisor gives up.
  final Duration giveUpAfter;

  /// Delay before the 1-based [attempt]. [random01] in 0..1 picks the point in
  /// the jitter range (0.5 = no jitter).
  Duration delayFor(int attempt, [double random01 = 0.5]) {
    final index = (attempt - 1).clamp(0, delays.length - 1).toInt();
    final factor = 1 + jitter * (2 * random01 - 1);
    return Duration(
      milliseconds: (delays[index].inMilliseconds * factor).round(),
    );
  }

  /// Whether another attempt can help after a disconnect for [reason].
  ///
  ///  * requested: the user asked for it, never reconnect.
  ///  * linkLost, stalled, connectFailed: ordinary outages, retry.
  ///  * initFailed: retry only for transient errors; a rejected init step
  ///    ([ElmInitException]) is a configuration problem and will fail again.
  bool isRetriable(ElmDisconnectReason? reason, Object? error) {
    switch (reason) {
      case null:
      case ElmDisconnectReason.requested:
        return false;
      case ElmDisconnectReason.linkLost:
      case ElmDisconnectReason.stalled:
      case ElmDisconnectReason.connectFailed:
        return true;
      case ElmDisconnectReason.initFailed:
        return error is! ElmInitException;
    }
  }
}
