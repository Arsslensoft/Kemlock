import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/modes.dart' show cipherAes256;
import 'package:kemlock/crypto/keys/openpgp/packets.dart';
import 'package:kemlock/crypto/keys/openpgp/session_key.dart';
import 'package:kemlock/crypto/keys/openpgp/signatures.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/security_key/openpgp_card/card_operations.dart';
import 'package:kemlock/security_key/openpgp_card/card_session.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';

const _nfc = {SecurityKeyLinkKind.nfc};
final _created = DateTime.utc(2026, 11, 17);
final _random = Random.secure();

Uint8List _bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

Uint8List _pin(String pin) => Uint8List.fromList(utf8.encode(pin));

/// Runs [action] on [card] held to a fake phone.
Future<T> _onCard<T>(FakeOpenPgpCard card, Future<T> Function(OpenPgpCardSession session) action) {
  final phone = FakeSecurityKeys();
  phone.arrive(FakeKey(applets: [card]).device(kinds: _nfc));
  return runOnKey(phone, (connection) async {
    final session = await OpenPgpCardSession.open(connection);
    try {
      return await action(session);
    } finally {
      session.close();
    }
  }, now: phone.now);
}

/// A card with keys of [kinds] in the signature and decryption places,
/// their fingerprints written as GnuPG's keytocard writes them, and the
/// key packets they are.
Future<(FakeOpenPgpCard, KeyPacket, KeyPacket)> _card(CardAlgorithm Function(CardPlace place) kinds) async {
  final card = FakeOpenPgpCard();
  for (final place in [CardPlace.signature, CardPlace.decryption]) {
    card.load(place, await FakeCardKey.generate(kinds(place)), algorithm: kinds(place));
  }
  final packets = await _onCard(card, (session) async {
    return [
      for (final (place, tag) in [(CardPlace.signature, PgpTag.publicKey), (CardPlace.decryption, PgpTag.publicSubkey)])
        cardKeyPacket(cardKeyPacketBody(kinds(place), await session.readPublicKey(place), _created), tag: tag),
    ];
  });
  card.fingerprints[CardPlace.signature] = packets[0].fingerprint;
  card.fingerprints[CardPlace.decryption] = packets[1].fingerprint;
  return (card, packets[0], packets[1]);
}

void main() {
  final kinds = <String, CardAlgorithm Function(CardPlace)>{
    'Ed25519 with Curve25519': fake25519,
    'RSA 2048': (_) => RsaAttributes.ofBits(2048),
    'NIST P-256': fakeNist,
    'NIST P-384': (place) => fakeNist(place, p384: true),
  };

  for (final MapEntry(key: name, value: kind) in kinds.entries) {
    group(name, () {
      late FakeOpenPgpCard card;
      late KeyPacket signer;
      late KeyPacket recipient;

      setUpAll(() async => (card, signer, recipient) = await _card(kind));

      test('a signature the card makes verifies against the public key', () async {
        final digest = Uint8List.fromList(hash.sha512.convert(utf8.encode('signed on the card')).bytes);

        final mpis = await _onCard(card, (session) async {
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          return cardSign(session, signer, digest);
        });

        expect(await verifySignatureMaterial(signer, 10, digest, mpis), isTrue);
        expect(await verifySignatureMaterial(signer, 10, Uint8List.fromList(digest)..[0] ^= 1, mpis), isFalse);
      });

      test('a card that returns a wrong signature gives "did not sign correctly" and nothing else', () async {
        card.corruptSignatures = true;
        addTearDown(() => card.corruptSignatures = false);

        await expectLater(
          _onCard(card, (session) async {
            session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
            return cardSign(session, signer, Uint8List(64));
          }),
          throwsA(isA<CardBadSignature>()),
        );
      });

      test("what the card deciphers opens a session key the vault's code wrote to its key", () async {
        final sessionKey = _bytes(32);
        final body = await writePkesk3(recipient, cipherAes256, sessionKey, _bytes(pkeskRandomLength(recipient, 32)));

        final opened = await _onCard(card, (session) async {
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          return openPkesk(parsePkesk(body), recipient, cardSecret(session));
        });

        expect(opened.cipher, cipherAes256);
        expect(opened.key, sessionKey);
      });
    });
  }

  group('the right card', () {
    late FakeOpenPgpCard card;
    late KeyPacket signer;

    setUpAll(() async => (card, signer, _) = await _card(fake25519));

    test('one without the fingerprint is refused before any PIN', () async {
      final other = FakeOpenPgpCard(serial: 0x87654321)
        ..load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));

      await expectLater(
        _onCard(other, (session) async {
          session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
          return cardSign(session, signer, Uint8List(64));
        }),
        throwsA(isA<CardWrongCard>()),
      );
      expect(other.pinsSent, isEmpty);
    });

    test('a second card with the same key is used, whatever its serial', () async {
      final twin = FakeOpenPgpCard(serial: 0x11112222)
        ..load(CardPlace.signature, card.keys[CardPlace.signature]!, fingerprint: card.fingerprints[CardPlace.signature]);
      final digest = Uint8List(64)..[0] = 7;

      final mpis = await _onCard(twin, (session) async {
        session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
        return cardSign(session, signer, digest);
      });

      expect(await verifySignatureMaterial(signer, 10, digest, mpis), isTrue);
    });

    test('two signatures in one connection on a card that wants the PIN for each send it twice and ask for it once', () async {
      card
        ..pinForEverySignature = true
        ..log.clear();
      var asked = 0;

      await _onCard(card, (session) async {
        for (var i = 0; i < 2; i++) {
          try {
            await cardSign(session, signer, Uint8List(64));
          } on CardPinNeeded {
            asked++;
            session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
            await cardSign(session, signer, Uint8List(64));
          }
        }
      });

      expect(asked, 1);
      expect(card.log.where((entry) => entry == 'verify 81'), hasLength(2));
      expect(card.log.where((entry) => entry == 'sign'), hasLength(2));
    });
  });

  test('the authentication key answers a fresh challenge, and the answer verifies', () async {
    final card = FakeOpenPgpCard();
    card.load(CardPlace.authentication, await FakeCardKey.generate(fake25519(CardPlace.authentication)));
    final key = await _onCard(
      card,
      (session) async => cardKeyPacket(
        cardKeyPacketBody(fake25519(CardPlace.authentication), await session.readPublicKey(CardPlace.authentication), _created),
        tag: PgpTag.publicSubkey,
      ),
    );
    card.fingerprints[CardPlace.authentication] = key.fingerprint;

    await _onCard(card, (session) async {
      session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
      await cardAuthenticate(session, key);
    });
    card.corruptSignatures = true;
    await expectLater(
      _onCard(card, (session) async {
        session.holdPin(CardPin.pin, _pin(FakeOpenPgpCard.factoryPin));
        await cardAuthenticate(session, key);
      }),
      throwsA(isA<CardBadSignature>()),
    );
  });
}
