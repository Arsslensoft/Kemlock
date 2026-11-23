// Generates a PGP key of each type with Kemlock's code and writes, for
// each, the public key, the secret key exported with a passphrase and the
// unprotected secret key as the vault keeps it, all armored, into a new
// directory. tool/keys/gnupg_check.sh and tool/keys/sequoia_check.sh run
// it and import the files into GnuPG and Sequoia. Run it from mobile/:
//
//   dart run tool/keys/write_pgp_keys.dart <new directory> <passphrase>
//
// The files are named by type: ed25519, rsa4096, pq-standard, pq-gnupg.
// It wrote test/fixtures/keys/kemlock/pgp-pq-standard.* and pgp-pq-gnupg.*
// once, on 2026-11-17.

import 'dart:io';

import 'package:kemlock/crypto/keys/keys.dart';

/// The file name of each type's keys.
String pgpKeyFileName(PgpKeyType type) => switch (type) {
  PgpKeyType.ed25519 => 'ed25519',
  PgpKeyType.rsa4096 => 'rsa4096',
  PgpKeyType.pqStandard => 'pq-standard',
  PgpKeyType.pqGnupg => 'pq-gnupg',
};

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/keys/write_pgp_keys.dart <new directory> <passphrase>');
    exit(64);
  }
  final out = Directory(args[0]);
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists');
    exit(1);
  }
  out.createSync(recursive: true);
  for (final type in PgpKeyType.values) {
    final name = pgpKeyFileName(type);
    final key = await makeKey(PgpKeyRequest(name: 'Ada Lovelace', email: '$name@example.org', type: type));
    File('${out.path}/$name.public.asc').writeAsStringSync(publicKeyPem(key)!);
    File('${out.path}/$name.secret.asc').writeAsStringSync(exportPgpSecretKey(key, passphrase: args[1]));
    File('${out.path}/$name.unprotected.asc').writeAsStringSync(exportPgpSecretKey(key));
    stdout.writeln('$name: ${keyFingerprint(key)!.text}');
  }
}
