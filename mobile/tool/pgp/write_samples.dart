// Writes the messages and signatures Kemlock makes for fixed inputs,
// fixed randomness and a fixed time (test/crypto/pgp/samples.dart) into a
// new directory, with a `manifest.txt` that says what each is, for
// tool/pgp/gnupg_check.sh to give to GnuPG. Run it from mobile/:
//
//   dart run tool/pgp/write_samples.dart <new directory>
//
// test/fixtures/pgp/kemlock holds one run's output, made on 2026-11-16,
// and `test/crypto/pgp/encrypt_test.dart` checks the writers still give
// those bytes. Like the other fixtures, they are never regenerated: a
// change in what Kemlock writes must show as a failing test.

import 'dart:io';

import '../../test/crypto/pgp/samples.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/pgp/write_samples.dart <new directory>');
    exit(64);
  }
  final out = Directory(args.single);
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists; the samples are never regenerated');
    exit(1);
  }
  out.createSync(recursive: true);
  final manifest = StringBuffer();
  for (final sample in await kemlockSamples()) {
    File('${out.path}/${sample.file}').writeAsBytesSync(await sample.make());
    final signers = sample.signers.isEmpty ? '-' : sample.signers.join(',');
    manifest.writeln('${sample.file} ${sample.kind.name} ${sample.plain} $signers');
    stdout.writeln(sample.file);
  }
  File('${out.path}/manifest.txt').writeAsStringSync(manifest.toString());
}
