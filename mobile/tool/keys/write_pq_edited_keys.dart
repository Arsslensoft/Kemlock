// Changes the post-quantum PGP keys of test/fixtures/keys/kemlock with
// Kemlock's code, each kind of change on its own, and adds post-quantum
// subkeys to the Ed25519 key, writing the results armored into a new
// directory for tool/keys/pq_edit_check.sh to give Sequoia and GnuPG
// (openspec: add-post-quantum-pgp, tasks 9.1 and 9.2). Run it from
// mobile/:
//
//   dart run tool/keys/write_pq_edited_keys.dart <new directory>
//
// It writes, each as <name>.public.asc and <name>.secret.asc:
//
// - standard.original, and standard.expiry, standard.uid, standard.encrypt
//   and standard.sign: the standard key with a new expiry for it and its
//   subkey, a second user ID, and a new version 6 subkey of its own kind
//   to encrypt and to sign; standard.rev.asc, a revocation certificate
//   made here, and standard.revoked;
// - ed25519.pq-standard and ed25519.pq-gnupg: the Ed25519 key with an
//   ML-KEM-768+X25519 subkey, and with a Kyber-768 with X25519 subkey.
//
// The secret keys are unprotected but for ed25519.pq-gnupg, which keeps
// the Ed25519 key's passphrase, `fixture passphrase`, on its new subkey
// too.

import 'dart:io';
import 'dart:typed_data';

import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/crypto/keys/openpgp/armor.dart';

const passphrase = 'fixture passphrase';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/keys/write_pq_edited_keys.dart <new directory>');
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
  Uint8List fixture(String name) => readArmorBlock(File('test/fixtures/keys/kemlock/$name').readAsBytesSync());

  Future<void> write(String name, Uint8List secret) async {
    final parsed = await readPrivateKey(secret);
    File('${out.path}/$name.secret.asc').writeAsStringSync(writeArmor(pgpPrivateKeyBlock, secret));
    File('${out.path}/$name.public.asc').writeAsStringSync(writeArmor(pgpPublicKeyBlock, parsed.public!));
    stdout.writeln('$name: ${parsed.pgp!.subkeys.map((k) => k.algorithm).join(', ')}');
  }

  Future<Uint8List> change(Uint8List key, PgpChange change, {String? passphrase}) async =>
      (await makeKey(PgpChangeRequest(key, change, passphrase: passphrase, now: now))).private;

  final standard = fixture('pgp-pq-standard.unprotected.asc');
  await write('standard.original', standard);
  await write('standard.expiry', await change(standard, SetPgpExpiry(inTwoYears, alsoSubkeys: true)));
  await write('standard.uid', await change(standard, const AddPgpUserId(name: 'Ada Added', email: 'added@example.org')));
  await write('standard.encrypt', await change(standard, const AddPgpSubkey(type: PgpKeyType.pqStandard, use: PgpSubkeyUse.encrypt)));
  await write('standard.sign', await change(standard, const AddPgpSubkey(type: PgpKeyType.pqStandard, use: PgpSubkeyUse.sign)));
  final certificate = await revocationCertificate(standard, reason: PgpRevocationReason.superseded, now: now);
  File('${out.path}/standard.rev.asc').writeAsStringSync(certificate);
  await write(
    'standard.revoked',
    await change(standard, const RevokePgpKey(reason: PgpRevocationReason.compromised, note: 'Left on a train')),
  );

  await write(
    'ed25519.pq-standard',
    await change(fixture('pgp-ed25519.unprotected.asc'), const AddPgpSubkey(type: PgpKeyType.pqStandard, use: PgpSubkeyUse.encrypt)),
  );
  await write(
    'ed25519.pq-gnupg',
    await change(
      fixture('pgp-ed25519.secret.asc'),
      const AddPgpSubkey(type: PgpKeyType.pqGnupg, use: PgpSubkeyUse.encrypt),
      passphrase: passphrase,
    ),
  );
}
