// The public half of keys generated on the fake OpenPGP card, as the
// Generate sheet makes it (openspec: add-openpgp-card, task 10.4): the
// card's keys made in its three places, their fingerprints and times
// written, the key certified and its subkeys bound by the card. GnuPG
// imported it and found its self-signatures good; the README of
// test/fixtures/keys/gnupg/card records how.
//
// Written once with
//
//   OUT=test/fixtures/keys/gnupg/card flutter test test/security_key/openpgp_card/card_generated_fixture_test.dart
//
// and never again; without OUT the test checks the file.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/security_key/openpgp_card/card_public_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_session.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';

const _file = 'test/fixtures/keys/gnupg/card/generated-ed25519.public.gpg';

void main() {
  final out = Platform.environment['OUT'];

  test('writes the public half of keys generated on the fake card to OUT', () async {
    final card = FakeOpenPgpCard(defaultAlgorithm: fake25519(CardPlace.signature));
    final phone = FakeSecurityKeys();
    phone.arrive(FakeKey(applets: [card]).device(kinds: {SecurityKeyLinkKind.nfc}));
    final public = await runOnKey(phone, (connection) async {
      final session = await OpenPgpCardSession.open(connection);
      session
        ..holdPin(CardPin.admin, Uint8List.fromList(utf8.encode(FakeOpenPgpCard.factoryAdminPin)))
        ..holdPin(CardPin.pin, Uint8List.fromList(utf8.encode(FakeOpenPgpCard.factoryPin)));
      for (final place in CardPlace.values) {
        await session.generate(place);
      }
      await session.refresh();
      final now = DateTime.utc(2026, 11, 16, 12);
      final packets = await cardKeyPackets(session, missingTime: now, writeMissing: true);
      return cardTransferablePublicKey(session, packets, userId: 'Card Fixture <card@example.org>', now: now);
    }, now: phone.now);
    File('$out/generated-ed25519.public.gpg').writeAsBytesSync(public);
  }, skip: out == null ? 'Writes the frozen fixture; set OUT to run' : false);

  test("the key's self-signatures are good, and its three keys are there with their uses", () async {
    final public = File(_file).readAsBytesSync();

    expect(await verifyPgpSelfSignatures(public), isTrue);
    final info = readPgpKeyInfo(public);
    expect(info.userIds, ['Card Fixture <card@example.org>']);
    expect([info.primary.algorithm, for (final subkey in info.subkeys) subkey.algorithm], ['ed25519', 'cv25519', 'ed25519']);
    expect(
      [info.primary.flags, for (final subkey in info.subkeys) subkey.flags],
      [PgpKeyFlag.certify | PgpKeyFlag.sign, PgpKeyFlag.encryptCommunications | PgpKeyFlag.encryptStorage, PgpKeyFlag.authenticate],
    );
  });
}
