// The job controller: one job, the inactivity lock held off for its
// length, and everything stopped and forgotten when the vault locks.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as openpgp;
import 'package:kemlock/features/pgp/pgp_controller.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/test_app.dart';
import 'pgp_kit.dart';

PgpRequest _request() => VerifyRequest(now: testNow, text: Uint8List.fromList(utf8.encode('x')));

void main() {
  Future<PgpApp> start(WidgetTester tester) async {
    final pgp = PgpApp(tester)..hold = true;
    await pgp.start(keys: ['ed']);
    return pgp;
  }

  testWidgets('the inactivity lock is held while a job runs, and let go when it succeeds', (tester) async {
    final pgp = await start(tester);
    final holds = pgp.app.container.read(autoLockHoldsProvider);
    expect(holds.isHeld, isFalse);
    expect(pgp.app.container.read(pgpJobControllerProvider), isNull);

    final running = pgp.jobs.run(_request());
    await tester.pump();
    expect(holds.isHeld, isTrue);
    expect(pgp.jobs.isRunning, isTrue);
    final status = pgp.app.container.read(pgpJobControllerProvider)!;
    expect((status.progress, status.onFile), (0, false));

    pgp.held.single.progressValue.value = 0.5;
    expect(pgp.app.container.read(pgpJobControllerProvider)!.progress, 0.5);

    pgp.held.single.finish(PgpSignedOutcome(Uint8List(0)));
    expect(await done(pgp, running), isA<PgpSignedOutcome>());
    expect(holds.isHeld, isFalse);
    expect(pgp.jobs.isRunning, isFalse);
    expect(pgp.app.container.read(pgpJobControllerProvider), isNull);
  });

  testWidgets('the hold is let go on an error and on cancel', (tester) async {
    final pgp = await start(tester);
    final holds = pgp.app.container.read(autoLockHoldsProvider);

    final failing = pgp.jobs.run(_request());
    await tester.pump();
    pgp.held[0].finish(const PgpFailedOutcome(openpgp.PgpException(openpgp.PgpProblem.damaged)));
    expect(await done(pgp, failing), isA<PgpFailedOutcome>());
    expect(holds.isHeld, isFalse);

    final cancelled = pgp.jobs.run(_request());
    await tester.pump();
    expect(holds.isHeld, isTrue);
    pgp.jobs.cancel();
    expect(await done(pgp, cancelled), isA<PgpCancelledOutcome>());
    expect(pgp.held[1].cancelled, isTrue);
    expect(holds.isHeld, isFalse);
  });

  testWidgets('one job at a time', (tester) async {
    final pgp = await start(tester);
    final first = pgp.jobs.run(_request());
    await tester.pump();
    await expectLater(pgp.jobs.run(_request()), throwsStateError);
    pgp.jobs.cancel();
    await done(pgp, first);
  });

  testWidgets('a job that fails or is cancelled loses its directory; one that succeeds keeps it until discard', (tester) async {
    final pgp = await start(tester);
    Future<Directory> made() async => (await tester.runAsync(pgp.jobs.newDirectory))!;

    final kept = await made();
    final succeeding = pgp.jobs.run(_request(), directory: kept);
    await tester.pump();
    pgp.held.last.finish(const PgpEncryptedOutcome(null));
    await done(pgp, succeeding);
    expect(kept.existsSync(), isTrue);

    final lost = await made();
    final failing = pgp.jobs.run(_request(), directory: lost);
    await tester.pump();
    pgp.held.last.finish(const PgpFailedOutcome(openpgp.PgpException(openpgp.PgpProblem.outOfSpace)));
    await done(pgp, failing);
    expect(lost.existsSync(), isFalse);

    await tester.runAsync(pgp.jobs.discard);
    expect(kept.existsSync(), isFalse);
    expect(pgp.tempEntries, isEmpty);
  });

  testWidgets('a picked copy is deleted when its job succeeds, kept when it fails, and gone at discard', (tester) async {
    final pgp = await start(tester);
    File copy(String name) => File('${pgp.tempRoot.path}/$name')..writeAsStringSync('picked');

    final finished = copy('done.gpg');
    pgp.jobs.adopt(finished.path);
    final succeeding = pgp.jobs.run(_request(), pickedCopy: finished.path);
    await tester.pump();
    pgp.held.last.finish(const PgpEncryptedOutcome(null));
    await done(pgp, succeeding);
    expect(finished.existsSync(), isFalse);

    // A wrong passphrase: the file is tried again
    final retried = copy('retried.gpg');
    pgp.jobs.adopt(retried.path);
    final failing = pgp.jobs.run(_request(), pickedCopy: retried.path);
    await tester.pump();
    pgp.held.last.finish(const PgpFailedOutcome(openpgp.PgpException(openpgp.PgpProblem.wrongPassphrase)));
    await done(pgp, failing);
    expect(retried.existsSync(), isTrue);

    await tester.runAsync(pgp.jobs.discard);
    expect(retried.existsSync(), isFalse);
  });

  testWidgets('lock during a job cancels it and empties the controller', (tester) async {
    final pgp = await start(tester);
    final holds = pgp.app.container.read(autoLockHoldsProvider);
    final directory = (await tester.runAsync(pgp.jobs.newDirectory))!;
    final picked = File('${pgp.tempRoot.path}/picked.txt')..writeAsStringSync('plain text, about to be encrypted');
    pgp.jobs.adopt(picked.path);
    pgp.app.container.read(pgpLastSignerProvider.notifier).choose('pgp-ed');
    expect(pgp.app.container.read(pgpLastSignerProvider), 'pgp-ed');

    final running = pgp.jobs.run(_request(), directory: directory, pickedCopy: picked.path);
    await tester.pump();
    expect(holds.isHeld, isTrue);

    pgp.app.container.read(vaultControllerProvider.notifier).lock();
    await done(pgp, running);
    await pgp.settle(2);
    expect(await running, isA<PgpCancelledOutcome>());
    expect(pgp.held.single.cancelled, isTrue);
    expect(holds.isHeld, isFalse);

    // Nothing left: no job, no file, no key id
    expect(pgp.jobs.isRunning, isFalse);
    expect(pgp.app.container.read(pgpJobControllerProvider), isNull);
    expect(pgp.app.container.read(pgpLastSignerProvider), isNull);
    expect(directory.existsSync(), isFalse);
    expect(picked.existsSync(), isFalse);
    expect(pgp.tempEntries, isEmpty);
  });
}

/// Waits for [future], a job the controller runs: its ending touches real
/// files, so real time and the test's own clock are let pass in turn.
Future<PgpOutcome> done(PgpApp pgp, Future<PgpOutcome> future) async {
  PgpOutcome? outcome;
  unawaited(future.then((value) => outcome = value));
  for (var i = 0; i < 40 && outcome == null; i++) {
    await pgp.settle(1);
  }
  return outcome!;
}
