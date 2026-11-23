// Writes keys exported by Kemlock's own code into a new directory, for the
// tools that made the fixtures to open: `openssl pkey` reads the encrypted
// PKCS#8. Run it from mobile/:
//
//   dart run tool/keys/write_samples.dart <new directory>
//
// test/fixtures/keys/kemlock holds one run's output, and NOTES.md beside it
// what the tools printed for those files. Like the other fixtures, they are
// never regenerated.

import 'dart:io';

import 'package:kemlock/crypto/keys/keys.dart';

const passphrase = 'fixture passphrase';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/keys/write_samples.dart <new directory>');
    exit(64);
  }
  final out = Directory(args.single);
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists; the samples are never regenerated');
    exit(1);
  }
  out.createSync(recursive: true);
  void write(String name, String text) => File('${out.path}/$name').writeAsStringSync(text);

  final p256 = await readPrivateKey(File('test/fixtures/keys/openssl/p256.pkcs8.pem').readAsStringSync());
  write('p256.pbes2.pem', exportPkcs8Pem(p256, passphrase: passphrase));

  // The ssh-keygen keys, exported in OpenSSH form with a passphrase for
  // `ssh-keygen -y`, and as PKCS#8 for `openssl pkey -check`.
  for (final name in ['ed25519', 'ecdsa256', 'ecdsa384', 'rsa3072']) {
    final key = await readPrivateKey(File('test/fixtures/keys/openssh/$name').readAsBytesSync());
    write('$name.openssh', await exportOpenSsh(key, passphrase: passphrase));
    write('$name.from-openssh.pkcs8.pem', exportPkcs8Pem(key));
  }

  // PGP keys Kemlock generated, for GnuPG: the public key, the secret key
  // exported with the passphrase, and the unprotected secret key as the
  // vault keeps it.
  for (final type in PgpKeyType.values) {
    final key = await makeKey(PgpKeyRequest(name: 'Ada Lovelace', email: 'ada@example.org', type: type));
    write('pgp-${type.name}.public.asc', publicKeyPem(key)!);
    write('pgp-${type.name}.secret.asc', exportPgpSecretKey(key, passphrase: passphrase));
    write('pgp-${type.name}.unprotected.asc', exportPgpSecretKey(key));
  }
}
