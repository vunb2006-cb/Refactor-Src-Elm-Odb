/// What an ELM327 reply means, judged from its text alone.
///
/// Pure function so it is easy to unit-test; later layers (capability probing,
/// the polling scheduler) can reuse it to tell "unsupported PID" from "bus
/// problem" without re-parsing strings.
enum ElmReplyKind {
  ok,
  noData,
  unknownCommand,
  bufferFull,
  busBusy,
  canError,
  busError,
  unableToConnect,
  stopped,
  dataError,

  /// "LV RESET": the adapter restarted itself after a supply-voltage dip, so
  /// it is back at factory settings (echo on, spaces on...) and must be
  /// initialised again.
  lowVoltageReset,

  /// Any other message containing "ERROR".
  error,
  other,
}

ElmReplyKind classifyElmReply(String reply) {
  final up = reply.toUpperCase();
  // Message texts are matched with whitespace removed ("NO DATA" == "NODATA")
  // so odd spacing from clone adapters does not matter. Hex data cannot be
  // mistaken for these words: it never contains letters beyond A-F.
  final c = up.replaceAll(RegExp(r'\s'), '');

  if (c.contains('UNABLE')) return ElmReplyKind.unableToConnect;
  if (c.contains('BUFFERFULL')) return ElmReplyKind.bufferFull;
  if (c.contains('BUSBUSY')) return ElmReplyKind.busBusy;
  if (c.contains('CANERROR')) return ElmReplyKind.canError;
  if (c.contains('BUSERROR') ||
      c.contains('FBERROR') ||
      RegExp(r'BUSINIT:.*ERR').hasMatch(c)) {
    return ElmReplyKind.busError;
  }
  if (c.contains('NODATA')) return ElmReplyKind.noData;
  if (c.contains('STOPPED')) return ElmReplyKind.stopped;
  if (c.contains('DATAERROR')) return ElmReplyKind.dataError;
  if (c.contains('LVRESET')) return ElmReplyKind.lowVoltageReset;
  if (c.contains('ERROR')) return ElmReplyKind.error;

  final lines = up.split(RegExp(r'[\r\n]+')).map((l) => l.trim());
  if (lines.contains('?')) return ElmReplyKind.unknownCommand;
  if (RegExp(r'\bOK\b').hasMatch(up)) return ElmReplyKind.ok;
  return ElmReplyKind.other;
}

/// True when the reply shows the adapter has found a working vehicle protocol
/// (or at least did not report that it failed to find one).
bool replyShowsProtocolUp(ElmReplyKind kind) =>
    kind != ElmReplyKind.unableToConnect &&
    kind != ElmReplyKind.busError &&
    kind != ElmReplyKind.canError &&
    kind != ElmReplyKind.lowVoltageReset &&
    kind != ElmReplyKind.error;
