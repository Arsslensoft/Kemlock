// Times the PGP message code, for the figures in decision 13 of
// openspec/changes/add-pgp-messages/design.md: encrypting and decrypting a
// 100 MB file (SEIPD version 1, the form Kemlock writes), OCB over the
// same amount in 4 MiB chunks (the form GnuPG sends to its own keys), an
// RSA 4096 private operation, and Iterated and Salted S2K at GnuPG's
// count octet (229) and at the top one (255). It also prints the
// process's peak memory, which must not grow with the file.
//
// Run it from mobile/, as the Dart VM runs it or compiled ahead of time
// as a release build is:
//
//   dart run tool/pgp/benchmark.dart [megabytes]
//   dart compile exe tool/pgp/benchmark.dart -o /tmp/pgp-benchmark && /tmp/pgp-benchmark [megabytes]

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kemlock/crypto/keys/keys.dart' as keys;
import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/crypto/keys/openpgp/modes.dart';
import 'package:kemlock/crypto/keys/openpgp/s2k.dart';
import 'package:kemlock/crypto/keys/pgp.dart';

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';

Future<void> main(List<String> args) async {
  final megabytes = args.isEmpty ? 100 : int.parse(args.first);
  final size = megabytes * 1024 * 1024;
  stdout.writeln('${Platform.operatingSystemVersion}, Dart ${Platform.version.split(' ').first}');

  Future<T> time<T>(String name, Future<T> Function() body, {int? bytes}) async {
    final watch = Stopwatch()..start();
    final result = await body();
    final ms = watch.elapsedMilliseconds;
    final rate = bytes == null || ms == 0 ? '' : ', ${(bytes / (1024 * 1024) / (ms / 1000)).toStringAsFixed(1)} MB/s';
    stdout.writeln('$name: $ms ms$rate; peak memory ${_mb(ProcessInfo.maxRss)}');
    return result;
  }

  final directory = Directory.systemTemp.createTempSync('pgp-benchmark');
  try {
    // A file that does not compress, written a megabyte at a time
    final input = File('${directory.path}/input.bin');
    final sink = input.openSync(mode: FileMode.writeOnly);
    final block = Uint8List(1024 * 1024);
    var x = 0x4b454d4c;
    for (var written = 0; written < size; written += block.length) {
      for (var i = 0; i < block.length; i++) {
        x ^= (x << 13) & 0xffffffff;
        x ^= x >> 17;
        x ^= (x << 5) & 0xffffffff;
        block[i] = x & 0xff;
      }
      sink.writeFromSync(block);
    }
    sink.closeSync();
    stdout.writeln('input: $megabytes MB; memory before any work ${_mb(ProcessInfo.currentRss)}');

    final ed = readArmorBlock(File('test/fixtures/keys/gnupg/ed25519.secret.asc').readAsBytesSync());
    final edPublic = File('test/fixtures/keys/gnupg/ed25519.public.gpg').readAsBytesSync();
    final rsa4096 = readArmorBlock(File('test/fixtures/keys/kemlock/pgp-rsa4096.unprotected.asc').readAsBytesSync());
    final rsaPublic = (await readPgpPublicKey(rsa4096)).transferableKey;

    final encrypted = '${directory.path}/input.bin.gpg';
    await time(
      'encrypt $megabytes MB to a Curve25519 key, signed (CFB, SHA-1 check, SHA-512 signature)',
      () => encrypt(
        data: PgpData.file(input.path),
        recipients: [edPublic],
        signer: PgpSecretKey(ed),
        text: false,
        fileName: 'input.bin',
        outputPath: encrypted,
      ),
      bytes: size,
    );
    final out = Directory('${directory.path}/out')..createSync();
    await time(
      'decrypt it and check the signature',
      () => decrypt(data: PgpData.file(encrypted), keys: [PgpSecretKey(ed)], verifiers: [edPublic], outputDirectory: out.path),
      bytes: size,
    );

    // OCB as GnuPG's packet has it: 4 MiB chunks under one key
    await time('OCB, sealing and opening $megabytes MB in 4 MiB chunks', () async {
      final ocb = Ocb(Uint8List.fromList(List.generate(32, (i) => i)));
      final chunk = Uint8List(4 * 1024 * 1024);
      final ad = Uint8List.fromList([0xd4, 1, 9, 2, 16]);
      for (var done = 0, index = 0; done < size; done += chunk.length, index++) {
        final nonce = Uint8List(15)..buffer.asByteData().setUint32(11, index);
        final sealed = ocb.seal(nonce, chunk, ad);
        if (ocb.open(nonce, sealed, ad) == null) throw StateError('OCB does not open what it sealed');
      }
    }, bytes: 2 * size);

    // One RSA 4096 private operation, which decrypting a message to such a key takes
    final small = (await encrypt(data: PgpData.bytes(Uint8List.fromList(utf8.encode('to an RSA 4096 key'))), recipients: [rsaPublic], text: true))!;
    await time('decrypt a short message to an RSA 4096 key', () => decrypt(data: PgpData.bytes(small), keys: [PgpSecretKey(rsa4096)]));
    await time('sign a short message with the RSA 4096 key', () async {
      await sign(data: PgpData.bytes(Uint8List(100)), signer: PgpSecretKey(rsa4096), form: PgpSignatureForm.detached);
    });
    await time('read and check a key (Ed25519 self-signatures)', () => readPgpPublicKey(edPublic));
    await time('generate nothing: read the RSA 4096 key and check its self-signatures', () => keys.verifyPgpSelfSignatures(rsa4096));

    final passphrase = utf8.encode('benchmark passphrase');
    for (final (count, hash) in [(229, hashSha512), (255, hashSha256), (0xf0, hashSha256)]) {
      await time(
        'S2K, count octet $count (${(16 + (count & 15)) << ((count >> 4) + 6)} bytes of ${hashName(hash)})',
        () async => S2k.iterated(hash, Uint8List(8), count).derive(passphrase, 32),
      );
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}
