import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/piv/piv_commands.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/security_key/piv/piv_session.dart';

import '../../fakes/fake_piv_card.dart';
import '../../fakes/fake_security_keys.dart';

void main() {
  final certificate = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x05]);

  /// Opens the PIV application of a key with [fake] on it, over the
  /// connection the app uses, and runs [action] in that session.
  Future<T> withSession<T>(FakePivCard fake, Future<T> Function(PivSession session) action) {
    final phone = FakeSecurityKeys();
    phone.arrive(FakeKey(applets: [fake]).device(kinds: {SecurityKeyLinkKind.nfc}));
    return runOnKey(phone, (connection) async {
      final application = await connection.selectApplication(pivAid);
      final session = await PivSession.open(application.transmit);
      try {
        return await action(session);
      } finally {
        session.close();
      }
    });
  }

  group('opening', () {
    test('reads the four slots, the tries and what the maker’s commands say', () async {
      final fake = FakePivCard()
        ..putCertificate(PivSlot.authentication, certificate)
        ..putCertificate(PivSlot.signature, certificate, compressed: true)
        ..generate(PivSlot.authentication, PivAlgorithm.eccP256);

      final state = await withSession(fake, (session) async => session.state);

      expect(
        [for (final slot in PivSlot.values) state.slots[slot]!.status],
        [PivSlotStatus.certificate, PivSlotStatus.certificate, PivSlotStatus.empty, PivSlotStatus.empty],
      );
      expect(state.slots[PivSlot.signature]!.certificate, certificate);
      expect(state.slotsInUse, 2);
      expect(state.slots[PivSlot.authentication]!.publicKey, isNotNull);
      expect(state.slots[PivSlot.signature]!.publicKey, isNull);
      expect((state.pinTries, state.pukTries), (3, 3));
      expect((state.pin!.isDefault, state.puk!.isDefault, state.factoryManagementKey), (true, true, true));
      expect((state.serial, state.version, state.makerCommands), (12345678, (major: 5, minor: 4, patch: 3), true));
      expect(state.keyId, '12345678');
    });

    test('sends no PIN, proves no key and lowers no counter', () async {
      final fake = FakePivCard()..pinTries = 2;

      await withSession(fake, (session) async {});

      expect(fake.log.where((line) => line == 'verify' || line.startsWith('change') || line == 'unblock' || line == 'auth'), isEmpty);
      expect(fake.log, contains('verify?'));
      expect((fake.pinTries, fake.pukTries), (2, 3));
    });

    test('a standard-only card gives no PUK count, no factory-code facts and no sign of a reset', () async {
      final fake = FakePivCard(makerCommands: false);

      final state = await withSession(fake, (session) async => session.state);

      expect(state.pinTries, 3);
      expect((state.pukTries, state.pin, state.puk, state.managementKey), (null, null, null, null));
      expect((state.makerCommands, state.serial, state.version), (false, null, null));
      // Asked once for the PIN's metadata, and not again for the rest of the group
      expect(fake.log.where((line) => line.startsWith('metadata')), isEmpty);
      expect((fake.pinTries, fake.pukTries), (3, 3));
    });

    test('a standard-only card is tried once with the published management key', () async {
      final factory = FakePivCard(makerCommands: false);
      expect((await withSession(factory, (session) async => session.state)).factoryManagementKey, isTrue);
      expect(factory.log.where((line) => line == 'auth'), hasLength(2), reason: 'the two halves of one exchange');

      final changed = FakePivCard(makerCommands: false, managementKey: List.generate(24, (i) => 0x30 + i));
      expect((await withSession(changed, (session) async => session.state)).factoryManagementKey, isFalse);
    });

    test('a card with metadata is not tried with the published key', () async {
      final fake = FakePivCard(managementKeyType: PivManagementKeyType.aes256, managementKey: List.filled(32, 5));
      final state = await withSession(fake, (session) async => session.state);
      expect((state.factoryManagementKey, state.managementKeyType), (false, PivManagementKeyType.aes256));
      expect(fake.log, isNot(contains('auth')));
    });

    test('a slot refused over NFC is reported as such', () async {
      final fake = FakePivCard()
        ..refuseOverNfc = true
        ..putCertificate(PivSlot.authentication, certificate)
        ..putCertificate(PivSlot.cardAuthentication, certificate);

      final state = await withSession(fake, (session) async => session.state);

      expect(state.slots[PivSlot.authentication]!.status, PivSlotStatus.needsContact);
      expect(state.slots[PivSlot.keyManagement]!.status, PivSlotStatus.needsContact);
      expect(state.slots[PivSlot.cardAuthentication]!.status, PivSlotStatus.certificate);
      expect(state.slotsInUse, 1);
    });

    test('an object that is not wrapped as a certificate is unreadable, and kept', () async {
      final fake = FakePivCard()..objects[PivSlot.keyManagement.object] = Uint8List.fromList([0x70, 0x05, 0x01]);
      final state = await withSession(fake, (session) async => session.state);
      expect(state.slots[PivSlot.keyManagement]!.status, PivSlotStatus.unreadable);
      expect(state.slots[PivSlot.keyManagement]!.certificate, isNotNull);
    });

    test('the card identifier names a card with no serial number', () async {
      final fake = FakePivCard()
        ..serial = null
        ..objects[pivCccObject] = buildPivCcc(Uint8List.fromList(List.generate(14, (i) => 0xb0 + i)));
      final state = await withSession(fake, (session) async => session.state);
      expect(state.keyId, 'b0b1b2b3b4b5b6b7b8b9babbbcbd');
      expect(state.hasCapabilityContainer, isTrue);
    });
  });

  group('the held PIN and PUK', () {
    test('are wiped when the session closes', () async {
      final pin = Uint8List.fromList('123456'.codeUnits);
      late PivSession kept;
      await withSession(FakePivCard(), (session) async {
        kept = session..holdPin(pin);
        session.holdPuk('12345678'.codeUnits);
        await session.verifyPin();
      });
      expect(kept.holdsPin, isFalse);
      await expectLater(kept.verifyPin(), throwsStateError);
      await expectLater(kept.unblockPin('111222'.codeUnits), throwsStateError);
    });

    test('the tries are read afresh before a PIN is sent: none left sends nothing', () async {
      final fake = FakePivCard();
      await withSession(fake, (session) async {
        session.holdPin('123456'.codeUnits);
        // Blocked elsewhere since the application was read
        fake.pinTries = 0;
        await expectLater(session.verifyPin(), throwsA(isA<PivBlocked>()));
        await expectLater(session.changePin('654321'.codeUnits), throwsA(isA<PivBlocked>()));
      });
      expect(fake.log.where((line) => line == 'verify' || line == 'change pin'), isEmpty);
    });

    test('one try left sends nothing until the person was warned', () async {
      final fake = FakePivCard()..pinTries = 1;
      await withSession(fake, (session) async {
        session.holdPin('000000'.codeUnits);
        await expectLater(session.verifyPin(), throwsA(isA<PivLastTry>()));
        expect(fake.log, isNot(contains('verify')));
        await expectLater(session.verifyPin(lastTry: true), throwsA(isA<PivBlocked>()));
      });
      expect(fake.pinTries, 0);
    });

    test('the same holds for the PUK on a card that reports its tries, and a card that does not is sent it', () async {
      final fake = FakePivCard()..pukTries = 1;
      await withSession(fake, (session) async {
        session.holdPuk('00000000'.codeUnits);
        await expectLater(session.unblockPin('111222'.codeUnits), throwsA(isA<PivLastTry>()));
        await expectLater(session.changePuk('11112222'.codeUnits), throwsA(isA<PivLastTry>()));
      });
      expect(fake.pukTries, 1);

      final plain = FakePivCard(makerCommands: false)..pukTries = 1;
      await withSession(plain, (session) async {
        session.holdPuk('12345678'.codeUnits);
        await session.unblockPin('111222'.codeUnits);
      });
      expect((plain.pin, plain.pukTries), ('111222', 3));
    });
  });
}
