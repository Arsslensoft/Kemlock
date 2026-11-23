import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/security_key/apdu.dart';
import 'package:kemlock/security_key/piv/piv_commands.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';

import '../hex.dart';

/// A card that answers what the test told it to, and keeps what it was sent.
class _Script {
  final Queue<ApduResponse> _answers = Queue();
  final List<String> sent = [];

  void answer(String data, [int sw = 0x9000]) => _answers.add(ApduResponse(unhex(data), sw));

  Future<ApduResponse> transmit(ApduCommand command) async {
    sent.add(hex(command.encodeShort()));
    return _answers.removeFirst();
  }
}

void main() {
  late _Script script;
  late PivCard card;

  setUp(() {
    script = _Script();
    card = PivCard(script.transmit, random: (length) => unhex(length == 8 ? '8899aabbccddeeff' : 'ffeeddccbbaa99887766554433221100'));
  });

  // The examples are written out from SP 800-73-4 part 2 (section 3) and,
  // for the last five, from Yubico's published PIV reference.
  group('each command is the bytes the standard gives', () {
    test('GET DATA for the certificate of 9a', () async {
      script.answer('5300');
      expect(hex(await card.getData(PivSlot.authentication.object)), '5300');
      expect(script.sent, ['00cb3fff055c035fc10500']);
    });

    test('PUT DATA wraps the contents in 53', () async {
      script.answer('');
      await card.putData(PivSlot.signature.object, unhex('7001aa710100fe00'));
      expect(script.sent, ['00db3fff0f5c035fc10a53087001aa710100fe00']);
    });

    test('VERIFY with a PIN pads it with FF to eight bytes', () async {
      script.answer('');
      await card.verifyPin('123456'.codeUnits);
      expect(script.sent, ['0020008008313233343536ffff']);
    });

    test('VERIFY without a PIN asks for the tries left, and is no try', () async {
      script.answer('', 0x63c3);
      expect(await card.pinTries(), 3);
      expect(script.sent, ['00200080']);

      script.answer('', 0x6983);
      expect(await card.pinTries(), 0);
      script.answer('');
      expect(await card.pinTries(), isNull);
    });

    test('CHANGE REFERENCE DATA for the PIN and for the PUK', () async {
      script
        ..answer('')
        ..answer('');
      await card.changePin('123456'.codeUnits, '654321'.codeUnits);
      await card.changePuk('12345678'.codeUnits, '87654321'.codeUnits);
      expect(script.sent, ['0024008010313233343536ffff363534333231ffff', '002400811031323334353637383837363534333231']);
    });

    test('RESET RETRY COUNTER sends the PUK and the new PIN', () async {
      script.answer('');
      await card.unblockPin('12345678'.codeUnits, '246810'.codeUnits);
      expect(script.sent, ['002c0080103132333435363738323436383130ffff']);
    });

    test('GENERATE ASYMMETRIC KEY PAIR names the slot and the algorithm', () async {
      final point = [4, ...List.filled(64, 3)];
      script.answer(hex(pivTlv(0x7f49, pivTlv(0x86, point))));
      final key = await card.generate(PivSlot.authentication, PivAlgorithm.eccP256) as EcPublicHalf;
      expect(script.sent, ['0047009a05ac0380011100']);
      expect(key.point, point);

      script.answer('7f490a 810300c0ff 8203010001');
      await card.generate(PivSlot.keyManagement, PivAlgorithm.rsa2048);
      expect(script.sent.last, '0047009d05ac0380010700');
    });

    test('GENERAL AUTHENTICATE signs with a slot’s key', () async {
      script.answer('7c05 8203 3001ff');
      final signature = await card.sign(PivSlot.signature, PivAlgorithm.eccP256, List.filled(32, 0xab));
      expect(script.sent, ['0087119c267c2482008120${'ab' * 32}00']);
      expect(hex(signature), '3001ff');
    });

    test('SET MANAGEMENT KEY carries the kind, the reference and the key', () async {
      script.answer('');
      await card.setManagementKey(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      expect(script.sent, ['00ffffff1b039b18010203040506070801020304050607080102030405060708']);

      script.answer('');
      await card.setManagementKey(PivManagementKeyType.aes256, List.generate(32, (i) => i));
      expect(script.sent.last, '00ffffff230c9b20000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    });

    test('metadata, serial, version and reset', () async {
      script
        ..answer('0101ff 050101 06020303')
        ..answer('00bc614e')
        ..answer('050403')
        ..answer('');
      expect((await card.metadata(pivPukReference)).triesLeft, 3);
      expect(await card.serial(), 12345678);
      expect(await card.version(), (major: 5, minor: 4, patch: 3));
      await card.reset();
      expect(script.sent, ['00f7008100', '00f8000000', '00fd000000', '00fb0000']);
    });
  });

  // The encrypted blocks were worked out with `openssl enc -des-ede3-ecb` and
  // `-aes-256-ecb` (the AES pair is also FIPS 197's example C.3).
  group('the management key exchange', () {
    test('with triple DES decrypts the witness and checks the card’s answer', () async {
      script
        ..answer('7c0a 8008 26604d88e55bd3e7')
        ..answer('7c0a 8208 83e96cd48a9d7151');
      await card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      expect(script.sent, ['0087039b047c02800000', '0087039b167c1480080011223344556677 81088899aabbccddeeff00'.replaceAll(' ', '')]);
    });

    test('with AES-256 does the same on blocks of sixteen bytes', () async {
      script
        ..answer('7c12 8010 8ea2b7ca516745bfeafc49904b496089')
        ..answer('7c12 8210 4c5e3c10dd6a2f21346bc31c590f6ff9');
      await card.authenticate(PivManagementKeyType.aes256, List.generate(32, (i) => i));
      expect(script.sent, [
        '00870c9b047c02800000',
        '00870c9b267c24 801000112233445566778899aabbccddeeff 8110ffeeddccbbaa99887766554433221100 00'.replaceAll(' ', ''),
      ]);
    });

    test('is refused when the card refuses, or answers as no holder of the key would', () async {
      script.answer('', 0x6982);
      await expectLater(
        card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey),
        throwsA(isA<PivManagementKeyRefused>()),
      );

      script
        ..answer('7c0a 8008 26604d88e55bd3e7')
        ..answer('', 0x6982);
      await expectLater(
        card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey),
        throwsA(isA<PivManagementKeyRefused>()),
      );

      script
        ..answer('7c0a 8008 26604d88e55bd3e7')
        ..answer('7c0a 8208 0000000000000000');
      await expectLater(
        card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey),
        throwsA(isA<PivManagementKeyRefused>()),
      );

      // A key of the wrong length is never sent
      final before = script.sent.length;
      await expectLater(card.authenticate(PivManagementKeyType.aes256, pivFactoryManagementKey), throwsA(isA<PivManagementKeyRefused>()));
      expect(script.sent, hasLength(before));
    });
  });

  group('refusals are named', () {
    Future<Object?> refusal(int sw) async {
      script.answer('', sw);
      try {
        await card.verifyPin('123456'.codeUnits);
      } on PivError catch (error) {
        return error;
      }
      return null;
    }

    test('a wrong PIN says how many tries are left', () async {
      expect(await refusal(0x63c2), isA<PivWrongCode>().having((error) => error.triesLeft, 'triesLeft', 2));
    });

    test('blocked, security status, not found, not supported, no room', () async {
      expect(await refusal(0x6983), isA<PivBlocked>());
      expect(await refusal(0x63c0), isA<PivBlocked>());
      expect(await refusal(0x6982), isA<PivSecurityStatus>());
      expect(await refusal(0x6a82), isA<PivNotFound>());
      expect(await refusal(0x6d00), isA<PivNotSupported>());
      expect(await refusal(0x6a81), isA<PivNotSupported>());
      expect(await refusal(0x6a84), isA<PivNoRoom>());
      expect(await refusal(0x6a80), isA<PivRefused>().having((error) => error.sw, 'sw', 0x6a80));
    });

    test('an answer that is not PIV throws the format error', () async {
      script.answer('3000');
      await expectLater(card.sign(PivSlot.cardAuthentication, PivAlgorithm.eccP256, const [1]), throwsA(isA<PivFormatException>()));
      script.answer('0102');
      await expectLater(card.serial(), throwsA(isA<PivFormatException>()));
    });
  });

  group('codes and keys', () {
    test('a PIN or PUK of no bytes or more than eight is refused before it is sent', () {
      expect(() => padPivCode(const []), throwsArgumentError);
      expect(() => padPivCode('123456789'.codeUnits), throwsArgumentError);
      expect(hex(padPivCode('12345678'.codeUnits)), '3132333435363738');
    });

    test('odd parity is set on every byte of a triple DES key', () {
      expect(hex(withOddParity(unhex('00 01 02 03 fe ff 80 7f'))), '01010202fefe807f');
      for (final byte in withOddParity(List.generate(256, (i) => i))) {
        expect(byte.toRadixString(2).replaceAll('0', '').length.isOdd, isTrue);
      }
    });

    test('weak triple DES keys are told', () {
      expect(isWeakTripleDesKey(pivFactoryManagementKey), isTrue, reason: 'three equal parts');
      expect(isWeakTripleDesKey(unhex('0101010101010101 1112131415161718 2122232425262728')), isTrue, reason: 'a weak DES key');
      expect(isWeakTripleDesKey(unhex('01fe01fe01fe01fe 1112131415161718 2122232425262728')), isTrue, reason: 'a semi-weak DES key');
      expect(isWeakTripleDesKey(unhex('0102030405060708 1112131415161718 2122232425262728')), isFalse);
      expect(isWeakTripleDesKey(unhex('0102030405060708')), isTrue);
    });
  });
}
