import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

final _pdf = Uint8List.fromList([...utf8.encode('%PDF-1.7\n'), for (var i = 0; i < 70000; i++) i & 0xff]);
final _png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  late FakeFiles files;

  Future<TestApp> openNote(WidgetTester tester) async {
    files = FakeFiles();
    final app = TestApp();
    await startApp(tester, app, overrides: [files.asOverride]);
    await createVault(tester);
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    final pdfKey = randomBytes(32);
    final pngKey = randomBytes(32);
    await app.attachments.write(vaultId, 'doc1', _pdf, pdfKey);
    await app.attachments.write(vaultId, 'pic1', _png, pngKey);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(
          SecureNote(
            id: 'n1',
            title: 'Taxes',
            addedAt: 0,
            attachments: [
              NoteAttachment(id: 'doc1', name: 'tax-2026.pdf', size: _pdf.length, type: 'application/pdf', key: b64(pdfKey), addedAt: 0),
              NoteAttachment(id: 'pic1', name: 'receipt.png', size: _png.length, type: 'image/png', key: b64(pngKey), addedAt: 0),
            ],
          ),
        );
    // The note's toast would sit over the sheets these tests open, until it times out
    await tester.pump(const Duration(seconds: 10));
    await goTo(tester, app, '/vault/notes/n1');
    return app;
  }

  Future<void> confirm(WidgetTester tester, String labelId) =>
      tapOn(tester, find.descendant(of: find.byType(Dialog), matching: find.text(t(labelId))));

  testWidgets('saves a copy under its own name, byte for byte, after the warning', (tester) async {
    await openNote(tester);

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.copy.save')));
    expect(find.text(t('notes.copy.title')), findsOneWidget);
    expect(find.text(t('notes.copy.body', {'name': 'tax-2026.pdf'})), findsOneWidget);
    await confirm(tester, 'notes.copy.save');

    final saved = files.saved.single;
    expect((saved.name, saved.mimeType, saved.shared), ('tax-2026.pdf', 'application/pdf', false));
    expect(saved.bytes, _pdf);
    expect(find.text(t('notes.copy.saved', {'location': 'Downloads/tax-2026.pdf'})), findsOneWidget);
  });

  testWidgets('shares a copy, byte for byte', (tester) async {
    await openNote(tester);

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.copy.share')));
    await confirm(tester, 'notes.copy.share');

    expect(files.saved.single.shared, isTrue);
    expect(files.saved.single.bytes, _pdf);
  });

  testWidgets('cancelling the warning hands nothing over', (tester) async {
    await openNote(tester);

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.copy.save')));
    await confirm(tester, 'export.cancel');

    expect(files.saved, isEmpty);
    expect(find.text(t('notes.copy.title')), findsNothing);
  });

  testWidgets('saves a picture from the full screen view', (tester) async {
    await openNote(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    await tapOn(tester, find.byKey(const ValueKey('picture:pic1')));
    await tapOn(tester, find.byTooltip(t('notes.copy.save')));
    await confirm(tester, 'notes.copy.save');

    expect(files.saved.single.name, 'receipt.png');
    expect(files.saved.single.bytes, _png);
  });

  testWidgets('says so when the file is not on this phone, and hands nothing over', (tester) async {
    final app = await openNote(tester);
    await app.attachments.delete(app.container.read(vaultControllerProvider).vault.id, 'doc1');

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.copy.save')));
    await confirm(tester, 'notes.copy.save');

    expect(files.saved, isEmpty);
    expect(find.text(t('notes.file.missing')), findsOneWidget);
  });

  testWidgets('a cancelled save keeps nothing', (tester) async {
    await openNote(tester);
    files.nextSave = const SaveCancelled();

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.copy.save')));
    await confirm(tester, 'notes.copy.save');

    expect(files.saved, isEmpty);
  });

  testWidgets('removes a file from the note, and Undo brings it back', (tester) async {
    final app = await openNote(tester);

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.file.remove')));
    expect(find.text('tax-2026.pdf'), findsNothing);
    await tapOn(tester, find.text(t('app.undo')));
    expect(find.text('tax-2026.pdf'), findsOneWidget);

    await tapOn(tester, find.text('tax-2026.pdf'));
    await tapOn(tester, find.text(t('notes.file.remove')));
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, find.widgetWithText(FilledButton, t('notes.save')));

    final note = app.container.read(vaultControllerProvider).notes.single;
    expect([for (final file in note.files) file.id], ['pic1']);
    // The stored file waits for the sweep, so an Undo of the note's own deletion still finds it
    expect(app.attachments.files[app.container.read(vaultControllerProvider).vault.id]!.keys, contains('doc1'));
  });
}
