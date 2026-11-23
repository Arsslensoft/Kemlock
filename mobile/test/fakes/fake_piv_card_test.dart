import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/crypto/keys/der.dart';
import 'package:kemlock/security_key/piv/piv_commands.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';

import 'fake_piv_card.dart';

void main() {
  late FakePivCard fake;
  late PivCard card;

  setUp(() {
    fake = FakePivCard();
    fake.selectAnswer;
    card = PivCard(fake.transmit);
  });

  group('the PIN', () {
    test('blocks after three wrong tries, and the right one no longer opens it', () async {
      for (final left in [2, 1]) {
        await expectLater(card.verifyPin('000000'.codeUnits), throwsA(isA<PivWrongCode>().having((e) => e.triesLeft, 'triesLeft', left)));
      }
      await expectLater(card.verifyPin('000000'.codeUnits), throwsA(isA<PivBlocked>()));
      await expectLater(card.verifyPin('123456'.codeUnits), throwsA(isA<PivBlocked>()));
      expect(fake.pinTries, 0);
    });

    test('a verify with no PIN reports the count and does not lower it', () async {
      expect(await card.pinTries(), 3);
      expect(await card.pinTries(), 3);
      await expectLater(card.verifyPin('000000'.codeUnits), throwsA(isA<PivWrongCode>()));
      expect(await card.pinTries(), 2);
      expect(fake.pinTries, 2);
    });

    test('the right PIN fills the counter again', () async {
      await expectLater(card.verifyPin('000000'.codeUnits), throwsA(isA<PivWrongCode>()));
      await card.verifyPin('123456'.codeUnits);
      expect(fake.pinTries, 3);
    });

    test('is changed with the current one, and unblocked with the PUK', () async {
      await card.changePin('123456'.codeUnits, '24681012'.codeUnits);
      expect(fake.pin, '24681012');
      fake.pinTries = 0;
      await expectLater(card.unblockPin('00000000'.codeUnits, '111222'.codeUnits), throwsA(isA<PivWrongCode>()));
      expect(fake.pukTries, 2);
      await card.unblockPin('12345678'.codeUnits, '111222'.codeUnits);
      expect((fake.pin, fake.pinTries, fake.pukTries), ('111222', 3, 3));
    });
  });

  group('the management key', () {
    test('of either kind is proven by the exchange, and a wrong one is refused', () async {
      await card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      expect(fake.authenticated, isTrue);

      final aes = List.generate(32, (i) => 0x40 + i);
      await card.setManagementKey(PivManagementKeyType.aes256, aes);
      fake.selectAnswer;
      await expectLater(
        card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey),
        throwsA(isA<PivManagementKeyRefused>()),
      );
      await expectLater(card.authenticate(PivManagementKeyType.aes256, List.filled(32, 1)), throwsA(isA<PivManagementKeyRefused>()));
      expect(fake.authenticated, isFalse);
      await card.authenticate(PivManagementKeyType.aes256, aes);
      expect(fake.authenticated, isTrue);
    });

    test('is wanted before a key is generated or a data object written', () async {
      await expectLater(card.generate(PivSlot.authentication, PivAlgorithm.eccP256), throwsA(isA<PivSecurityStatus>()));
      await expectLater(card.putData(PivSlot.authentication.object, const [1]), throwsA(isA<PivSecurityStatus>()));
      expect(fake.keys, isEmpty);
    });
  });

  group('a slot’s key', () {
    Future<void> signs(PivSlot slot, PivAlgorithm algorithm) async {
      await card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      final public = await card.generate(slot, algorithm);
      final message = Uint8List.fromList('what is signed'.codeUnits);
      if (slot.needsPin) await card.verifyPin('123456'.codeUnits);
      switch (public) {
        case RsaPublicHalf():
          final digest = hash.sha256.convert(message).bytes;
          final signature = await card.sign(slot, algorithm, emsaPkcs1(oidSha256, digest, 256));
          expect(rsaVerifyPkcs1(public, oidSha256, digest, bytesToBigInt(signature)), isTrue);
        case EcPublicHalf(:final curve):
          final digest = (curve == EcCurve.p256 ? hash.sha256 : hash.sha384).convert(message).bytes;
          final signature = readSequence(await card.sign(slot, algorithm, digest));
          expect(ecdsaVerify(public, message, signature.integer(), signature.integer()), isTrue);
        default:
          fail('not a key a slot holds');
      }
    }

    for (final algorithm in PivAlgorithm.values) {
      test('of ${algorithm.name} signs, and the signature verifies', () => signs(PivSlot.authentication, algorithm));
    }

    test('signs without the PIN in 9e only, and 9c wants it before every signature', () async {
      await card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      for (final slot in PivSlot.values) {
        await card.generate(slot, PivAlgorithm.eccP256);
      }
      final digest = List.filled(32, 7);
      await card.sign(PivSlot.cardAuthentication, PivAlgorithm.eccP256, digest);
      await expectLater(card.sign(PivSlot.authentication, PivAlgorithm.eccP256, digest), throwsA(isA<PivSecurityStatus>()));
      await card.verifyPin('123456'.codeUnits);
      await card.sign(PivSlot.authentication, PivAlgorithm.eccP256, digest);
      await card.sign(PivSlot.signature, PivAlgorithm.eccP256, digest);
      await expectLater(card.sign(PivSlot.signature, PivAlgorithm.eccP256, digest), throwsA(isA<PivSecurityStatus>()));
    });
  });

  group('the maker’s commands', () {
    test('answer on a card that has them', () async {
      expect(await card.serial(), 12345678);
      expect(await card.version(), (major: 5, minor: 4, patch: 3));
      final pin = await card.metadata(pivPinReference);
      expect((pin.isDefault, pin.triesLeft), (true, 3));
      expect((await card.metadata(pivManagementKeyReference)).isDefault, isTrue);
      await expectLater(card.metadata(PivSlot.authentication.key), throwsA(isA<PivNotFound>()));
    });

    test('answer "not supported" with the switch off', () async {
      fake.makerCommands = false;
      await expectLater(card.serial(), throwsA(isA<PivNotSupported>()));
      await expectLater(card.version(), throwsA(isA<PivNotSupported>()));
      await expectLater(card.metadata(pivPinReference), throwsA(isA<PivNotSupported>()));
      await expectLater(card.setManagementKey(PivManagementKeyType.aes256, List.filled(32, 1)), throwsA(isA<PivNotSupported>()));
      await expectLater(card.reset(), throwsA(isA<PivNotSupported>()));
    });

    test('reset is taken only when the PIN and the PUK are both blocked', () async {
      await card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      await card.generate(PivSlot.authentication, PivAlgorithm.eccP256);
      fake.putCertificate(PivSlot.authentication, const [0x30, 0x00]);
      await card.setManagementKey(PivManagementKeyType.aes256, List.filled(32, 9));
      await expectLater(card.reset(), throwsA(isA<PivRefused>()));
      fake.pinTries = 0;
      await expectLater(card.reset(), throwsA(isA<PivRefused>()));
      fake.pukTries = 0;
      await card.reset();
      expect(fake.keys, isEmpty);
      expect(fake.objects, isEmpty);
      expect((fake.pinTries, fake.pukTries), (3, 3));
      expect(fake.managementKey, pivFactoryManagementKey);
    });
  });

  group('certificates', () {
    test('are read back as they were stored, plain or compressed', () async {
      final der = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x05]);
      fake.putCertificate(PivSlot.authentication, der);
      fake.putCertificate(PivSlot.signature, der, compressed: true);
      expect(unwrapPivCertificate(await card.getData(PivSlot.authentication.object)), der);
      expect(unwrapPivCertificate(await card.getData(PivSlot.signature.object)), der);
      await expectLater(card.getData(PivSlot.keyManagement.object), throwsA(isA<PivNotFound>()));
    });

    test('all but 9e’s are refused with the "over NFC" switch on', () async {
      fake.refuseOverNfc = true;
      fake.putCertificate(PivSlot.cardAuthentication, const [0x30, 0x00]);
      await expectLater(card.getData(PivSlot.authentication.object), throwsA(isA<PivSecurityStatus>()));
      await card.getData(PivSlot.cardAuthentication.object);
    });
  });
}
