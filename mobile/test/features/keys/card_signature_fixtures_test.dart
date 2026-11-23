// Signatures made on the fake OpenPGP card through the whole message flow
// (openspec: add-openpgp-card, task 6.5): a PGP job whose signer is a card
// key, its private step through a card bridge, the fake card's session and
// its key. The fake card holds the secret parts of GnuPG's Ed25519 fixture
// key, so GnuPG checks the outputs against that key's public half; the
// README of test/fixtures/keys/gnupg/card/signed records how.
//
// The fixtures were written once with
//
//   OUT=test/fixtures/keys/gnupg/card/signed flutter test test/features/keys/card_signature_fixtures_test.dart
//
// and are never written again; without OUT the test checks them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/packets.dart';
import 'package:kemlock/crypto/keys/openpgp/writer.dart' show cardStubKey;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/openpgp_card/card_commands.dart';
import 'package:kemlock/security_key/openpgp_card/card_operations.dart';
import 'package:kemlock/security_key/openpgp_card/card_session.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';

const _dir = 'test/fixtures/keys/gnupg/card/signed';
final _secret = File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync();
final _public = File('test/fixtures/keys/gnupg/ed25519.public.gpg').readAsBytesSync();
final _when = DateTime.utc(2026, 11, 17, 12);
const _text = 'Signed on a security key.\nThe second line.\n';
final _file = Uint8List.fromList([for (var i = 0; i < 1000; i++) (i * 31 + 7) & 0xff]);

/// The card's private step as the app's bridge does it, without its sheet:
/// the fake card held to a fake phone, its factory PIN given.
class _FakeCardBridge implements PgpCardBridge {
  _FakeCardBridge(this.card);

  final FakeOpenPgpCard card;

  Future<Uint8List> _on(Future<Uint8List> Function(OpenPgpCardSession session) action) {
    final phone = FakeSecurityKeys();
    phone.arrive(FakeKey(applets: [card]).device(kinds: {SecurityKeyLinkKind.nfc}));
    return runOnKey(phone, (connection) async {
      final session = await OpenPgpCardSession.open(connection);
      session.holdPin(CardPin.pin, Uint8List.fromList(utf8.encode(FakeOpenPgpCard.factoryPin)));
      try {
        return await action(session);
      } finally {
        session.close();
      }
    }, now: phone.now);
  }

  KeyPacket _key(Uint8List packet) => parseKeyPacket(readPackets(packet).single);

  @override
  Future<Uint8List> sign(Uint8List keyPacket, Uint8List digest) => _on((session) => cardSign(session, _key(keyPacket), digest));

  @override
  Future<Uint8List> decipher(Uint8List keyPacket, Uint8List input) => _on((session) => cardDecipher(session, _key(keyPacket), input));
}

/// The fixture key as a card key's job key, and its card.
Future<(PgpJobKey, FakeOpenPgpCard)> _cardKey() async {
  final card = FakeOpenPgpCard();
  await card.loadPgpKey(_secret);
  final info = readTransferableKey(_public).info;
  final stub = cardStubKey(_public, cardAid: card.fullAid, onCard: [info.primary.fingerprint, info.subkeys.single.fingerprint]);
  return (PgpJobKey(stub, onCard: true), card);
}

Future<Uint8List> _signed(PgpRequest request, FakeOpenPgpCard card) async {
  final outcome = await runPgpRequest(request, card: _FakeCardBridge(card));
  if (outcome is! PgpSignedOutcome) fail('not signed: $outcome');
  return outcome.bytes;
}

void main() {
  final out = Platform.environment['OUT'];

  test('writes the signatures made on the fake card to OUT', () async {
    final (key, card) = await _cardKey();
    final dir = Directory(out!)..createSync(recursive: true);
    final file = File('${dir.path}/data.bin')..writeAsBytesSync(_file);

    final message = await _signed(SignRequest(now: _when, text: Uint8List.fromList(utf8.encode(_text)), signer: key), card);
    final signature = await _signed(SignRequest(now: _when, inputPath: file.path, signer: key), card);

    File('${dir.path}/message.asc').writeAsBytesSync(message);
    File('${dir.path}/data.bin.sig').writeAsBytesSync(signature);
    expect(card.signatures, 2);
  }, skip: out == null ? 'Writes the frozen fixtures; set OUT to run' : false);

  test("the fixtures are what the card's flow gives now, and verify", () async {
    if (!File('$_dir/message.asc').existsSync()) return;
    final (key, card) = await _cardKey();

    final message = await _signed(SignRequest(now: _when, text: Uint8List.fromList(utf8.encode(_text)), signer: key), card);

    // Ed25519 signatures are deterministic: the same key, time and text give the same bytes
    expect(message, File('$_dir/message.asc').readAsBytesSync());
    final verified = await pgp.verify(signed: pgp.PgpData.bytes(message), verifiers: [_public], now: _when);
    expect(verified.signatures.single.verdict, pgp.SignatureVerdict.good);
    expect(utf8.decode(verified.content!), startsWith('Signed on a security key.'));
    final detached = await pgp.verify(
      signed: pgp.PgpData.bytes(File('$_dir/data.bin.sig').readAsBytesSync()),
      data: pgp.PgpData.bytes(File('$_dir/data.bin').readAsBytesSync()),
      verifiers: [_public],
      now: _when,
    );
    expect(detached.signatures.single.verdict, pgp.SignatureVerdict.good);
    expect(File('$_dir/data.bin').readAsBytesSync(), _file);
  });
}
