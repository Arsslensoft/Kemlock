import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/pgp/pgp_job.dart';

Uint8List _key(String name) => File('test/fixtures/keys/gnupg/$name.gpg').readAsBytesSync();
Uint8List _mail(String name) => File('test/fixtures/mail/$name').readAsBytesSync();
final _now = DateTime.utc(2026, 11, 17, 9);

/// What the mail provider asks of a job that the PGP sheets do not: bytes
/// in and out in either form, and nothing written to storage (openspec:
/// add-pgp-mail-provider, decision 10).
void main() {
  final body = _mail('body.eml');

  test('encrypts bytes to binary when asked', () async {
    final outcome = await runPgpRequest(EncryptRequest(now: _now, text: body, recipients: [_key('ed25519.public')], binary: true));
    final bytes = (outcome as PgpEncryptedOutcome).armored!;
    expect(bytes.first & 0x80, 0x80, reason: 'a packet, not armor');
    final decrypted = await pgp.decrypt(data: pgp.PgpData.bytes(bytes), keys: [pgp.PgpSecretKey(_key('ed25519.secret'))], now: _now);
    expect(decrypted.bytes, body);
  });

  test('encrypts bytes to armor by default, as before', () async {
    final outcome = await runPgpRequest(EncryptRequest(now: _now, text: body, recipients: [_key('ed25519.public')]));
    expect(String.fromCharCodes((outcome as PgpEncryptedOutcome).armored!.take(27)), '-----BEGIN PGP MESSAGE-----');
  });

  for (final form in [pgp.PgpSignatureForm.detached, pgp.PgpSignatureForm.detachedArmored]) {
    test('signs bytes with a detached signature, ${form.name}', () async {
      final outcome = await runPgpRequest(SignRequest(now: _now, text: body, signer: PgpJobKey(_key('ed25519.secret')), form: form));
      final signature = (outcome as PgpSignedOutcome).bytes;
      expect(String.fromCharCodes(signature.take(5)) == '-----', form == pgp.PgpSignatureForm.detachedArmored);
      final verified = await pgp.verify(
        signed: pgp.PgpData.bytes(signature),
        data: pgp.PgpData.bytes(body),
        verifiers: [_key('ed25519.public')],
        now: _now,
      );
      expect(verified.signatures.single.verdict, pgp.SignatureVerdict.good);
      expect(pgp.pgpMicalg(signature), 'pgp-sha512');
    });
  }

  test("names GnuPG's hash for micalg, and refuses what is no signature", () {
    expect(pgp.pgpMicalg(_mail('body.eml.sig.asc')), 'pgp-sha512');
    expect(() => pgp.pgpMicalg(body), throwsA(isA<pgp.PgpException>()));
  });

  test('decrypts in memory with no directory, up to its bound', () async {
    final big = Uint8List(4096);
    final encrypted = await pgp.encrypt(data: pgp.PgpData.bytes(big), recipients: [_key('ed25519.public')], text: false, now: _now);
    final fits = await runPgpRequest(
      DecryptRequest(now: _now, text: encrypted, outputDirectory: null, maxInMemory: 4096, keys: [PgpJobKey(_key('ed25519.secret'))]),
    );
    expect((fits as PgpDecryptedOutcome).message.bytes, big);
    final over = await runPgpRequest(
      DecryptRequest(now: _now, text: encrypted, outputDirectory: null, maxInMemory: 4095, keys: [PgpJobKey(_key('ed25519.secret'))]),
    );
    expect((over as PgpFailedOutcome).error.problem, pgp.PgpProblem.tooLarge);
  });

  test('armors a public key that reads back as the same key', () async {
    final armored = pgp.armoredPgpPublicKey(_key('ed25519.public'));
    expect(armored, startsWith('-----BEGIN PGP PUBLIC KEY BLOCK-----'));
    expect((await pgp.readPgpPublicKey(armored)).fingerprintHex, '1FCDA135EE42400EC2B77CE677249ABE661CF8DB');
  });
}
