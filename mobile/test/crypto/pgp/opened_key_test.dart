import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pgp.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';

/// A test key of test/fixtures/keys/gnupg, binary.
Uint8List _key(String name) => File('test/fixtures/keys/gnupg/$name.gpg').readAsBytesSync();

const _passphrase = 'fixture passphrase';
final _now = DateTime.utc(2026, 11, 17, 9);

/// A protected key opened once and handed to a job with no passphrase
/// (openspec: add-pgp-mail-provider, task 1.2 and decision 13).
void main() {
  for (final name in ['ed25519-protected', 'rsa3072-protected']) {
    group(name, () {
      late Uint8List secret;
      late Uint8List public;
      late Uint8List opened;

      setUpAll(() async {
        secret = _key('$name.secret');
        public = _key('$name.public');
        opened = await openPgpSecretKey(secret, _passphrase);
      });

      test('holds no protected secret and the same public key', () {
        final info = crypto.readPgpKeyInfo(opened);
        expect(crypto.readPgpKeyInfo(secret).protected, isTrue);
        expect(info.protected, isFalse);
        expect(info.isSecret, isTrue);
        expect(info.primary.fingerprintHex, crypto.readPgpKeyInfo(public).primary.fingerprintHex);
        expect(info.subkeys.map((k) => k.fingerprintHex), crypto.readPgpKeyInfo(public).subkeys.map((k) => k.fingerprintHex));
      });

      test('signs in a job with no passphrase, and the signature verifies', () async {
        final text = Uint8List.fromList(utf8.encode('Signed with the opened key.\n'));
        final signed = await runPgpRequest(SignRequest(now: _now, text: text, signer: PgpJobKey(opened)));
        expect(signed, isA<PgpSignedOutcome>());
        final verified = await verify(signed: PgpData.bytes((signed as PgpSignedOutcome).bytes), verifiers: [public], now: _now);
        expect(verified.signatures.single.verdict, SignatureVerdict.good);
      });

      test('decrypts in a job with no passphrase', () async {
        final text = Uint8List.fromList(utf8.encode('For the opened key.\n'));
        final encrypted = await encrypt(data: PgpData.bytes(text), recipients: [public], text: true, now: _now);
        final outcome = await runPgpRequest(
          DecryptRequest(now: _now, text: encrypted, outputDirectory: Directory.systemTemp.path, keys: [PgpJobKey(opened)]),
        );
        expect(outcome, isA<PgpDecryptedOutcome>());
        expect((outcome as PgpDecryptedOutcome).message.bytes, text);
      });

      test('the stored key still asks for its passphrase', () async {
        final text = Uint8List.fromList(utf8.encode('x'));
        final outcome = await runPgpRequest(SignRequest(now: _now, text: text, signer: PgpJobKey(secret)));
        expect((outcome as PgpFailedOutcome).error.problem, PgpProblem.passphraseNeeded);
      });

      test('a wrong passphrase opens nothing', () async {
        await expectLater(
          openPgpSecretKey(secret, 'not the passphrase'),
          throwsA(isA<PgpException>().having((e) => e.problem, 'problem', PgpProblem.wrongPassphrase)),
        );
      });
    });
  }

  test('an unprotected key comes back as it was', () async {
    final secret = _key('ed25519.secret');
    expect(await openPgpSecretKey(secret, _passphrase), secret);
  });

  test('a public key is no secret key', () async {
    await expectLater(
      openPgpSecretKey(_key('ed25519.public'), _passphrase),
      throwsA(isA<PgpException>().having((e) => e.problem, 'problem', PgpProblem.notAMessage)),
    );
  });

  // Joined with add-post-quantum-pgp: a mail app may use a post-quantum key
  for (final path in [
    'kemlock/pgp-pq-standard.secret.asc',
    'kemlock/pgp-pq-gnupg.secret.asc',
    'gnupg/pqc/ky768-cv25519-protected.secret.asc',
  ]) {
    test('$path opens, and decrypts in a job with no passphrase', () async {
      final parsed = await crypto.readPrivateKey(File('test/fixtures/keys/$path').readAsStringSync());
      final opened = await openPgpSecretKey(Uint8List.fromList(parsed.private), _passphrase);
      final info = crypto.readPgpKeyInfo(opened);
      expect((parsed.pgp!.protected, info.protected), (true, false));
      expect(info.subkeys.single.fingerprintHex, parsed.pgp!.subkeys.single.fingerprintHex);
      final text = Uint8List.fromList(utf8.encode('For the opened post-quantum key.\n'));
      final encrypted = await encrypt(data: PgpData.bytes(text), recipients: [parsed.public!], text: true, now: _now);
      final outcome = await runPgpRequest(
        DecryptRequest(now: _now, text: encrypted, outputDirectory: Directory.systemTemp.path, keys: [PgpJobKey(opened)]),
      );
      expect((outcome as PgpDecryptedOutcome).message.bytes, text);
      if (path.contains('standard')) {
        final signed = await runPgpRequest(SignRequest(now: _now, text: text, signer: PgpJobKey(opened)));
        final verified = await verify(signed: PgpData.bytes((signed as PgpSignedOutcome).bytes), verifiers: [parsed.public!], now: _now);
        expect(verified.signatures.single.verdict, SignatureVerdict.good);
      }
    });
  }
}
