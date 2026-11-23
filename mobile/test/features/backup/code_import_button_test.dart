import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/build_kind.dart';
import 'package:kemlock/features/backup/code_import_button.dart';
import 'package:kemlock/features/backup/code_readers.dart';
import 'package:kemlock/platform/files.dart';

import '../../fakes/fake_code_readers.dart';
import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';

void main() {
  late FakeFiles files;
  late FakeCodeReaders readers;
  late List<List<String>> found;

  setUp(() {
    files = FakeFiles();
    readers = FakeCodeReaders();
    found = [];
  });

  Future<void> pump(WidgetTester tester) =>
      pumpOnPage(tester, CodeImportButton(onCodes: found.add), overrides: [files.asOverride, ...readers.overrides]);

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.text(t('codeImport.button')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String id) async {
    await openMenu(tester);
    await tester.tap(find.text(t(id)));
    await tester.pumpAndSettle();
  }

  testWidgets('offers the photo library, the camera and a file', (tester) async {
    await pump(tester);
    await openMenu(tester);

    expect(find.text(t('codeImport.from.photos')), findsOneWidget);
    expect(find.text(t('codeImport.from.camera')), findsOneWidget);
    expect(find.text(t('codeImport.from.file')), findsOneWidget);
    expect(files.opened, isEmpty);
  });

  testWidgets('reads the codes off a picture from the photos', (tester) async {
    files.nextPick = FakeFiles.image('IMG_0001.png');
    readers.images.text = 'Backup codes\n1234 5678  8765 4321';
    await pump(tester);

    await choose(tester, 'codeImport.from.photos');

    expect(files.opened, ['photos']);
    expect(readers.images.read.single.name, 'IMG_0001.png');
    expect(found, [
      ['1234 5678', '8765 4321'],
    ]);
  });

  testWidgets('reads a new photo as a picture, whatever it is called', (tester) async {
    files.nextPick = PickedFile(name: 'photo', bytes: Uint8List(4));
    readers.images.text = 'abcde-12345';
    await pump(tester);

    await choose(tester, 'codeImport.from.camera');

    expect(files.opened, ['camera']);
    expect(found, [
      ['abcde-12345'],
    ]);
  });

  testWidgets('reads a PDF or a text file picked from the files', (tester) async {
    files.nextPick = FakeFiles.text('github-recovery-codes.pdf', '%PDF-1.7', mimeType: 'application/pdf');
    readers.pdfs.text = 'GitHub recovery codes\n1a2b3-4c5d6  7e8f9-0a1b2';
    await pump(tester);

    await choose(tester, 'codeImport.from.file');
    files.nextPick = FakeFiles.text('codes.txt', 'one\ntwo');
    await choose(tester, 'codeImport.from.file');

    expect(files.opened, ['file ${codeFileExtensions.join(',')}', 'file ${codeFileExtensions.join(',')}']);
    expect(found, [
      ['1a2b3-4c5d6', '7e8f9-0a1b2'],
      ['one', 'two'],
    ]);
  });

  testWidgets('shows a bar while it reads, and can’t be pressed again', (tester) async {
    final reading = Completer<void>();
    readers.images.wait = reading.future;
    readers.images.text = 'abcde-12345';
    files.nextPick = FakeFiles.image('codes.png');
    await pump(tester);
    await openMenu(tester);
    await tester.tap(find.text(t('codeImport.from.photos')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.semanticsLabel, t('codeImport.reading'));
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);

    reading.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(found, [
      ['abcde-12345'],
    ]);
  });

  testWidgets('says when the file holds no codes, until the warning is closed', (tester) async {
    files.nextPick = FakeFiles.image('cat.png');
    readers.images.text = 'A cat on a sofa';
    await pump(tester);

    await choose(tester, 'codeImport.from.photos');
    expect(find.text(t('codeImport.none')), findsOneWidget);
    expect(found, isEmpty);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text(t('codeImport.none')), findsNothing);
  });

  testWidgets('says which files it reads', (tester) async {
    files.nextPick = FakeFiles.text('vault.json', '{}', mimeType: 'application/json');
    await pump(tester);

    await choose(tester, 'codeImport.from.file');

    expect(find.text(t('codeImport.unsupported')), findsOneWidget);
  });

  testWidgets('says when a file can’t be read', (tester) async {
    files.nextPick = FakeFiles.text('codes.pdf', 'not really', mimeType: 'application/pdf');
    readers.pdfs.error = Exception('damaged');
    await pump(tester);

    await choose(tester, 'codeImport.from.file');

    expect(find.text(t('codeImport.failed')), findsOneWidget);
  });

  testWidgets('clears the last warning when it opens again', (tester) async {
    files.nextPick = FakeFiles.text('vault.json', '{}', mimeType: 'application/json');
    await pump(tester);
    await choose(tester, 'codeImport.from.file');

    await openMenu(tester);

    expect(find.text(t('codeImport.unsupported')), findsNothing);
  });

  testWidgets('does nothing when the picker is closed', (tester) async {
    await pump(tester);

    await choose(tester, 'codeImport.from.photos');

    expect(files.opened, ['photos']);
    expect(readers.images.read, isEmpty);
    expect(found, isEmpty);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  // openspec: add-fdroid-release, design decision 4
  group('in a build that reads neither pictures nor PDFs', () {
    /// The button as the free build has it: its readers refuse pictures and PDFs.
    Future<void> pumpTextOnly(WidgetTester tester) {
      readers.images.error = const NotInThisBuild();
      readers.pdfs.error = const NotInThisBuild();
      return pumpOnPage(
        tester,
        CodeImportButton(onCodes: found.add),
        overrides: [
          files.asOverride,
          readers.images.asOverride,
          readers.pdfs.asOverride,
          readsPicturesProvider.overrideWithValue(false),
          readsPdfsProvider.overrideWithValue(false),
        ],
      );
    }

    testWidgets('opens the file picker at once, held to text files, and says why', (tester) async {
      await pumpTextOnly(tester);

      expect(find.text(t('backup.import.freeNote')), findsOneWidget);
      expect(find.text(t('codeImport.button')), findsNothing);
      await tester.tap(find.text(t('backup.import.freeButton')));
      await tester.pumpAndSettle();

      expect(files.opened, ['file txt,csv,md']);
      expect(find.text(t('codeImport.from.photos')), findsNothing);
      expect(find.text(t('codeImport.from.camera')), findsNothing);
    });

    testWidgets('imports the codes of a text file', (tester) async {
      files.nextPick = FakeFiles.text('codes.txt', 'abcd-1234\nefgh-5678');
      await pumpTextOnly(tester);

      await tester.tap(find.text(t('backup.import.freeButton')));
      await tester.pumpAndSettle();

      expect(found, [
        ['abcd-1234', 'efgh-5678'],
      ]);
    });

    testWidgets('says so for a PDF or a picture handed over anyway, and adds nothing', (tester) async {
      await pumpTextOnly(tester);

      for (final file in [FakeFiles.text('codes.pdf', '%PDF-1.7', mimeType: 'application/pdf'), FakeFiles.image('codes.png')]) {
        files.nextPick = file;
        await tester.tap(find.text(t('backup.import.freeButton')));
        await tester.pumpAndSettle();

        expect(find.text(t('backup.import.notInThisBuild')), findsOneWidget, reason: file.name);
        expect(find.text(t('codeImport.unsupported')), findsNothing);
      }
      expect(found, isEmpty);
    });

    test('is the free build, and not the store build', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final textOnly = !container.read(readsPicturesProvider) && !container.read(readsPdfsProvider);

      expect(textOnly, buildKind == BuildKind.free);
    });
  });
}
