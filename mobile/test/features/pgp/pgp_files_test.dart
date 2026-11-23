// The temporary files of the PGP actions, in a real directory: made for a
// job, gone when the sheet closes, on cancel and on lock, and swept at
// start; and the file service's two new calls.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/pgp/decrypt_sheet.dart';
import 'package:kemlock/features/pgp/encrypt_sheet.dart';
import 'package:kemlock/features/pgp/pgp_files.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import 'pgp_kit.dart';

void main() {
  group('the directory helpers', () {
    late Directory root;
    setUp(() => root = Directory('${Directory.systemTemp.createTempSync('pgp-files-test').path}/pgp'));
    tearDown(() {
      if (root.parent.existsSync()) root.parent.deleteSync(recursive: true);
    });

    test('a job directory is new, empty, and under the root', () async {
      final first = await createPgpJobDirectory(root);
      final second = await createPgpJobDirectory(root);
      expect(first.path, isNot(second.path));
      expect(first.parent.path, root.path);
      expect(first.listSync(), isEmpty);
      // Its name is random: nothing of the vault or of a file
      expect(first.uri.pathSegments.where((s) => s.isNotEmpty).last, matches(r'^[0-9a-f]{16}$'));
    });

    test('deleting takes the directory and what is in it, and bears one that is gone', () async {
      final directory = await createPgpJobDirectory(root);
      File('${directory.path}/letter.txt').writeAsStringSync('decrypted');
      await deletePgpDirectory(directory);
      expect(directory.existsSync(), isFalse);
      await deletePgpDirectory(directory);
      await deletePgpFile('${directory.path}/letter.txt');
    });

    test('the sweep at start removes what a killed app left', () async {
      final leftover = await createPgpJobDirectory(root);
      File('${leftover.path}/letter.txt').writeAsStringSync('decrypted, and never saved');
      await sweepPgpTemp(root);
      expect(root.existsSync(), isFalse);
      // With nothing to sweep it does nothing
      await sweepPgpTemp(root);
    });
  });

  group('the file service', () {
    test('a picked path is not read, and text is shared as text', () async {
      final files = FakeFiles()..nextPath = FakeFiles.onDisk('report.pdf', utf8.encode('a report'));
      final picked = (await files.pickFilePath())!;
      addTearDown(() => File(picked.path).parent.deleteSync(recursive: true));
      expect((picked.name, picked.size), ('report.pdf', 8));
      expect(File(picked.path).readAsStringSync(), 'a report');
      expect(await files.pickFilePath(), isNull);
      expect(files.opened, ['path', 'path']);

      await files.shareText('-----BEGIN PGP MESSAGE-----');
      expect(files.sharedTexts, ['-----BEGIN PGP MESSAGE-----']);
      expect(files.saved, isEmpty);
    });
  });

  group('a sheet and its files', () {
    Future<PgpApp> startWith(WidgetTester tester, Uint8List content, {String name = 'report.pdf'}) async {
      final pgp = PgpApp(tester);
      await pgp.start(keys: ['ed']);
      pgp.files.nextPath = FakeFiles.onDisk(name, content);
      return pgp;
    }

    testWidgets('the picker\'s copy of a file to encrypt is deleted when the job ends, its output when the sheet closes', (tester) async {
      final pgp = await startWith(tester, Uint8List.fromList(utf8.encode('the report, in plain text')));
      final picked = pgp.files.nextPath!.path;
      addTearDown(() {
        final directory = File(picked).parent;
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.chooseFile')));
      expect(find.text('report.pdf'), findsOneWidget);
      expect(File(picked).existsSync(), isTrue);

      await pgp.tap(find.text(t('pgp.encrypt.button')));
      // Shared from the job's directory, under the file's own name
      expect(pgp.files.fromPath, ['report.pdf.gpg']);
      expect(pgp.tempEntries.where((p) => p.endsWith('report.pdf.gpg')), hasLength(1));
      expect(File(picked).existsSync(), isFalse, reason: 'the plain copy in the cache');

      await pgp.closeSheet();
      expect(find.byType(EncryptSheet), findsNothing);
      expect(pgp.tempEntries, isEmpty);
    });

    testWidgets('a file that was removed from the sheet is deleted at once', (tester) async {
      final pgp = await startWith(tester, Uint8List.fromList(utf8.encode('changed my mind')));
      final picked = pgp.files.nextPath!.path;
      addTearDown(() {
        final directory = File(picked).parent;
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.chooseFile')));
      await pgp.tap(find.text(t('pgp.encrypt.writeMessage')));
      expect(File(picked).existsSync(), isFalse);
      expect(find.text('report.pdf'), findsNothing);
    });

    testWidgets('a cancelled job leaves no directory', (tester) async {
      final pgp = await startWith(tester, Uint8List(200000));
      addTearDown(() {
        final directory = File(pgp.files.nextPath?.path ?? '${pgp.tempRoot.path}/x').parent;
        if (directory.existsSync() && directory.path != pgp.tempRoot.path) directory.deleteSync(recursive: true);
      });
      pgp.hold = true;
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.chooseFile')));
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      expect(pgp.tempEntries, hasLength(1), reason: 'the job has its directory');
      expect(find.text(t('pgp.cancel')), findsOneWidget);

      await pgp.tap(find.text(t('pgp.cancel')));
      expect(pgp.held.single.cancelled, isTrue);
      expect(pgp.tempEntries, isEmpty);
      // The sheet is ready to go again
      expect(find.text(t('pgp.encrypt.button')), findsOneWidget);
      expect(pgp.files.fromPath, isEmpty);
    });

    testWidgets('locking with a decrypted file waiting deletes it and closes the sheet', (tester) async {
      final pgp = await startWith(tester, fixtureBytes('pgp/gnupg/zip.gpg'), name: 'zip.gpg');
      final picked = pgp.files.nextPath!.path;
      addTearDown(() {
        final directory = File(picked).parent;
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      await pgp.open('decrypt');
      await pgp.tap(find.text(t('pgp.decrypt.chooseFile')));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(find.text('report.txt'), findsOneWidget);
      final decrypted = pgp.tempEntries.where((p) => p.endsWith('report.txt')).single;
      expect(File(decrypted).lengthSync(), 216000);

      pgp.app.container.read(vaultControllerProvider.notifier).lock();
      await pgp.settle();
      expect(find.byType(DecryptSheet), findsNothing);
      expect(File(decrypted).existsSync(), isFalse);
      expect(pgp.tempEntries, isEmpty);
      expect(File(picked).existsSync(), isFalse, reason: 'the picker\'s copy goes too');
    });

    testWidgets('closing the sheet deletes a decrypted file that was not saved', (tester) async {
      final pgp = await startWith(tester, fixtureBytes('pgp/gnupg/zip.gpg'), name: 'zip.gpg');
      addTearDown(() {
        final directory = File(pgp.requests.whereType<DecryptRequest>().first.inputPath!).parent;
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      await pgp.open('decrypt');
      await pgp.tap(find.text(t('pgp.decrypt.chooseFile')));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(pgp.tempEntries, isNotEmpty);
      await pgp.closeSheet();
      expect(pgp.tempEntries, isEmpty);
    });
  });
}
