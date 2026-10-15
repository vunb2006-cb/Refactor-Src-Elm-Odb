/// One command of the ELM327 initialisation sequence.
class ElmInitStep {
  const ElmInitStep(
    this.command, {
    this.mustSucceed = true,
    this.timeout,
    this.delayAfter = Duration.zero,
  });

  final String command;

  /// When true the adapter must answer "OK"; otherwise connecting fails with
  /// an [ElmInitException]. Use false for optional tuning commands (and for
  /// `ATZ`, whose reply differs between genuine chips and clones).
  final bool mustSucceed;

  /// Overrides the timeout policy for this step.
  final Duration? timeout;

  /// Pause after this step (the adapter needs time after `ATZ`).
  final Duration delayAfter;
}

/// The command sequence run once per connection, as data rather than code, so
/// a profile per adapter type (genuine, clone, vendor-specific) can be chosen
/// without touching `ElmClient`.
class ElmInitProfile {
  const ElmInitProfile(this.steps);

  final List<ElmInitStep> steps;

  /// The sequence the app used before profiles existed.
  static const standard = ElmInitProfile([
    ElmInitStep('ATZ',
        mustSucceed: false, delayAfter: Duration(milliseconds: 600)),
    ElmInitStep('ATE0'), // echo off
    ElmInitStep('ATL0'), // linefeeds off
    ElmInitStep('ATS0'), // spaces off
    ElmInitStep('ATH0'), // headers off
    ElmInitStep('ATSP0'), // auto protocol
  ]);
}

/// What the adapter answered to one init step.
class ElmInitResult {
  const ElmInitResult(this.command, this.response, this.ok);

  final String command;
  final String response;
  final bool ok;
}

/// A required init step was not acknowledged with "OK".
class ElmInitException implements Exception {
  ElmInitException(this.command, this.response);

  final String command;
  final String response;

  @override
  String toString() =>
      'ELM327 init step "$command" failed: '
      '${response.isEmpty ? '(no reply)' : response}';
}
