import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

const _note = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 0);

PickedFile _pdf(int size, {String name = 'passport-scan.pdf'}) =>
    PickedFile(name: name, bytes: Uint8List.fromList([for (var i = 0; i < size; i++) i & 0xff]), mimeType: 'application/pdf');

void main() {
  late FakeFiles files;

  Future<TestApp> openNote(WidgetTester tester, {SecureNote note = _note}) async {
    files = FakeFiles();
    final app = TestApp();
    await startApp(tester, app, overrides: [files.asOverride]);
    await createVault(tester);
    await app.container.read(vaultControllerProvider.notifier).addNote(note);
    await goTo(tester, app, '/vault/notes/${note.id}');
    return app;
  }

  List<SecureNote> notes(TestApp app) => app.container.read(vaultControllerProvider).notes;
  Future<void> attach(WidgetTester tester, String sourceId) async {
    await tapOn(tester, find.text(t('notes.attach')));
    await tapOn(tester, find.text(t(sourceId)));
  }

  Future<void> save(WidgetTester tester) => tapOn(tester, find.widgetWithText(FilledButton, t('notes.save')));

  testWidgets('attaches a document: listed by name and size, stored encrypted, kept on save', (tester) async {
    final app = await openNote(tester);
    files.nextPick = _pdf(2 * 1024 * 1024);

    await attach(tester, 'notes.attach.file');

    expect(files.opened, ['file *']);
    expect(find.text('passport-scan.pdf'), findsOneWidget);
    expect(find.text(t('notes.file.mb', {'size': 2.0})), findsOneWidget);
    await save(tester);

    final file = notes(app).single.files.single;
    expect((file.name, file.size, file.type), ('passport-scan.pdf', 2 * 1024 * 1024, 'application/pdf'));
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    final stored = app.attachments.files[vaultId]![file.id]!.sealed;
    expect(stored.sublist(0, 4), kma1Magic);
    expect(stored.length, kma1Length(file.size));
    expect(kma1DecryptSync(stored, unb64(file.key)), _pdf(2 * 1024 * 1024).bytes);
    // Nothing about the file is in the vault's storage in the clear either
    expect(storedText(app), isNot(contains('passport-scan')));
  });

  testWidgets('attaches a photo from the library and one from the camera', (tester) async {
    final app = await openNote(tester);

    files.nextPick = PickedFile(name: 'IMG_0001.jpg', bytes: Uint8List.fromList(utf8.encode('jpeg')), mimeType: 'image/jpeg');
    await attach(tester, 'notes.attach.photo');
    files.nextPick = PickedFile(name: 'image_picker_42.jpg', bytes: Uint8List.fromList(utf8.encode('photo')), mimeType: 'image/jpeg');
    await attach(tester, 'notes.attach.camera');
    await save(tester);

    expect(files.opened, ['photos', 'camera']);
    expect([for (final file in notes(app).single.files) file.name], ['IMG_0001.jpg', 'image_picker_42.jpg']);
  });

  testWidgets('a cancelled pick attaches nothing', (tester) async {
    final app = await openNote(tester);

    await attach(tester, 'notes.attach.file');

    expect(find.text(t('notes.unsaved.title')), findsNothing);
    expect(app.attachments.files.values.expand((vault) => vault.keys), isEmpty);
  });

  testWidgets('refuses a file over 50 MB, saying the limit', (tester) async {
    final app = await openNote(tester);
    files.nextPick = _pdf(attachmentSizeLimit + 1, name: 'huge.bin');

    await attach(tester, 'notes.attach.file');

    expect(find.text(t('notes.attach.tooLarge', {'size': 50})), findsOneWidget);
    expect(find.text('huge.bin'), findsNothing);
    expect(app.attachments.files.values.expand((vault) => vault.keys), isEmpty);
  });

  testWidgets('takes no file past the 100th, saying the limit', (tester) async {
    final full = _note.copyWith(
      attachments: [
        for (var i = 0; i < attachmentsPerNote; i++)
          NoteAttachment(id: 'f$i', name: 'file $i.txt', size: 1, key: b64(randomBytes(32)), addedAt: 0),
      ],
    );
    final app = await openNote(tester, note: full);

    expect(find.text(t('notes.attach.full', {'count': 100})), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.ancestor(of: find.text(t('notes.attach')), matching: find.byType(OutlinedButton)));
    expect(button.onPressed, isNull);
    expect(notes(app).single.files, hasLength(100));
  });

  testWidgets('a failed write leaves the note as it was and says so', (tester) async {
    final app = await openNote(tester);
    app.attachments.failWrites = true;
    files.nextPick = _pdf(1000);

    await attach(tester, 'notes.attach.file');

    expect(find.text(t('notes.attach.failed')), findsOneWidget);
    expect(find.text('passport-scan.pdf'), findsNothing);
    expect(app.attachments.files.values.expand((vault) => vault.keys), isEmpty);
    // Nothing changed, so leaving asks nothing
    await tapOn(tester, find.bySemanticsLabel(t('nav.back')));
    expect(find.text(t('notes.unsaved.title')), findsNothing);
    expect(notes(app).single.attachments, isNull);
  });
}
