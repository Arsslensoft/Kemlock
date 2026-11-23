import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';

import '../hex.dart';

/// A data object written out by hand: [tag] and [value] in hex, with its
/// length worked out (one byte, or `81`/`82` and the length).
String obj(String tag, String value) {
  final length = value.replaceAll(' ', '').length ~/ 2;
  final l = length < 0x80
      ? length.toRadixString(16).padLeft(2, '0')
      : length < 0x100
      ? '81${length.toRadixString(16).padLeft(2, '0')}'
      : '82${length.toRadixString(16).padLeft(4, '0')}';
  return '$tag$l${value.replaceAll(' ', '')}';
}

const _ed25519 = '16 2b06010401da470f01';
const _cv25519 = '12 2b060104019755010501';
const _rsa2048 = '01 0800 0011 00';
const _sigFingerprint = '1fcda135ee42400ec2b77ce677249abe661cf8db';
const _decFingerprint = '4ba83174fc8ce762a23bf0a4841a40e3b199ea67';

/// The application related data of a version 3.4 card, laid out as a
/// YubiKey 5 lays it out: Ed25519 in the signature place, Curve25519 in the
/// decryption place, the authentication place empty and set to RSA 2048.
final _v34 = unhex(
  obj(
    '6e',
    obj('4f', 'd2760001240103040006123456780000') +
        obj('5f52', '00730000e0059000') +
        obj('7f74', '810120') +
        obj(
          '73',
          obj('c0', '7d000bfe080000ff0000') +
              obj('c1', _ed25519) +
              obj('c2', _cv25519) +
              obj('c3', _rsa2048) +
              obj('c4', '00 7f 7f 7f 03 00 03') +
              obj('c5', _sigFingerprint + _decFingerprint + '00' * 20) +
              obj('c6', '00' * 60) +
              obj('cd', '6afa23a7 6afa23a8 00000000') +
              obj('de', '0101 0202 0300'),
        ),
  ),
);

/// The same of a version 2.1 card: RSA everywhere, no key information and
/// no touch settings, PIN good for many signatures, two tries left.
final _v21 = unhex(
  obj(
    '6e',
    obj('4f', 'd2760001240102010005000012340000') +
        obj('5f52', '0031c573c00140059000') +
        obj(
          '73',
          obj('c0', '7c000800080008000800') +
              obj('c1', '01 0800 0020') +
              obj('c2', '01 0800 0020') +
              obj('c3', '01 0800 0020') +
              obj('c4', '01 20 20 20 02 00 03') +
              obj('c5', _sigFingerprint + '00' * 40) +
              obj('c6', '00' * 60) +
              obj('cd', '6afa23a7 00000000 00000000'),
        ),
  ),
);

Matcher get _formatError => throwsA(isA<CardFormatError>());

