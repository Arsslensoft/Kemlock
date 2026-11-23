import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';

import '../hex.dart';

void main() {
  final certificate = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x05]);

  group('slots', () {
    test('are 9a, 9c, 9d and 9e, each with its certificate object', () {
      expect(
        [for (final slot in PivSlot.values) (slot.id, slot.object.toRadixString(16))],
        [('9a', '5fc105'), ('9c', '5fc10a'), ('9d', '5fc10b'), ('9e', '5fc101')],
      );
      expect([for (final slot in PivSlot.values) slot.needsPin], [true, true, true, false]);
    });
  });

  group('TLVs', () {
    test('are written with the shortest length and read back', () {
      expect(hex(pivTlv(0x70, const [1, 2])), '70020102');
      expect(hex(pivTlv(0x5fc105, const [])), '5fc10500');
      expect(hex(pivTlv(0x53, Uint8List(0x80))).substring(0, 6), '538180');
      expect(hex(pivTlv(0x53, Uint8List(0x123))).substring(0, 8), '53820123');
      final read = readPivTlvs(unhex('7f4903860104 fe00'));
      expect([for (final part in read) (part.tag, hex(part.value))], [(0x7f49, '860104'), (0xfe, '')]);
      expect(readPivTlvs(pivTlv(0x53, Uint8List(0x123))).single.value, hasLength(0x123));
    });

    test('cut short throw the format error and nothing else', () {
      for (final bad in ['70', '7002ff', '5f', '5381', '5382', '7f', '70850000000001']) {
        expect(() => readPivTlvs(unhex(bad)), throwsA(isA<PivFormatException>()), reason: bad);
      }
    });
  });

  group('a certificate object', () {
    test('wraps the certificate with "not compressed" and an empty check code', () {
      expect(hex(wrapPivCertificate(certificate)), '70053003020105710100fe00');
    });

    test('round-trips', () {
      final object = pivTlv(0x53, wrapPivCertificate(certificate));
      expect(unwrapPivCertificate(object), certificate);
    });

    test('unpacks a compressed certificate', () {
      final packed = gzip.encode(certificate);
      final object = pivTlv(0x53, [
        ...pivTlv(0x70, packed),
        ...pivTlv(0x71, const [1]),
        ...pivTlv(0xfe, const []),
      ]);
      expect(unwrapPivCertificate(object), certificate);
    });

    test('unpacks a compressed certificate only as far as the bound', () {
      Uint8List packed(int length) => pivTlv(0x53, [
        ...pivTlv(0x70, gzip.encode(Uint8List(length))),
        ...pivTlv(0x71, const [1]),
        ...pivTlv(0xfe, const []),
      ]);

      expect(unwrapPivCertificate(packed(pivCertificateMost)), hasLength(pivCertificateMost));
      expect(() => unwrapPivCertificate(packed(pivCertificateMost + 1)), throwsA(isA<PivFormatException>()));
      // A megabyte of zeros, packed into a kilobyte or so
      expect(() => unwrapPivCertificate(packed(1 << 20)), throwsA(isA<PivFormatException>()));
    });

    test('with nothing in it is an empty slot', () {
      expect(wrapPivCertificate(null), isEmpty);
      expect(unwrapPivCertificate(Uint8List(0)), isNull);
      expect(unwrapPivCertificate(unhex('5300')), isNull);
      expect(unwrapPivCertificate(unhex('53047000fe00')), isNull);
    });

    test('truncated or damaged throws the format error and nothing else', () {
      final whole = pivTlv(0x53, wrapPivCertificate(certificate));
      for (var length = 1; length < whole.length; length++) {
        expect(() => unwrapPivCertificate(Uint8List.sublistView(whole, 0, length)), throwsA(isA<PivFormatException>()), reason: '$length');
      }
      expect(() => unwrapPivCertificate(unhex('7000')), throwsA(isA<PivFormatException>()));
      // Marked as compressed, and not gzip
      expect(() => unwrapPivCertificate(unhex('530a 7003010203 710101 fe00')), throwsA(isA<PivFormatException>()));
    });
  });

  group('metadata', () {
    test('of a PIN gives whether it is the factory one and its tries', () {
      final pin = PivMetadata.parse(unhex('0101ff 050101 06020302'));
      expect((pin.isDefault, pin.totalTries, pin.triesLeft, pin.algorithm), (true, 3, 2, 0xff));
    });

    test('of a management key gives its kind', () {
      final key = PivMetadata.parse(unhex('01010c 02020001 050100'));
      expect((PivManagementKeyType.byId(key.algorithm!), key.isDefault), (PivManagementKeyType.aes256, false));
    });

    test('of a slot gives its algorithm and public key', () {
      final point = [4, ...List.filled(64, 7)];
      final slot = PivMetadata.parse(Uint8List.fromList([...unhex('010111 02020201 030101'), ...pivTlv(0x04, pivTlv(0x86, point))]));
      expect(slot.algorithm, PivAlgorithm.eccP256.id);
      expect(slot.generated, isTrue);
      expect((slot.publicKey! as EcPublicHalf).point, point);
    });

    test('cut short throws the format error', () {
      expect(() => PivMetadata.parse(unhex('0601')), throwsA(isA<PivFormatException>()));
      expect(() => PivMetadata.parse(unhex('060103')), throwsA(isA<PivFormatException>()));
      expect(() => PivMetadata.parse(unhex('010111 0403860104')), throwsA(isA<PivFormatException>()));
    });
  });

  group('a generated key', () {
    test('is read from 7F49 for RSA and for a curve', () {
      final rsa = readPivGeneratedKey(PivAlgorithm.rsa2048, unhex('7f490a 810300c0ff 8203010001')) as RsaPublicHalf;
      expect((rsa.n, rsa.e), (BigInt.from(0xc0ff), BigInt.from(65537)));
      final point = [4, ...List.filled(96, 9)];
      final ec = readPivGeneratedKey(PivAlgorithm.eccP384, pivTlv(0x7f49, pivTlv(0x86, point))) as EcPublicHalf;
      expect(ec.curve, EcCurve.p384);
      expect(ec.point, point);
    });

    test('that is not one throws the format error', () {
      expect(() => readPivGeneratedKey(PivAlgorithm.eccP256, unhex('7f4903860104')), throwsA(isA<PivFormatException>()));
      expect(() => readPivGeneratedKey(PivAlgorithm.rsa2048, unhex('7f4903810101')), throwsA(isA<PivFormatException>()));
      expect(() => readPivGeneratedKey(PivAlgorithm.rsa2048, unhex('3000')), throwsA(isA<PivFormatException>()));
    });
  });

  test('the serial and version answers are read, and nothing of another length', () {
    expect(readPivSerial(unhex('00bc614e')), 12345678);
    expect(readPivVersion(unhex('050703')), (major: 5, minor: 7, patch: 3));
    expect(() => readPivSerial(unhex('0102')), throwsA(isA<PivFormatException>()));
    expect(() => readPivVersion(unhex('01020304')), throwsA(isA<PivFormatException>()));
  });

  group('the identifier objects', () {
    final guid = Uint8List.fromList(List.generate(16, (i) => 0xa0 + i));

    test('a card holder identifier carries the identifier, and gives it back', () {
      final chuid = buildPivChuid(guid);
      expect(chuid, hasLength(59));
      expect(
        hex(chuid),
        '3019d4e739da739ced39ce739d836858210842108421c84210c3eb'
        '3410a0a1a2a3a4a5a6a7a8a9aaabacadaeaf'
        '350832303330303130313e00fe00',
      );
      expect(readPivChuidGuid(pivTlv(0x53, chuid)), 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf');
      expect(readPivChuidGuid(unhex('5300')), isNull);
      expect(readPivChuidGuid(Uint8List(0)), isNull);
    });

    test('a capability container is the template round the card identifier', () {
      final ccc = buildPivCcc(Uint8List.fromList(List.filled(14, 0x11)));
      expect(ccc, hasLength(51));
      expect(hex(ccc), 'f015a000000116ff02${'11' * 14}f10121f20121f300f40100f50110f600f700fa00fb00fc00fd00fe00');
      expect(readPivCccId(pivTlv(0x53, ccc)), '11' * 14);
      expect(readPivCccId(unhex('5300')), isNull);
    });
  });

  test('the factory management key is the published one', () {
    expect(hex(pivFactoryManagementKey), '010203040506070801020304050607080102030405060708');
  });
}
