// Signs one file with Kemlock's code and each unprotected SSH key of
// test/fixtures/keys/openssh that the vault keeps (Ed25519, ECDSA P-256 and
// P-384, RSA), and writes `<key>.sig` into a new directory.
// tool/keys/sshsig_check.sh runs it and gives the signatures to
// `ssh-keygen`. Run it from mobile/:
//
//   dart run tool/keys/write_sshsigs.dart <new directory> <file> <namespace>

import 'dart:io';

import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/crypto/keys/pkcs8.dart';
import 'package:kemlock/crypto/keys/sshsig.dart';

const keys = ['ed25519', 'ecdsa256', 'ecdsa384', 'rsa3072'];

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: dart run tool/keys/write_sshsigs.dart <new directory> <file> <namespace>');
    exit(64);
  }
  final out = Directory(args[0]);
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists');
    exit(1);
  }
  out.createSync(recursive: true);
  final message = File(args[1]).readAsBytesSync();
  for (final name in keys) {
    final key = await readPrivateKey(File('test/fixtures/keys/openssh/$name').readAsBytesSync());
    final signature = await sshsigSign(await readPkcs8(key.private), args[2], message);
    File('${out.path}/$name.sig').writeAsStringSync(signature);
    stdout.writeln('$name: ${keyFingerprint(key)!.text}');
  }
}