void main() {
  group('a version 3.4 card', () {
    final data = ApplicationData.parse(_v34);

    test('names itself: version, maker and serial', () {
      expect(data.aid.version, '3.4');
      expect(data.aid.isV3, isTrue);
      expect(data.aid.manufacturer, 0x0006);
      expect(cardMakerName(data.aid.manufacturer), 'Yubico');
      expect(data.aid.serial, '12345678');
      expect(data.aid.groupedSerial, '1234 5678');
      expect(data.aid.hex, 'D2760001240103040006123456780000');
    });

    test("reads each place's algorithm, fingerprint and time", () {
      expect(data.attributes[CardPlace.signature]!.name, 'ed25519');
      expect(data.attributes[CardPlace.decryption]!.name, 'cv25519');
      expect(data.attributes[CardPlace.authentication], isA<RsaAttributes>());
      expect(data.attributes[CardPlace.authentication]!.name, 'rsa2048');
      expect(cardHex(data.fingerprints[CardPlace.signature]!), _sigFingerprint.toUpperCase());
      expect(cardHex(data.fingerprints[CardPlace.decryption]!), _decFingerprint.toUpperCase());
      expect(data.fingerprints.containsKey(CardPlace.authentication), isFalse);
      expect(data.times[CardPlace.signature], DateTime.fromMillisecondsSinceEpoch(0x6afa23a7 * 1000, isUtc: true));
      expect(data.times.containsKey(CardPlace.authentication), isFalse);
    });

    test('says which places hold a key, by key information', () {
      expect(data.keyInformation!.of(CardPlace.signature), CardKeyOrigin.generated);
      expect(data.keyInformation!.of(CardPlace.decryption), CardKeyOrigin.imported);
      expect(data.keyInformation!.of(CardPlace.authentication), CardKeyOrigin.none);
      expect([for (final place in CardPlace.values) data.holdsKey(place)], [true, true, false]);
    });

    test('reads the PIN status', () {
      final status = data.pinStatus;
      expect(status.pinForEverySignature, isTrue);
      expect(status.pinMaxLength, 127);
      expect(status.adminPinMaxLength, 127);
      expect(status.pinTries, 3);
      expect(status.resetCodeTries, 0);
      expect(status.resetCodeSet, isFalse);
      expect(status.adminPinTries, 3);
    });

    test('reads what it can do, and that it can be reset', () {
      final caps = data.capabilities!;
      expect(caps.keyImport, isTrue);
      expect(caps.pinStatusChangeable, isTrue);
      expect(caps.algorithmAttributesChangeable, isTrue);
      expect(caps.kdf, isTrue);
      expect(caps.secureMessaging, isFalse);
      expect(data.historical!.lifeCycleStatus, 0x05);
      expect(data.historical!.lifeCycleManagement, isTrue);
    });

    test('marks what Kemlock can use', () {
      expect(data.attributes.values.map((a) => a.usable), everyElement(isTrue));
      expect(CardAlgorithm.parse(unhex('13 2b2403030208010107')).name, 'brainpoolP256r1');
      expect(CardAlgorithm.parse(unhex('13 2b2403030208010107')).usable, isFalse);
      expect(CardAlgorithm.parse(unhex('13 2a8648ce3d030107')).name, 'nistp256');
      expect(CardAlgorithm.parse(unhex('13 2a8648ce3d030107')).usable, isTrue);
      expect(CardAlgorithm.parse(unhex('12 2b81040022')).name, 'nistp384');
      expect(CardAlgorithm.parse(unhex('13 2b81040023')).usable, isFalse, reason: 'P-521');
      expect(CardAlgorithm.parse(unhex('01 0400 0011 00')).usable, isFalse, reason: 'RSA 1024');
      expect(
        CardAlgorithm.parse(unhex('16 2b06010401da470f01 ff')),
        isA<EccAttributes>().having((a) => a.withPublicKey, 'with public key', isTrue),
      );
      expect(CardAlgorithm.parse(unhex('63 0102')).usable, isFalse);
      expect(cardAlgorithmLabel(CardAlgorithm.parse(unhex(_rsa2048))), 'RSA 2048');
      expect(cardAlgorithmLabel(CardAlgorithm.parse(unhex(_cv25519))), 'Curve25519');
    });

    test('reads touch settings, the KDF object and the algorithm list', () {
      expect(TouchSetting(unhex('0020')).policy, TouchPolicy.off);
      expect(TouchSetting(unhex('0220')).policy, TouchPolicy.fixed);
      expect(TouchSetting(unhex('0220')).policy!.permanent, isTrue);
      expect(TouchSetting(unhex('0320')).policy, TouchPolicy.cached);

      final off = KdfSetting.parse(unhex('810100'));
      expect(off.on, isFalse);
      expect(off.readable, isTrue);
      final on = KdfSetting.parse(
        unhex(obj('f9', '810103 820108 830400030000 8408 0102030405060708 8508 1112131415161718 8608 2122232425262728')),
      );
      expect(on.on, isTrue);
      expect(on.hash, 0x08);
      expect(on.count, 0x30000);
      expect(hex(on.saltPin!), '0102030405060708');
      expect(hex(on.saltResetCode!), '1112131415161718');
      expect(hex(on.saltAdmin!), '2122232425262728');
      expect(on.readable, isTrue);
      expect(KdfSetting.parse(unhex('810104')).readable, isFalse, reason: 'an algorithm the specification does not define');
      expect(KdfSetting.parse(unhex('810103 82010b 830400030000 8408 0102030405060708 8608 2122232425262728')).readable, isFalse);

      final list = AlgorithmList.parse(
        unhex(obj('fa', obj('c1', _rsa2048) + obj('c1', _ed25519) + obj('c2', _rsa2048) + obj('c2', _cv25519) + obj('c3', _ed25519))),
      );
      expect(list.of(CardPlace.signature).map((a) => a.name), ['rsa2048', 'ed25519']);
      expect(list.of(CardPlace.decryption).map((a) => a.name), ['rsa2048', 'cv25519']);
      expect(list.of(CardPlace.authentication).map((a) => a.name), ['ed25519']);
    });

    test("reads the cardholder's name and the signature counter", () {
      expect(
        cardholderName(unhex(obj('65', obj('5b', '4c6f76656c6163653c3c416461') + obj('5f2d', '656e') + obj('5f35', '39')))),
        'Ada Lovelace',
      );
      expect(cardholderName(unhex(obj('65', obj('5b', '')))), isNull);
      expect(signatureCounter(unhex(obj('7a', obj('93', '000102')))), 258);
    });
  });

  group('a version 2.1 card', () {
    final data = ApplicationData.parse(_v21);

    test('reads without the objects version 3 added', () {
      expect(data.aid.version, '2.1');
      expect(data.aid.isV3, isFalse);
      expect(cardMakerName(data.aid.manufacturer), 'ZeitControl');
      expect(data.keyInformation, isNull);
      expect(data.attributes.values.map((a) => a.name), everyElement('rsa2048'));
      expect([for (final place in CardPlace.values) data.holdsKey(place)], [true, false, false], reason: 'by fingerprint');
      expect(data.pinStatus.pinForEverySignature, isFalse);
      expect(data.pinStatus.pinTries, 2);
      expect(data.pinStatus.pinMaxLength, 32);
      expect(data.capabilities!.kdf, isFalse);
      expect(data.historical!.lifeCycleManagement, isTrue);
    });
  });

  group('bytes that are not what they should be', () {
    test('throw the format error and nothing else', () {
      final cases = <String, Object? Function()>{
        'a length past the end': () => parseTlvs(unhex('4f10d27600')),
        'a tag cut short': () => parseTlvs(unhex('5f')),
        'a length cut short': () => parseTlvs(unhex('4f82 01')),
        'a length of four bytes': () => parseTlvs(unhex('4f840000000100')),
        'more than a card answers': () => parseTlvs(Uint8List(70000)..[0] = 0x4f),
        'an application identifier too short': () => CardAid(unhex('d27600012401030400061234')),
        'an application identifier too long': () => CardAid(unhex('d2760001240103040006123456780000ff')),
        'another application': () => CardAid(unhex('a0000006472f0001 0000000000000000')),
        'a PIN status cut short': () => PinStatus(unhex('007f7f7f0300')),
        'a PIN status too long': () => PinStatus(unhex('007f7f7f03000300')),
        'fingerprints cut short': () => ApplicationData.parse(
          unhex(obj('6e', obj('4f', 'd2760001240103040006123456780000') + obj('c4', '007f7f7f030003') + obj('c5', '00' * 40))),
        ),
        'no PIN status': () =>
            ApplicationData.parse(unhex(obj('6e', obj('4f', 'd2760001240103040006123456780000') + obj('c5', '00' * 60)))),
        'key times too long': () => ApplicationData.parse(
          unhex(
            obj(
              '6e',
              obj('4f', 'd2760001240103040006123456780000') + obj('c4', '007f7f7f030003') + obj('c5', '00' * 60) + obj('cd', '00' * 16),
            ),
          ),
        ),
        'a truncated application data object': () => ApplicationData.parse(Uint8List.sublistView(_v34, 0, _v34.length - 10)),
        'empty algorithm attributes': () => CardAlgorithm.parse(const []),
        'RSA attributes too long': () => CardAlgorithm.parse(unhex('01 0800 0011 00 00')),
        'curve attributes too short': () => CardAlgorithm.parse(unhex('16')),
        'a touch setting too long': () => TouchSetting(unhex('002000')),
        'key information of an odd length': () => KeyInformation(unhex('010102')),
        'a KDF object without its algorithm': () => KdfSetting.parse(unhex('820108')),
        'a KDF count too short': () => KdfSetting.parse(unhex('810103 82010a 8302 0300')),
        'a signature counter too long': () => signatureCounter(unhex(obj('7a', obj('93', '00010203')))),
        'extended capabilities too long': () => ExtendedCapabilities(Uint8List(11)),
      };
      for (final MapEntry(key: name, value: read) in cases.entries) {
        expect(read, _formatError, reason: name);
      }
    });

    test('padding between objects is passed over', () {
      final objects = parseTlvs(unhex('00ff 4f0101 00 c40100'));
      expect(objects.map((o) => o.tag), [0x4f, 0xc4]);
    });
  });
}
