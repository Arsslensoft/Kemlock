import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/notes/note_files.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

/// A 1×1 PNG, so the picture really decodes.
final _png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  Future<TestApp> openNoteWithPicture(WidgetTester tester) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    final key = randomBytes(32);
    final vaultId = app.container.read(vaultControllerProvider).vault.id;
    await app.attachments.write(vaultId, 'pic1', _png, key);
    await app.container
        .read(vaultControllerProvider.notifier)
        .addNote(
          SecureNote(
            id: 'n1',
            title: 'Passport',
            addedAt: 0,
            attachments: [
              NoteAttachment(id: 'pic1', name: 'passport.png', size: _png.length, type: 'image/png', key: b64(key), addedAt: 0),
            ],
          ),
        );
    await goTo(tester, app, '/vault/notes/n1');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('shows an attached picture in the note, decrypted', (tester) async {
    await openNoteWithPicture(tester);

    final thumbs = find.byType(PictureThumb);
    expect(thumbs, findsNWidgets(2));
    final image = tester.widget<Image>(find.descendant(of: thumbs.first, matching: find.byType(Image)));
    expect((image.image as MemoryImage).bytes, _png);
  });

  testWidgets('opens a picture full screen and closes it', (tester) async {
    await openNoteWithPicture(tester);

    await tapOn(tester, find.byKey(const ValueKey('picture:pic1')));

    expect(find.byType(PictureViewer), findsOneWidget);
    expect(find.descendant(of: find.byType(PictureViewer), matching: find.byType(InteractiveViewer)), findsOneWidget);
    await tapOn(tester, find.byTooltip(t('notes.file.close')));
    expect(find.byType(PictureViewer), findsNothing);
  });

  testWidgets('locking replaces an open picture with the lock screen', (tester) async {
    final app = await openNoteWithPicture(tester);
    await tapOn(tester, find.byKey(const ValueKey('picture:pic1')));
    expect(find.byType(PictureViewer), findsOneWidget);

    app.container.read(vaultControllerProvider.notifier).lock();
    await tester.pumpAndSettle();

    expect(find.byType(LockScreen), findsOneWidget);
    expect(find.byType(PictureViewer), findsNothing);
    expect(find.byType(PictureThumb), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is Image && widget.image is MemoryImage), findsNothing);
  });
}
