// Times key generation and the passphrase-protected exports, for the
// figures in openspec/changes/add-vault-items/design.md, and the
// post-quantum PGP keys of add-post-quantum-pgp (task 6.5): making each,
// and encrypting, decrypting and signing a 50 MB file with a standard key
// (SEIPD version 2, OCB) and a GnuPG-format Kyber key (SEIPD version 1).
// Run it from mobile/, as the Dart VM runs it or compiled ahead of time as
// a release build is:
//
//   dart run tool/keys/benchmark.dart [runs]
//   dart compile exe tool/keys/benchmark.dart -o /tmp/benchmark && /tmp/benchmark [runs]

import 'dart:io';

import 'dart:typed_data';

import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;

Future<void> main(List<String> args) async {
  final runs = args.isEmpty ? 10 : int.parse(args.first);
  stdout.writeln('${Platform.operatingSystemVersion}, Dart ${Platform.version.split(' ').first}, $runs runs each');

  Future<void> time(String name, Future<void> Function() body) async {
    final times = <int>[];
    for (var i = 0; i < runs; i++) {
      final watch = Stopwatch()..start();
      await body();
      times.add(watch.elapsedMilliseconds);
    }
    times.sort();
    stdout.writeln('$name: median ${times[times.length ~/ 2]} ms, min ${times.first} ms, max ${times.last} ms');
  }

  for (final kind in [KeyKind.signing, KeyKind.exchange]) {
    for (final algorithm in generatedAlgorithms[kind]!) {
      await time('generate ${algorithm.name}', () => makeKey(NewKeyRequest(kind, algorithm)));
    }
  }
  final ssh = await makeKey(const NewKeyRequest(KeyKind.ssh, GeneratedAlgorithm.ed25519));
  await time('OpenSSH export with a passphrase (bcrypt, 16 rounds)', () => exportOpenSsh(ssh, passphrase: 'benchmark'));
  await time('PKCS#8 export with a passphrase (PBKDF2, 600,000 rounds)', () async => exportPkcs8Pem(ssh, passphrase: 'benchmark'));

  // Post-quantum PGP keys
  final made = <PgpKeyType, ParsedKey>{};
  for (final type in [PgpKeyType.pqStandard, PgpKeyType.pqGnupg]) {
    await time('generate PGP ${type.name}', () async {
      made[type] = await makeKey(PgpKeyRequest(name: 'Bench', email: 'bench@example.org', type: type));
    });
  }
  final dir = Directory.systemTemp.createTempSync('kemlock-bench');
  try {
    final input = '${dir.path}/input.bin';
    final data = Uint8List(50 * 1024 * 1024);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 2654435761) >> 24;
    }
    File(input).writeAsBytesSync(data);
    Directory('${dir.path}/out').createSync();
    for (final MapEntry(key: type, value: key) in made.entries) {
      final output = '${dir.path}/${type.name}.gpg';
      Future<void> once(String name, Future<void> Function() body) async {
        final watch = Stopwatch()..start();
        await body();
        stdout.writeln('$name: ${watch.elapsedMilliseconds} ms');
      }

      await once('encrypt 50 MB to ${type.name}, signed by it', () async {
        await pgp.encrypt(
          data: pgp.PgpData.file(input),
          recipients: [key.public!],
          signer: pgp.PgpSecretKey(key.private),
          text: false,
          fileName: 'input.bin',
          outputPath: output,
        );
      });
      await once('decrypt it and check the signature', () async {
        final result = await pgp.decrypt(
          data: pgp.PgpData.file(output),
          keys: [pgp.PgpSecretKey(key.private)],
          verifiers: [key.public!],
          // Not beside the input, which has the name the message carries
          outputDirectory: Directory('${dir.path}/out').path,
        );
        if (result.signatures.single.verdict != pgp.SignatureVerdict.good) throw StateError('signature not good');
        File(result.path!).deleteSync();
      });
      await once('sign 50 MB with ${type.name}, detached', () async {
        await pgp.sign(data: pgp.PgpData.file(input), signer: pgp.PgpSecretKey(key.private), form: pgp.PgpSignatureForm.detached);
      });
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}
