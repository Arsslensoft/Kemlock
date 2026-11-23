import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/secret_key.dart';
import 'package:kemlock/crypto/keys/pem.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/security_key/openpgp_card/card_move.dart';
import 'package:kemlock/security_key/openpgp_card/card_session.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';

Uint8List _key(String path) {
  final bytes = File('test/fixtures/keys/$path').readAsBytesSync();
  return path.endsWith('.asc') ? readArmor(readPemBlocks(utf8.decode(bytes)).single) : bytes;
}

Future<T> _onCard<T>(FakeOpenPgpCard card, Future<T> Function(OpenPgpCardSession session) action) {
  final phone = FakeSecurityKeys();
  phone.arrive(FakeKey(applets: [card]).device(kinds: {SecurityKeyLinkKind.nfc}));
  return runOnKey(phone, (connection) async => action(await OpenPgpCardSession.open(connection)), now: phone.now);
}

Future<CardSnapshot> _snapshot(FakeOpenPgpCard card) => _onCard(card, (session) async => session.read);

String _fp(KeyPacket packet) => cardHex(packet.fingerprint);

void main() {
  final now = DateTime.utc(2026, 11, 18);

  test('a key Kemlock generated: its primary key signs, its subkey decrypts, and nothing authenticates', () async {
    final key = _key('kemlock/pgp-ed25519.unprotected.asc');
    final info = readPgpKeyInfo(key);

    final plan = cardMovePlan(key, await _snapshot(FakeOpenPgpCard()), now);

    expect(plan.fits, isTrue);
    expect(_fp(plan.parts[CardPlace.signature]!.$1), info.primary.fingerprintHex);
    expect(_fp(plan.parts[CardPlace.decryption]!.$1), info.subkeys.single.fingerprintHex);
    expect(plan.parts.containsKey(CardPlace.authentication), isFalse);
    expect(plan.parts[CardPlace.signature]!.$2.name, 'ed25519');
    expect(plan.parts[CardPlace.decryption]!.$2.name, 'cv25519');
  });

  test('a GnuPG key with a certify-only primary: its signing, newest valid encryption and authentication subkeys', () async {
    final key = _key('gnupg/card/subkeys.secret.gpg');
    final info = readPgpKeyInfo(key);
    // The first encryption subkey expired in 2020; the newer one is valid
    final [expired, signing, encryption, authentication] = info.subkeys;
    expect(expired.expires, isNotNull);

    final plan = cardMovePlan(key, await _snapshot(FakeOpenPgpCard()), now);

    expect(plan.fits, isTrue);
    expect(_fp(plan.parts[CardPlace.signature]!.$1), signing.fingerprintHex);
    expect(_fp(plan.parts[CardPlace.decryption]!.$1), encryption.fingerprintHex);
    expect(_fp(plan.parts[CardPlace.authentication]!.$1), authentication.fingerprintHex);
    expect(_fp(plan.parts[CardPlace.decryption]!.$1), isNot(expired.fingerprintHex));
  });

  test('a key the card does not list a place for cannot be held', () async {
    final key = _key('kemlock/pgp-rsa4096.unprotected.asc');

    final plan = cardMovePlan(key, await _snapshot(FakeOpenPgpCard(algorithms: fakeCardAlgorithms(rsa: false))), now);

    expect(plan.fits, isFalse);
    expect(plan.cannotHold, CardPlace.signature);
  });

  test('a NIST P-256 key, whose secret Kemlock cannot take out, cannot be held', () async {
    final key = readArmor(readPemBlocks(File('test/fixtures/pgp/gnupg/nistp256.secret.asc').readAsStringSync()).single);

    final plan = cardMovePlan(key, await _snapshot(FakeOpenPgpCard()), now);

    expect(plan.fits, isFalse);
    expect(plan.cannotHold, CardPlace.signature);
  });

  group('putting the key on the card', () {
    Future<void> move(FakeOpenPgpCard card, Uint8List key) => _onCard(card, (session) async {
      session.holdPin(CardPin.admin, Uint8List.fromList(utf8.encode(FakeOpenPgpCard.factoryAdminPin)));
      session.holdPin(CardPin.pin, Uint8List.fromList(utf8.encode(FakeOpenPgpCard.factoryPin)));
      final plan = cardMovePlan(key, session.read, now);
      final packets = readTransferableKey(key).packets.where((p) => p.tag == 5 || p.tag == 7).map(parseKeyPacket).toList();
      await cardImportPlan(session, plan, (packet) => unlockSecretKey(packets.firstWhere((p) => _fp(p) == _fp(packet))));
    });

    test('Ed25519 with Curve25519: the card holds them, signs, opens and is read back with their fingerprints', () async {
      final card = FakeOpenPgpCard();
      final key = _key('gnupg/card/subkeys.secret.gpg');

      await move(card, key);

      final info = readPgpKeyInfo(key);
      expect(cardHex(card.fingerprints[CardPlace.signature]!), info.subkeys[1].fingerprintHex);
      expect(cardHex(card.fingerprints[CardPlace.decryption]!), info.subkeys[2].fingerprintHex);
      expect(cardHex(card.fingerprints[CardPlace.authentication]!), info.subkeys[3].fingerprintHex);
      expect(card.log, containsAll(['import b6', 'import b8', 'import a4', 'sign', 'decipher', 'authenticate']));
    });

    for (final (form, attributes) in [
      ('e, p and q', [0x01, 0x10, 0x00, 0x00, 0x20, 0x00]),
      ('the CRT form with the modulus', [0x01, 0x10, 0x00, 0x00, 0x20, 0x03]),
    ]) {
      test('RSA in $form', () async {
        final rsa = CardAlgorithm.parse(attributes);
        final card = FakeOpenPgpCard(
          algorithms: {
            for (final place in CardPlace.values) place: [rsa],
          },
        );
        final key = _key('kemlock/pgp-rsa4096.unprotected.asc');

        await move(card, key);

        final info = readPgpKeyInfo(key);
        expect(cardHex(card.fingerprints[CardPlace.signature]!), info.primary.fingerprintHex);
        expect(cardHex(card.fingerprints[CardPlace.decryption]!), info.subkeys.single.fingerprintHex);
        expect(card.attributes[CardPlace.signature], rsa);
      });
    }

    test('a card that does not show the key afterwards stops the move', () async {
      final card = FakeOpenPgpCard();
      card.ignoreFingerprints = true;
      await expectLater(move(card, _key('kemlock/pgp-ed25519.unprotected.asc')), throwsA(isA<CardIncompleteMove>()));
    });
  });
}
