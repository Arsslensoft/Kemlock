import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/security_key/openpgp_card/card_session.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';

const _nfc = {SecurityKeyLinkKind.nfc};

Uint8List _pin(String pin) => Uint8List.fromList(utf8.encode(pin));

void main() {
  late FakeSecurityKeys phone;

  /// Opens [card] held to a fake phone and runs [action] on its session.
  Future<T> onCard<T>(FakeOpenPgpCard card, Future<T> Function(OpenPgpCardSession session) action) {
    phone = FakeSecurityKeys();
    phone.arrive(FakeKey(applets: [card]).device(kinds: _nfc));
    return runOnKey(phone, (connection) async => action(await OpenPgpCardSession.open(connection)), now: phone.now);
  }

  group('opening', () {
    test('reads what the card reports and sends no PIN', () async {
      final card = FakeOpenPgpCard()..cardholder = 'Lovelace<<Ada';
      card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)), fingerprint: Uint8List(20)..[0] = 1);
      card.setTouch(CardPlace.signature, TouchPolicy.on);

      final snapshot = await onCard(card, (session) async => session.read);

      expect(snapshot.aid.serial, '12345678');
      expect(snapshot.aid.version, '3.4');
      expect(snapshot.data.attributes[CardPlace.signature]!.name, 'ed25519');
      expect(snapshot.fingerprintHex(CardPlace.signature), '01${'00' * 19}');
      expect(snapshot.data.holdsKey(CardPlace.signature), isTrue);
      expect(snapshot.data.holdsKey(CardPlace.decryption), isFalse);
      expect(snapshot.pinStatus.pinTries, 3);
      expect(snapshot.touch[CardPlace.signature]!.policy, TouchPolicy.on);
      expect(snapshot.touch[CardPlace.decryption]!.policy, TouchPolicy.off);
      expect(snapshot.kdf!.on, isFalse);
      expect(snapshot.algorithms!.of(CardPlace.signature), isNotEmpty);
      expect(snapshot.cardholder, 'Ada Lovelace');
      expect(snapshot.signatureCounter, 0);
      expect(card.log.where((entry) => entry.startsWith('verify')), isEmpty);
      expect(card.pinsSent, isEmpty);
    });

    test('of a card without touch settings, an algorithm list or hashed PINs, gives none of them', () async {
      final card = FakeOpenPgpCard(versionMajor: 2, versionMinor: 1, touchSettings: false, kdfSupported: false);

      final snapshot = await onCard(card, (session) async => session.read);

      expect(snapshot.aid.version, '2.1');
      expect(snapshot.touch, isEmpty);
      expect(snapshot.algorithms, isNull);
      expect(snapshot.kdf, isNull);
      expect(snapshot.data.keyInformation, isNull);
    });

    test('of a terminated card gives a session that can finish the reset', () async {
      final card = FakeOpenPgpCard()..terminated = true;

      final (terminated, snapshot) = await onCard(card, (session) async {
        final terminated = session.terminated;
        return (terminated, await session.finishReset());
      });

      expect(terminated, isTrue);
      expect(snapshot.pinStatus.adminPinTries, 3);
      expect(card.terminated, isFalse);
    });

    test('of a key without the application says so', () async {
      phone = FakeSecurityKeys();
      phone.arrive(FakeKey().device(kinds: _nfc));
      await expectLater(
        runOnKey(phone, (connection) => OpenPgpCardSession.open(connection), now: phone.now),
        throwsA(isA<SecurityKeyNoApplication>()),
      );
    });
  });

  group('PINs', () {
    late FakeOpenPgpCard card;

    setUp(() async {
      card = FakeOpenPgpCard();
      card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));
    });

    test('one not held is asked for with the tries read just then', () async {
      card.pinTries = 2;

      final error = await onCard(card, (session) async {
        try {
          await session.sign(Uint8List(64));
        } on CardPinNeeded catch (error) {
          return error;
        }
        return null;
      });

      expect(error!.pin, CardPin.pinToSign);
      expect(error.triesLeft, 2);
      expect(card.log.last, 'get c4');
      expect(card.pinsSent, isEmpty);
    });

    test('a held one is sent, and a wrong one is forgotten with the tries read again', () async {
      final (signature, wrong, heldAfter) = await onCard(card, (session) async {
        session.holdPin(CardPin.pin, _pin('654321'));
        CardWrongPin? wrong;
        try {
          await session.sign(Uint8List(64));
        } on CardWrongPin catch (error) {
          wrong = error;
        }
        final held = session.holds(CardPin.pin);
        session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
        return (await session.sign(Uint8List(64)), wrong, held);
      });

      expect(wrong!.triesLeft, 2);
      expect(heldAfter, isFalse);
      expect(signature, hasLength(64));
    });

    // A wrong value is answered 6982 by the specification's cards and 63Cx by some others
    for (final (name, inStatus) in [('6982', false), ('63Cx', true)]) {
      group('on a card that answers a wrong value $name', () {
        setUp(() async {
          card = FakeOpenPgpCard(wrongPinInStatus: inStatus);
          card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));
        });

        test('a wrong PIN is said with the tries left, forgotten, and never sent a second time', () async {
          final (wrong, again) = await onCard(card, (session) async {
            session.holdPin(CardPin.pin, _pin('654321'));
            CardWrongPin? wrong;
            try {
              await session.sign(Uint8List(64));
            } on CardWrongPin catch (error) {
              wrong = error;
            }
            CardPinNeeded? again;
            try {
              await session.sign(Uint8List(64));
            } on CardPinNeeded catch (error) {
              again = error;
            }
            return (wrong, again);
          });

          expect(wrong!.pin, CardPin.pinToSign);
          expect(wrong.triesLeft, 2);
          expect(again!.triesLeft, 2, reason: 'the PIN is asked for again, not sent again');
          expect(card.pinsSent, hasLength(1));
          expect(card.pinTries, 2);
        });

        test('a wrong admin PIN is forgotten too, and the PIN held beside it is kept', () async {
          final (wrong, holdsAdmin, holdsPin) = await onCard(card, (session) async {
            session
              ..holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin))
              ..holdPin(CardPin.admin, _pin('87654321'));
            CardWrongPin? wrong;
            try {
              await session.setTouch(CardPlace.signature, TouchPolicy.on);
            } on CardWrongPin catch (error) {
              wrong = error;
            }
            return (wrong, session.holds(CardPin.admin), session.holds(CardPin.pin));
          });

          expect(wrong!.pin, CardPin.admin);
          expect(wrong.triesLeft, 2);
          expect(holdsAdmin, isFalse);
          expect(holdsPin, isTrue);
          expect(card.touch[CardPlace.signature], isNot(TouchPolicy.on));
        });

        test('the wrong PIN that spends the last try says the PIN is blocked', () async {
          card.pinTries = 1;

          await expectLater(
            onCard(card, (session) async {
              session.holdPin(CardPin.pin, _pin('654321'));
              await session.sign(Uint8List(64));
            }),
            throwsA(isA<CardPinBlocked>().having((e) => e.pin, 'pin', CardPin.pinToSign)),
          );

          expect(card.pinTries, 0);
          expect(card.pinsSent, hasLength(1));
        });

        test('a change with a wrong current PIN says so with the tries left', () async {
          final wrong = await onCard(card, (session) async {
            try {
              await session.changePin(CardPin.admin, _pin('00000000'), _pin('87654321'));
            } on CardWrongPin catch (error) {
              return error;
            }
            return null;
          });

          expect(wrong!.pin, CardPin.admin);
          expect(wrong.triesLeft, 2);
          expect(card.adminPin, FakeOpenPgpCard.factoryAdminPin);
        });

        test('a wrong reset code says so with the tries left', () async {
          card
            ..resetCode = '11112222'
            ..resetCodeTries = 3;

          final wrong = await onCard(card, (session) async {
            try {
              await session.unblockWithResetCode(_pin('99998888'), _pin('654321'));
            } on CardWrongPin catch (error) {
              return error;
            }
            return null;
          });

          expect(wrong!.pin, CardPin.resetCode);
          expect(wrong.triesLeft, 2);
          expect(card.pin, FakeOpenPgpCard.factoryPin);
        });

        test('a factory reset blocks both PINs and brings the card back empty', () async {
          final snapshot = await onCard(card, (session) => session.factoryReset());

          expect(snapshot.data.holdsKey(CardPlace.signature), isFalse);
          expect(snapshot.pinStatus.pinTries, 3);
          expect(card.keys, isEmpty);
          expect(card.log, containsAllInOrder(['terminate', 'activate']));
        });
      });
    }

    test('a factory reset blocks a PIN of eight "@", which its wrong value is not', () async {
      // The card takes PINs of up to 127 bytes, as a YubiKey does
      card
        ..pin = '@@@@@@@@'
        ..adminPin = '@@@@@@@@';

      final snapshot = await onCard(card, (session) => session.factoryReset());

      expect(card.keys, isEmpty);
      expect(snapshot.pinStatus.pinTries, 3);
      expect(card.pin, FakeOpenPgpCard.factoryPin);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a factory reset on a card whose tries do not fall ends before the card is terminated', () async {
      card.countsWrongValues = false;

      await expectLater(onCard(card, (session) => session.factoryReset()), throwsA(isA<CardNotSupported>()));

      expect(card.log.where((entry) => entry.startsWith('verify')), hasLength(1));
      expect(card.log, isNot(contains('terminate')));
      expect(card.keys, hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('nothing is sent when no try is left', () async {
      card.pinTries = 0;

      await expectLater(
        onCard(card, (session) async {
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          await session.sign(Uint8List(64));
        }),
        throwsA(isA<CardPinBlocked>()),
      );

      expect(card.pinsSent, isEmpty);
      expect(card.log.where((entry) => entry.startsWith('verify') || entry == 'sign'), isEmpty);
    });

    test('a change of PIN is not sent when no try is left', () async {
      card.pinTries = 0;

      await expectLater(
        onCard(card, (session) => session.changePin(CardPin.pin, _pin('123456'), _pin('654321'))),
        throwsA(isA<CardPinBlocked>()),
      );

      expect(card.pinsSent, isEmpty);
    });

    test('are not in the session after it is closed', () async {
      final session = await onCard(card, (session) async {
        session
          ..holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin))
          ..holdPin(CardPin.admin, _pin(FakeOpenPgpCard.factoryAdminPin));
        await session.sign(Uint8List(64));
        return session;
      });
      expect(session.holdsAnyPin, isTrue);

      session.close();

      expect(session.holdsAnyPin, isFalse);
      expect(session.holds(CardPin.pin), isFalse);
      expect(session.holds(CardPin.admin), isFalse);
    });

    test('the PIN is sent again before each signature on a card that wants it, and once on one that does not', () async {
      Future<int> verifiesForTwo(bool every) async {
        card
          ..pinForEverySignature = every
          ..log.clear();
        await onCard(card, (session) async {
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          await session.sign(Uint8List(64));
          await session.sign(Uint8List(64));
        });
        return card.log.where((entry) => entry == 'verify 81').length;
      }

      expect(await verifiesForTwo(true), 2);
      expect(await verifiesForTwo(false), 1);
    });
  });
  group('hashed PINs', () {
    late FakeOpenPgpCard card;

    setUp(() async {
      card = FakeOpenPgpCard();
      card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));
      // The PINs as typed must never reach a card that hashes them
      card.forbidden.addAll([FakeOpenPgpCard.factoryPin, FakeOpenPgpCard.factoryAdminPin]);
    });

    for (final (name, hashAlgorithm) in [('SHA-256', 0x08), ('SHA-512', 0x0a)]) {
      test('with $name: the right PIN is taken, hashed, and never sent plain', () async {
        card.hashPins(hashAlgorithm: hashAlgorithm);

        final signature = await onCard(card, (session) async {
          expect(session.read.kdf!.on, isTrue);
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          return session.sign(Uint8List(64));
        });

        expect(signature, hasLength(64));
        expect(card.pinTries, 3);
        expect(card.forbiddenSeen, isEmpty);
        expect(card.pinsSent.single, hasLength(hashAlgorithm == 0x0a ? 64 : 32));
      });
    }

    test('a change of the admin PIN is hashed both ways', () async {
      card.hashPins(hashAlgorithm: 0x08);
      card.nextPins.add('87654321');

      await onCard(card, (session) => session.changePin(CardPin.admin, _pin(FakeOpenPgpCard.factoryAdminPin), _pin('87654321')));

      expect(card.adminPin, '87654321');
      expect(card.forbiddenSeen, isEmpty);
    });

    test('a KDF object Kemlock cannot follow sends nothing and spends no try', () async {
      card.kdf = Uint8List.fromList([0x81, 0x01, 0x04]);

      await expectLater(
        onCard(card, (session) async {
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          return session.sign(Uint8List(64));
        }),
        throwsA(isA<CardKdfUnreadable>()),
      );

      expect(card.pinsSent, isEmpty);
      expect(card.pinTries, 3);
      expect(card.log.where((entry) => entry.startsWith('verify')), isEmpty);
    });
  });
}
