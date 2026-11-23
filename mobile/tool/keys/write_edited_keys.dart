// Changes the PGP keys of test/fixtures/keys/gnupg/editing and
// other/editing with Kemlock's code, each kind of change on its own, and
// writes the results armored into a new directory, for GnuPG and Sequoia
// to import (openspec: add-pgp-key-editing, task 3.6). tool/keys/gnupg_check.sh
// runs it. Run it from mobile/:
//
//   dart run tool/keys/write_edited_keys.dart <new directory>
//
// For each key <k> it writes <k>.<change>.public.asc and .secret.asc, and
// <k>.original.public.asc with <k>.rev.asc, a revocation certificate made
// here, to import into a GnuPG that has only the original public key. The
// secret keys keep the protection they came with: the protected key's,
// `fixture passphrase`, covers its new subkey too.

import 'dart:io';

import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/crypto/keys/openpgp/armor.dart';

const passphrase = 'fixture passphrase';

const keys = {
  'signing-subkey': 'gnupg/editing/signing-subkey.secret.asc',
  'rsa3072-expiring': 'gnupg/editing/rsa3072-expiring.secret.asc',
  'protected': 'gnupg/editing/protected.secret.asc',
  'direct-key': 'other/editing/direct-key.secret.asc',
};

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/keys/write_edited_keys.dart <new directory>');
    exit(64);
  }
  final out = Directory(args.single);
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists');
    exit(1);
  }
  out.createSync(recursive: true);
  final now = DateTime.now().toUtc();
  final inTwoYears = DateTime.utc(now.year + 2, now.month, now.day, 12);
  final inOneYear = DateTime.utc(now.year + 1, now.month, now.day, 12);

  for (final MapEntry(key: name, value: path) in keys.entries) {
    final original = readArmorBlock(File('test/fixtures/keys/$path').readAsBytesSync());
    final secret = name == 'protected' ? passphrase : null;
    final parsed = await readPrivateKey(original);
    final subkey = parsed.pgp!.subkeys.first.fingerprint;

    final changes = <String, PgpChange>{
      'expiry': SetPgpExpiry(inTwoYears, alsoSubkeys: true),
      'never': const SetPgpExpiry(null, alsoSubkeys: true),
      'subkey-expiry': SetPgpExpiry(inOneYear, subkey: subkey),
      'uid': const AddPgpUserId(name: 'Fixture Added', email: 'added@example.org', makePrimary: true),
      'encrypt': AddPgpSubkey(type: PgpKeyType.ed25519, use: PgpSubkeyUse.encrypt, expires: inOneYear),
      'sign': const AddPgpSubkey(type: PgpKeyType.ed25519, use: PgpSubkeyUse.sign),
      if (name == 'rsa3072-expiring') 'rsa-sign': const AddPgpSubkey(type: PgpKeyType.rsa4096, use: PgpSubkeyUse.sign),
      'revoked': const RevokePgpKey(reason: PgpRevocationReason.compromised, note: 'Left on a train'),
    };
    void write(String file, String text) => File('${out.path}/$file').writeAsStringSync(text);
    for (final MapEntry(key: change, value: request) in changes.entries) {
      final changed = await makeKey(PgpChangeRequest(original, request, passphrase: secret, now: now));
      write('$name.$change.public.asc', publicKeyPem(changed)!);
      write('$name.$change.secret.asc', writeArmor(pgpPrivateKeyBlock, changed.private));
    }
    write('$name.original.public.asc', publicKeyPem(parsed)!);
    write(
      '$name.rev.asc',
      await revocationCertificate(original, passphrase: secret, reason: PgpRevocationReason.retired, note: 'Kept in a drawer', now: now),
    );
    stdout.writeln('$name: ${keyFingerprint(parsed)!.text}');
  }
}
