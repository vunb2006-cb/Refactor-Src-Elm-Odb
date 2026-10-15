import 'package:elm_obd2/core/obd/capability/elm_protocol.dart';
import 'package:elm_obd2/core/obd/capability/supported_pids.dart';
import 'package:elm_obd2/core/obd/capability/vin_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_transport.dart';

void main() {
  group('SupportedPidsParser', () {
    test('decodes a full mask', () {
      final r = SupportedPidsParser.parse('41 00 BE 3E B8 11', base: 0)!;
      expect(r.pids, {
        '01', '03', '04', '05', '06', '07', '0B', '0C', '0D', '0E', '0F', //
        '11', '13', '14', '15', '1C', '20',
      });
      expect(r.hasNextRange, isTrue);
    });

    test('bit 0 clear means no next range', () {
      final r = SupportedPidsParser.parse('41 00 BE 3E B8 10', base: 0)!;
      expect(r.hasNextRange, isFalse);
      expect(r.pids.contains('20'), isFalse);
    });

    test('offsets PID numbers by the range base', () {
      final r = SupportedPidsParser.parse('41 20 80 00 00 00', base: 0x20)!;
      expect(r.pids, {'21'});
      expect(r.hasNextRange, isFalse);
    });

    test('merges the masks of several ECUs', () {
      final r = SupportedPidsParser.parse(
        '41 00 80 00 00 00\r41 00 00 00 00 01',
        base: 0,
      )!;
      expect(r.pids, {'01', '20'});
      expect(r.hasNextRange, isTrue);
    });

    test('tolerates spaces, prompt and CAN headers', () {
      expect(SupportedPidsParser.parse('4100 80000000>', base: 0)!.pids, {'01'});
      expect(
        SupportedPidsParser.parse('7E8 06 41 00 80 00 00 00', base: 0)!.pids,
        {'01'},
      );
    });

    test('three ECUs answering the same mode 09 request', () {
      final r = SupportedPidsParser.parse(
        '49 00 55 40 10 00\r49 00 55 40 10 00\r49 00 55 40 10 00',
        base: 0,
        mode: '09',
      )!;
      expect(r.pids, {'02', '04', '06', '08', '0A', '14'});
      expect(r.hasNextRange, isFalse);
    });

    test('reads mode 09 support', () {
      final r =
          SupportedPidsParser.parse('49 00 40 00 00 00', base: 0, mode: '09')!;
      expect(r.pids, {'02'});
    });

    test('returns null when there is no usable mask', () {
      expect(SupportedPidsParser.parse('NO DATA', base: 0), isNull);
      expect(SupportedPidsParser.parse('', base: 0), isNull);
      expect(SupportedPidsParser.parse('SEARCHING...', base: 0), isNull);
      expect(SupportedPidsParser.parse('41 00 BE', base: 0), isNull);
      // A reply for another range is not an answer to this one.
      expect(SupportedPidsParser.parse('41 20 80 00 00 00', base: 0), isNull);
    });
  });

  group('ElmProtocol.parseDpn', () {
    test('automatic and fixed forms', () {
      expect(ElmProtocol.parseDpn('A6')!.code, '6');
      expect(ElmProtocol.parseDpn('A6')!.name, contains('CAN'));
      expect(ElmProtocol.parseDpn('3')!.code, '3');
      expect(ElmProtocol.parseDpn('AA')!.code, 'A');
    });

    test('nothing detected yet or garbage gives null', () {
      expect(ElmProtocol.parseDpn('A0'), isNull);
      expect(ElmProtocol.parseDpn('0'), isNull);
      expect(ElmProtocol.parseDpn(''), isNull);
      expect(ElmProtocol.parseDpn('NO DATA'), isNull);
      expect(ElmProtocol.parseDpn('?'), isNull);
    });

    test('uses the last line when something else precedes it', () {
      expect(ElmProtocol.parseDpn('SEARCHING...\rA6')!.code, '6');
    });
  });

  group('VinDecoder', () {
    const vin = '1HGCM82633A004352';

    test('CAN multi-frame reply', () {
      expect(VinDecoder.decode(canVinReply(vin)), vin);
    });

    test('CAN reply with spaces between bytes', () {
      const spaced = '014\r0: 49 02 01 31 48 47\r1: 43 4D 38 32 36 33 33\r'
          '2: 41 30 30 34 33 35 32';
      expect(VinDecoder.decode(spaced), vin);
    });

    test('one message per line (J1850 / ISO 9141 / KWP)', () {
      expect(VinDecoder.decode(isoVinReply(vin)), vin);
    });

    test('ignores a leading SEARCHING... line', () {
      expect(VinDecoder.decode('SEARCHING...\r${canVinReply(vin)}'), vin);
    });

    test('frame labels starting at 1 and a byte past the declared length',
        () {
      // Three frames of 7 bytes = 21 bytes, but the length line says 20.
      const reply = '014\r1:490201344A4744\r2:41354842374A42\r3:31353831343434';
      expect(VinDecoder.decode(reply), '4JGDA5HB7JB158144');
    });

    test('an extra frame beyond the declared length is ignored', () {
      // 0x55 is printable ("U"); the length line is what keeps it out.
      expect(VinDecoder.decode('${canVinReply(vin)}\r3:55555555'), vin);
    });

    test('no data or garbage gives null', () {
      expect(VinDecoder.decode('NO DATA'), isNull);
      expect(VinDecoder.decode(''), isNull);
      expect(VinDecoder.decode('41 0C 1A F8'), isNull);
    });

    test('rejects VINs with I, O or Q and wrong lengths', () {
      expect(VinDecoder.decode(canVinReply('1HGCM82633A00O352')), isNull);
      expect(VinDecoder.isValid('1HGCM82633A004352'), isTrue);
      expect(VinDecoder.isValid('1HGCM82633A00435'), isFalse);
      expect(VinDecoder.isValid('1hgcm82633a004352'), isFalse);
    });
  });
}
