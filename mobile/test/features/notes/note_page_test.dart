import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

void main() {
  Future<TestApp> openNote(WidgetTester tester, [String id = 'new']) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    await goTo(tester, app, '/vault/notes/$id');
    return app;
  }

  List<SecureNote> notes(TestApp app) => app.container.read(vaultControllerProvider).notes;
  final save = find.widgetWithText(FilledButton, t('notes.save'));

  testWidgets('a note needs a title', (tester) async {
    final app = await openNote(tester);
    await tester.enterText(field(t('notes.field.text')), 'Some text');

    await tapOn(tester, save);

    expect(find.text(t('notes.error.title')), findsOneWidget);
    expect(notes(app), isEmpty);
    expect(location(app), '/vault/notes/new');

    // Typing a title clears the message, and the note saves
    await tester.enterText(field(t('notes.field.title')), 'Passport');
    await tester.pump();
    expect(find.text(t('notes.error.title')), findsNothing);
    await tapOn(tester, save);
    expect(notes(app).single.title, 'Passport');
  });

  testWidgets('the keyboard neither suggests, corrects nor learns a note’s title or text', (tester) async {
    await openNote(tester);

    for (final label in ['notes.field.title', 'notes.field.text']) {
      final input = tester.widget<TextField>(field(t(label)));
      expect((input.autocorrect, input.enableSuggestions, input.enableIMEPersonalizedLearning), (false, false, false), reason: label);
    }
  });

  testWidgets('text over the limit says by how much, and is not saved', (tester) async {
    final app = await openNote(tester);
    await tester.enterText(field(t('notes.field.title')), 'Long');
    await tester.enterText(field(t('notes.field.text')), 'x' * (noteTextLimit + 12));
    await tester.pump();

    expect(find.text(t('notes.error.tooLong', {'count': 12, 'limit': noteTextLimit})), findsOneWidget);
    await tapOn(tester, save);
    expect(notes(app), isEmpty);

    await tester.enterText(field(t('notes.field.text')), 'x' * noteTextLimit);
    await tester.pump();
    expect(find.textContaining('too many'), findsNothing);
    await tapOn(tester, save);
    expect(notes(app).single.text.length, noteTextLimit);
  });

  testWidgets('leaving with changes asks, and Discard leaves the note as it was', (tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(const SecureNote(id: 'n1', title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
    await goTo(tester, app, '/vault/notes/n1');

    await tester.enterText(field(t('notes.field.text')), 'changed');
    await tapOn(tester, find.bySemanticsLabel(t('nav.back')));

    expect(find.text(t('notes.unsaved.title')), findsOneWidget);
    await tapOn(tester, find.text(t('notes.unsaved.stay')));
    expect(location(app), '/vault/notes/n1');
    expect(find.widgetWithText(TextField, 'changed'), findsOneWidget);

    await tapOn(tester, find.bySemanticsLabel(t('nav.back')));
    await tapOn(tester, find.text(t('notes.unsaved.discard')));

    expect(location(app), '/vault');
    expect(notes(app).single.text, 'hunter2');
  });

  testWidgets('leaving with changes and choosing Save saves them', (tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(const SecureNote(id: 'n1', title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
    await goTo(tester, app, '/vault/notes/n1');

    await tester.enterText(field(t('notes.field.text')), 'correct horse');
    await tapOn(tester, find.bySemanticsLabel(t('nav.back')));
    await tapOn(tester, find.descendant(of: find.byType(Dialog), matching: find.text(t('notes.save'))));

    expect(location(app), '/vault');
    expect(notes(app).single.text, 'correct horse');
  });

  testWidgets('leaving without changes asks nothing', (tester) async {
    final app = await openNote(tester);

    await tapOn(tester, find.bySemanticsLabel(t('nav.back')));

    expect(find.text(t('notes.unsaved.title')), findsNothing);
    expect(location(app), '/vault');
  });

  testWidgets('pins and tags a note, and deletes it with Undo', (tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(const SecureNote(id: 'n1', title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
    await goTo(tester, app, '/vault/notes/n1');

    await tapOn(tester, find.byType(Switch));
    await tapOn(tester, save);
    expect(notes(app).single.pinned, isTrue);

    await goTo(tester, app, '/vault/notes/n1');
    await tapOn(tester, find.text(t('notes.delete')));
    expect(location(app), '/vault');
    expect(notes(app), isEmpty);
    await tapOn(tester, find.text(t('app.undo')));
    expect(notes(app).single.title, 'Wi-Fi');
  });

  testWidgets('going from one note to another shows the other', (tester) async {
    final app = await openNote(tester);
    await app.controller.addNote(const SecureNote(id: 'a', title: 'Passport', addedAt: 0));
    await app.controller.addNote(const SecureNote(id: 'b', title: 'Wi-Fi', addedAt: 0));
    await tester.pump(const Duration(seconds: 10));
    await goTo(tester, app, '/vault/notes/a');

    await goTo(tester, app, '/vault/notes/b');

    expect(tester.widget<TextField>(field(t('notes.field.title'))).controller!.text, 'Wi-Fi');
  });

  testWidgets('a note that is not in the vault says so', (tester) async {
    await openNote(tester, 'gone');

    expect(find.text(t('notes.missing')), findsOneWidget);
  });

  testWidgets('opening a linked note from a note being edited keeps the edit under it', (tester) async {
    const first = '11111111-1111-4111-8111-111111111111';
    const second = '22222222-2222-4222-8222-222222222222';
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    final vault = app.container.read(vaultControllerProvider.notifier);
    await vault.addNote(const SecureNote(id: first, title: 'Wi-Fi', text: 'hunter2', addedAt: 0));
    await vault.addNote(const SecureNote(id: second, title: 'Router', text: 'admin', addedAt: 0));
    await vault.linkItems(notes(app).first, notes(app).last);
    await tester.pump(const Duration(seconds: 10));
    await goTo(tester, app, '/vault/notes/$first');

    await tester.enterText(field(t('notes.field.text')), 'changed');
    await tapOn(tester, find.text('Router'));
    expect(location(app), '/vault/notes/$second');

    await tapOn(tester, find.bySemanticsLabel(t('nav.back')));

    expect(location(app), '/vault/notes/$first');
    expect(find.widgetWithText(TextField, 'changed'), findsOneWidget);
  });
}
