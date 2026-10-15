import 'package:elm_obd2/core/obd/elm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyElmReply', () {
    test('recognises the usual adapter messages', () {
      expect(classifyElmReply('OK'), ElmReplyKind.ok);
      expect(classifyElmReply('ATE0\rOK'), ElmReplyKind.ok); // echo still on
      expect(classifyElmReply('?'), ElmReplyKind.unknownCommand);
      expect(classifyElmReply('NO DATA'), ElmReplyKind.noData);
      expect(classifyElmReply('BUFFER FULL'), ElmReplyKind.bufferFull);
      expect(classifyElmReply('BUS BUSY'), ElmReplyKind.busBusy);
      expect(classifyElmReply('CAN ERROR'), ElmReplyKind.canError);
      expect(classifyElmReply('STOPPED'), ElmReplyKind.stopped);
      expect(classifyElmReply('BUS INIT: ...ERROR'), ElmReplyKind.busError);
      expect(classifyElmReply('SEARCHING...\rUNABLE TO CONNECT'),
          ElmReplyKind.unableToConnect);
    });

    test('matches message text regardless of spacing', () {
      expect(classifyElmReply('NODATA'), ElmReplyKind.noData);
      expect(classifyElmReply('UNABLE TO CONNECT'), ElmReplyKind.unableToConnect);
      expect(classifyElmReply('UNABLETOCONNECT'), ElmReplyKind.unableToConnect);
      expect(classifyElmReply('BUS INIT: BUS ERROR'), ElmReplyKind.busError);
      expect(classifyElmReply('<DATA ERROR'), ElmReplyKind.dataError);
    });

    test('low-voltage reset and generic errors', () {
      expect(classifyElmReply('LV RESET'), ElmReplyKind.lowVoltageReset);
      expect(classifyElmReply('ERROR'), ElmReplyKind.error);
      expect(classifyElmReply('FB ERROR'), ElmReplyKind.busError);
    });

    test('data and banners are "other"', () {
      expect(classifyElmReply('41 0C 1A F8'), ElmReplyKind.other);
      expect(classifyElmReply('ELM327 v1.5'), ElmReplyKind.other);
      expect(classifyElmReply(''), ElmReplyKind.other);
    });

    test('protocol-up check', () {
      expect(replyShowsProtocolUp(ElmReplyKind.other), isTrue);
      expect(replyShowsProtocolUp(ElmReplyKind.noData), isTrue);
      expect(replyShowsProtocolUp(ElmReplyKind.unableToConnect), isFalse);
      expect(replyShowsProtocolUp(ElmReplyKind.busError), isFalse);
      expect(replyShowsProtocolUp(ElmReplyKind.canError), isFalse);
      expect(replyShowsProtocolUp(ElmReplyKind.lowVoltageReset), isFalse);
      expect(replyShowsProtocolUp(ElmReplyKind.error), isFalse);
    });
  });

  group('ElmTimeouts.forCommand', () {
    const t = ElmTimeouts();

    test('adapter restart uses the reset timeout', () {
      expect(t.forCommand('ATZ', protocolDetected: false), t.reset);
      expect(t.forCommand('atz', protocolDetected: true), t.reset);
    });

    test('other AT commands use the normal timeout', () {
      expect(t.forCommand('ATE0', protocolDetected: false), t.command);
      expect(t.forCommand('AT SP 0', protocolDetected: false), t.command);
    });

    test('first OBD command (protocol not detected) uses detect', () {
      expect(t.forCommand('0100', protocolDetected: false), t.detect);
      expect(t.forCommand('010C', protocolDetected: false), t.detect);
    });

    test('after detection: PIDs normal, DTC and VIN requests slow', () {
      expect(t.forCommand('010C', protocolDetected: true), t.command);
      expect(t.forCommand('0201', protocolDetected: true), t.command);
      expect(t.forCommand('03', protocolDetected: true), t.slow);
      expect(t.forCommand('07', protocolDetected: true), t.slow);
      expect(t.forCommand('0A', protocolDetected: true), t.slow);
      expect(t.forCommand('0902', protocolDetected: true), t.slow);
    });
  });
}
