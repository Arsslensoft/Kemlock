// The PGP job in its own isolate: real isolates, under tester.runAsync.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/pgp/pgp_job.dart';

import '../../helpers/test_app.dart';
import 'pgp_kit.dart';

Future<crypto.ParsedKey> _key(String name) => crypto.readPrivateKey(fixtureBytes(fixtureKeys[name]!.$1));

/// Bytes that do not compress or repeat, as a picture's would not.
Uint8List _noise(int length) {
  final out = Uint8List(length);
  var x = 0x2545f491;
  for (var i = 0; i < length; i++) {
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    out[i] = x & 0xff;
  }
  return out;
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('pgp-job-test'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  testWidgets('a text goes round: encrypted in one isolate, decrypted in another', (tester) async {
    await tester.runAsync(() async {
      final ed = await _key('ed');
      final text = Uint8List.fromList(utf8.encode('A message through the job.\n'));
      final encrypted = await startPgpJob(EncryptRequest(now: testNow, text: text, recipients: [ed.public!], signer: PgpJobKey(ed.private)))
          .result;
      final armored = (encrypted as PgpEncryptedOutcome).armored!;
      expect(utf8.decode(armored), startsWith('-----BEGIN PGP MESSAGE-----'));

      final directory = Directory('${temp.path}/out')..createSync();
      final decrypted = await startPgpJob(
        DecryptRequest(
          now: testNow,
          text: armored,
          outputDirectory: directory.path,
          keys: [PgpJobKey(ed.private)],
          verifiers: [ed.public!],
        ),
        directory: directory,
      ).result;
      final message = (decrypted as PgpDecryptedOutcome).message;
      expect(message.bytes, text);
      expect(message.isText, isTrue);
      expect(message.signatures.single.verdict, pgp.SignatureVerdict.good);
      expect(message.signatures.single.made, testNow);
      // A result in memory leaves the directory empty, and there
      expect(directory.listSync(), isEmpty);
    });
  });

  testWidgets('progress runs from 0 to 1 over a 3 MB file', (tester) async {
    await tester.runAsync(() async {
      final ed = await _key('ed');
      final input = File('${temp.path}/photo.bin')..writeAsBytesSync(_noise(3 << 20));
      final directory = Directory('${temp.path}/job')..createSync();
      final job = startPgpJob(
        EncryptRequest(
          now: testNow,
          inputPath: input.path,
          fileName: 'photo.bin',
          outputPath: '${directory.path}/photo.bin.gpg',
          recipients: [ed.public!],
        ),
        directory: directory,
      );
      final seen = <double>[];
      job.progress.addListener(() => seen.add(job.progress.value));
      final outcome = await job.result;
      expect(outcome, isA<PgpEncryptedOutcome>());
      expect((outcome as PgpEncryptedOutcome).armored, isNull);
      expect(seen.first, lessThan(0.1));
      expect(seen.last, 1);
      expect(seen.length, greaterThan(10));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(File('${directory.path}/photo.bin.gpg').lengthSync(), greaterThan(3 << 20));
      expect(input.readAsBytesSync().length, 3 << 20);
    });
  });

  testWidgets('cancel in the middle of a file ends as cancelled and leaves no directory', (tester) async {
    await tester.runAsync(() async {
      final ed = await _key('ed');
      final input = File('${temp.path}/big.bin')..writeAsBytesSync(_noise(24 << 20));
      final directory = Directory('${temp.path}/job')..createSync();
      final job = startPgpJob(
        EncryptRequest(
          now: testNow,
          inputPath: input.path,
          fileName: 'big.bin',
          outputPath: '${directory.path}/big.bin.gpg',
          recipients: [ed.public!],
        ),
        directory: directory,
      );
      // Once it is well into the file
      var cancelledAt = -1.0;
      job.progress.addListener(() {
        if (cancelledAt < 0 && job.progress.value > 0.05) {
          cancelledAt = job.progress.value;
          job.cancel();
        }
      });
      expect(await job.result, isA<PgpCancelledOutcome>());
      expect(cancelledAt, inExclusiveRange(0.05, 0.9));
      expect(directory.existsSync(), isFalse);
      // The file it was reading is whole and can be deleted: nothing holds it
      input.deleteSync();
      job.cancel();
    });
  });

  testWidgets('cancel with no directory to leave a note in kills the isolate', (tester) async {
    await tester.runAsync(() async {
      // An S2K at the top count, a few seconds of work with nothing to ask
      final message = fixtureBytes('pgp/rfc9580/a9-skesk6-eax.asc');
      final job = startPgpJob(DecryptRequest(now: testNow, text: message, outputDirectory: temp.path, passphrase: 'password'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final watch = Stopwatch()..start();
      job.cancel();
      expect(await job.result, isA<PgpCancelledOutcome>());
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  testWidgets('an error inside the isolate arrives as its PgpProblem', (tester) async {
    await tester.runAsync(() async {
      final ed = await _key('ed');
      Future<pgp.PgpException> failure(PgpRequest request, {Directory? directory}) async =>
          ((await startPgpJob(request, directory: directory).result) as PgpFailedOutcome).error;

      final notAMessage = await failure(
        DecryptRequest(now: testNow, text: Uint8List.fromList(utf8.encode('hello')), outputDirectory: temp.path),
      );
      expect(notAMessage.problem, pgp.PgpProblem.notAMessage);

      final directory = Directory('${temp.path}/failed')..createSync();
      final noKey = await failure(
        DecryptRequest(
          now: testNow,
          text: fixtureBytes('pgp/gnupg/to-rsa3072.seipd.gpg'),
          outputDirectory: directory.path,
          keys: [PgpJobKey(ed.private)],
        ),
        directory: directory,
      );
      expect(noKey.problem, pgp.PgpProblem.noKeyOpensIt);
      expect(noKey.keyIds, ['B8A3CCC781F74F29']);
      // A job that fails takes its directory with it
      expect(directory.existsSync(), isFalse);

      final unsupported = await failure(
        DecryptRequest(now: testNow, text: fixtureBytes('pgp/gnupg/sym-cast5.gpg'), outputDirectory: temp.path, passphrase: 'x'),
      );
      expect((unsupported.problem, unsupported.detail), (pgp.PgpProblem.unsupported, 'CAST5'));

      final locked = await _key('ed-protected');
      final wrong = await failure(
        SignRequest(
          now: testNow,
          text: Uint8List.fromList(utf8.encode('x')),
          signer: PgpJobKey(locked.private, passphrase: 'no'),
        ),
      );
      expect((wrong.problem, wrong.fingerprint), (pgp.PgpProblem.wrongPassphrase, '1BB5EC3961E61EE44F919AB63FCD57EBA0308CA9'));
    });
  });

  testWidgets('sign and verify go through the job too', (tester) async {
    await tester.runAsync(() async {
      final rsa = await _key('rsa');
      final input = File('${temp.path}/report.pdf')..writeAsBytesSync(_noise(100000));
      final signed = await startPgpJob(SignRequest(now: testNow, inputPath: input.path, signer: PgpJobKey(rsa.private))).result;
      final signature = (signed as PgpSignedOutcome).bytes;
      final verified = await startPgpJob(VerifyRequest(now: testNow, inputPath: input.path, signature: signature, verifiers: [rsa.public!]))
          .result;
      expect((verified as PgpVerifiedOutcome).verified.signatures.single.verdict, pgp.SignatureVerdict.good);

      final clear = await startPgpJob(
        SignRequest(now: testNow, text: Uint8List.fromList(utf8.encode('hello')), signer: PgpJobKey(rsa.private)),
      ).result;
      final text = (clear as PgpSignedOutcome).bytes;
      expect(utf8.decode(text), startsWith('-----BEGIN PGP SIGNED MESSAGE-----'));
      final checked = await startPgpJob(VerifyRequest(now: testNow, text: text, verifiers: [rsa.public!])).result;
      expect(utf8.decode((checked as PgpVerifiedOutcome).verified.content!), 'hello');
    });
  });
}
