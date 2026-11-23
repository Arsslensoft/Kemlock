import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/crypto/keys/x509.dart';
import 'package:kemlock/security_key/piv/piv_commands.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/security_key/piv/piv_operations.dart';
import 'package:kemlock/security_key/piv/piv_session.dart';

import '../../crypto/keys/x509_software.dart';
import '../../fakes/fake_piv_card.dart';

void main() {
  final from = DateTime.utc(2026, 11, 16);
  final until = DateTime.utc(2028, 11, 16);

  /// The PIV application of [fake], selected and read, as the app opens it.
  Future<PivSession> open(FakePivCard fake) {
    fake.selectAnswer;
    return PivSession.open(fake.transmit);
  }

  PublicHalf publicOf(KeyMaterial key) => switch (key) {
    RsaMaterial(:final n, :final e) => RsaPublicHalf(n, e),
    EcMaterial(:final curve, :final point) => EcPublicHalf(curve, point),
    _ => throw StateError('not a slot key'),
  };

  group('a slot signs its own certificate', () {
    for (final algorithm in PivAlgorithm.values) {
      test('${algorithm.name}: in every slot, with the PIN where the slot wants it', () async {
        for (final slot in PivSlot.values) {
          final fake = FakePivCard();
          final key = publicOf(fake.generate(slot, algorithm));
          final session = await open(fake);
          session.holdPin(pivFactoryPin.codeUnits);
          final der = await pivSelfSigned(session, slot, key, commonName: 'Ada Example', notBefore: from, notAfter: until);

          final certificate = readCertificate(der);
          expect(verifyOwnSignature(certificate), isTrue, reason: slot.id);
          expect((certificate.subject.commonName, certificate.notAfter), ('Ada Example', until));
          expect(fake.log.contains('verify'), slot.needsPin, reason: slot.id);
        }
      });
    }

    test('the signature slot is given the PIN before each signature, the others once', () async {
      final fake = FakePivCard();
      final session = await open(fake);
      session.holdPin(pivFactoryPin.codeUnits);
      await session.verifyPin();
      for (final slot in [PivSlot.authentication, PivSlot.signature]) {
        final key = publicOf(fake.generate(slot, PivAlgorithm.eccP256));
        fake.log.clear();
        await pivSelfSigned(session, slot, key, commonName: 'A', notBefore: from, notAfter: until, pinVerified: true);
        expect(fake.log.where((line) => line == 'verify'), hasLength(slot == PivSlot.signature ? 1 : 0), reason: slot.id);
      }
    });

    test('a signature that does not verify is refused, and nothing is stored', () async {
      final fake = FakePivCard()..signsWrongly = true;
      final key = publicOf(fake.generate(PivSlot.cardAuthentication, PivAlgorithm.eccP256));
      final session = await open(fake);
      await expectLater(
        pivSelfSigned(session, PivSlot.cardAuthentication, key, commonName: 'A', notBefore: from, notAfter: until),
        throwsA(isA<PivBadSignature>()),
      );
      await expectLater(pivRequest(session, PivSlot.cardAuthentication, key, commonName: 'A'), throwsA(isA<PivBadSignature>()));
      expect(fake.log.where((line) => line.startsWith('put')), isEmpty);
    });

    test('a request is a PKCS#10 request for the slot’s key that verifies', () async {
      final fake = FakePivCard();
      final key = publicOf(fake.generate(PivSlot.signature, PivAlgorithm.eccP384));
      final session = await open(fake);
      session.holdPin(pivFactoryPin.codeUnits);
      final request = readCertificateRequest(await pivRequest(session, PivSlot.signature, key, commonName: 'Ada Example'));
      expect((request.verifies, request.subject.commonName), (true, 'Ada Example'));
      expect(samePublicKey(request.publicKey!, key), isTrue);
    });
  });

  group('storing a certificate', () {
    test('writes both identifier objects on a card without them, and a fresh identifier each time', () async {
      final fake = FakePivCard();
      final session = await open(fake);
      await session.card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      expect(session.state.cardId, isNull);

      await pivStoreCertificate(session, PivSlot.authentication, Uint8List.fromList([0x30, 0x00]));
      final ccc = Uint8List.fromList(fake.objects[pivCccObject]!);
      final first = readPivChuidGuid(pivTlv(0x53, fake.objects[pivChuidObject]!));
      expect(session.state.cardId, readPivCccId(pivTlv(0x53, ccc)));

      await pivStoreCertificate(session, PivSlot.signature, Uint8List.fromList([0x30, 0x00]));
      expect(fake.objects[pivCccObject], ccc, reason: 'the container is written once');
      expect(readPivChuidGuid(pivTlv(0x53, fake.objects[pivChuidObject]!)), isNot(first));
    });

    test('removing writes an empty object and touches neither identifier', () async {
      final fake = FakePivCard()..putCertificate(PivSlot.keyManagement, [0x30, 0x00]);
      final session = await open(fake);
      await session.card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
      await pivStoreCertificate(session, PivSlot.keyManagement, null);
      expect(fake.objects[PivSlot.keyManagement.object], isEmpty);
      expect(fake.certificate(PivSlot.keyManagement), isNull);
      expect(fake.objects.containsKey(pivChuidObject), isFalse);
    });

    test('an imported certificate for another key is refused before anything is sent', () async {
      final fake = FakePivCard();
      final slotKey = publicOf(fake.generate(PivSlot.authentication, PivAlgorithm.eccP256));
      final other = publicOf(FakePivCard().generate(PivSlot.authentication, PivAlgorithm.eccP256));
      final authority = FakePivCard().generate(PivSlot.authentication, PivAlgorithm.eccP384);
      Uint8List issued(PublicHalf key) =>
          issueCertificate(subjectKey: key, commonName: 'Ada Example', authorityKey: authority, notBefore: from, notAfter: until);
      final session = await open(fake);
      await session.card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);

      await expectLater(
        pivImportCertificate(session, PivSlot.authentication, readCertificate(issued(other))),
        throwsA(isA<PivKeyMismatch>()),
      );
      expect(fake.log.where((line) => line.startsWith('put')), isEmpty);

      final mine = issued(slotKey);
      await pivImportCertificate(session, PivSlot.authentication, readCertificate(mine));
      expect(fake.certificate(PivSlot.authentication), mine);
    });
  });

  group('the management key', () {
    test('a new triple DES key has odd parity and is never weak; an AES one is its length', () {
      for (var i = 0; i < 50; i++) {
        final key = newPivManagementKey(PivManagementKeyType.tripleDes);
        expect(key, hasLength(24));
        expect(key, withOddParity(key));
        expect(isWeakTripleDesKey(key), isFalse);
      }
      expect(newPivManagementKey(PivManagementKeyType.aes256), hasLength(32));
      // Three equal parts are weak: a fresh draw is made
      var draws = 0;
      final key = newPivManagementKey(
        PivManagementKeyType.tripleDes,
        random: (length) => draws++ == 0 ? Uint8List(length) : Uint8List.fromList(List.generate(length, (i) => i * 7 + 3)),
      );
      expect((draws, isWeakTripleDesKey(key)), (2, false));
    });

    test('a typed key is read with spaces, colons and either case, and refused at a wrong length', () {
      expect(parsePivManagementKey('0102 0304 0506 0708 0102 0304 0506 0708 0102 0304 0506 0708'), pivFactoryManagementKey);
      expect(parsePivManagementKey('01:02:03:04:05:06:07:08:01:02:03:04:05:06:07:08:01:02:03:04:05:06:07:08'), pivFactoryManagementKey);
      expect(parsePivManagementKey('AbCd' * 8), hasLength(16));
      expect(parsePivManagementKey('abcd' * 7), isNull);
      expect(parsePivManagementKey('xyz0' * 12), isNull);
      expect(formatPivManagementKey(pivFactoryManagementKey), '0102 0304 0506 0708 0102 0304 0506 0708 0102 0304 0506 0708');
    });

    test('a key is tried as each kind of its length, the one the card reports first', () async {
      final aes192 = FakePivCard(makerCommands: false, managementKeyType: PivManagementKeyType.aes192, managementKey: List.filled(24, 9));
      final session = await open(aes192);
      expect(await pivAuthenticate(session, List.filled(24, 9)), PivManagementKeyType.aes192);
      await expectLater(pivAuthenticate(session, List.filled(24, 8)), throwsA(isA<PivManagementKeyRefused>()));

      final reported = FakePivCard(managementKeyType: PivManagementKeyType.aes192, managementKey: List.filled(24, 9));
      final read = await open(reported);
      reported.log.clear();
      expect(await pivAuthenticate(read, List.filled(24, 9)), PivManagementKeyType.aes192);
      expect(reported.log, ['auth', 'auth'], reason: 'one exchange, of the kind the card reported');
    });
  });

  group('reset', () {
    test('blocks the PIN, then the PUK, then resets, whatever the codes were', () async {
      for (final (pin, puk) in [(pivFactoryPin, pivFactoryPuk), ('00000000', '11111111'), ('11111111', '00000000')]) {
        final fake = FakePivCard(pin: pin, puk: puk, managementKeyType: PivManagementKeyType.aes256, managementKey: List.filled(32, 1))
          ..putCertificate(PivSlot.authentication, [0x30, 0x00]);
        fake.generate(PivSlot.authentication, PivAlgorithm.eccP256);
        final session = await open(fake);

        await pivReset(session);

        expect(fake.log.where((line) => line == 'reset'), hasLength(1), reason: '$pin $puk');
        expect(fake.keys, isEmpty);
        expect(fake.objects, isEmpty);
        expect((fake.pin, fake.puk, fake.pinTries, fake.pukTries), (pivFactoryPin, pivFactoryPuk, 3, 3));
        expect(session.state.factoryManagementKey, isTrue);
        expect(session.state.slotsInUse, 0);
      }
    });

    test('is never started on a card without the maker’s commands', () async {
      final fake = FakePivCard(makerCommands: false);
      final session = await open(fake);
      await expectLater(pivReset(session), throwsA(isA<PivNotSupported>()));
      expect((fake.pinTries, fake.pukTries), (3, 3));
    });

    test('finishes on a card whose codes are both blocked already', () async {
      final fake = FakePivCard()
        ..pinTries = 0
        ..pukTries = 0;
      final session = await open(fake);
      await pivReset(session);
      expect(fake.log.where((line) => line == 'verify' || line == 'unblock'), hasLength(2));
      expect((fake.pinTries, fake.pukTries), (3, 3));
    });
  });
}
