import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../keys/keys_kit.dart' show keyFixture;
import '../sync/sync_screen_kit.dart' show FakeSyncNotifier, fakeSync;

/// Sync with one shared space, "Family".
final _family = SyncSettings(
  spaces: [
    Space(
      id: 'fam',
      name: 'Family',
      target: SyncTarget(
        dav: const DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'pw'),
        file: spaceFile('fam'),
        key: 'a2V5',
      ),
      joinedAt: 1,
    ),
  ],
);

final _picker = find.text(t('spaces.picker.label'));

void main() {
  Future<TestApp> open(WidgetTester tester) async {
    final app = await startApp(tester, TestApp(), overrides: [fakeSync(const SyncSnapshot())]);
    await createVault(tester);
    // After the unlock, which loads the vault's own settings
    (app.container.read(syncProvider.notifier) as FakeSyncNotifier).setSettings(_family);
    await tester.pumpAndSettle();
    return app;
  }

  /// Picks [name] in the space menu.
  Future<void> pick(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.text(t('spaces.picker.mine')));
    await tapOn(tester, find.text(t('spaces.picker.mine')));
    await tapOn(tester, find.text(name).last);
  }

  testWidgets('a new note goes in the space picked for it', (tester) async {
    final app = await open(tester);
    await goTo(tester, app, '/vault/notes/new');
    await tester.enterText(field(t('notes.field.title')), 'Flat');

    await pick(tester, 'Family');
    await tapOn(tester, find.widgetWithText(FilledButton, t('notes.save')));

    expect(app.state.notes.single.spaceId, 'fam');
  });

  testWidgets('a note can be taken out of its space', (tester) async {
    final app = await open(tester);
    await app.controller.addNote(const SecureNote(id: 'shared', title: 'Shared', spaceId: 'fam', addedAt: 0));
    await tester.pump(const Duration(seconds: 10));

    await goTo(tester, app, '/vault/notes/shared');
    await tester.ensureVisible(find.text('Family'));
    await tapOn(tester, find.text('Family'));
    await tapOn(tester, find.text(t('spaces.picker.mine')).last);
    await tapOn(tester, find.widgetWithText(FilledButton, t('notes.save')));

    expect(app.state.notes.firstWhere((note) => note.id == 'shared').spaceId, isNull);
  });

  testWidgets('a key moves into a space, and its halves stay as they were', (tester) async {
    final app = await open(tester);
    final parsed = await tester.runAsync(() => crypto.readPrivateKey(keyFixture('openssh/ed25519').readAsBytesSync()));
    final key = vaultKeyOf(parsed!, id: 'k1', name: 'laptop', origin: KeyOrigin.imported);
    await app.controller.addKey(key);
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text('laptop'));

    await pick(tester, 'Family');
    await tester.ensureVisible(find.widgetWithText(FilledButton, t('passkeys.save')));
    await tapOn(tester, find.widgetWithText(FilledButton, t('passkeys.save')));

    final saved = app.state.keys.single;
    expect(saved.spaceId, 'fam');
    expect((saved.privateKey, saved.publicKey), (key.privateKey, key.publicKey));
  });

  testWidgets('a passkey offers no space, even with spaces to pick', (tester) async {
    final app = await open(tester);
    await app.controller.addPasskeys(const [
      Passkey(
        id: 'p1',
        credentialId: 'AAECAwQFBgcICQoLDA0ODw',
        rpId: 'github.com',
        rpName: 'GitHub',
        userHandle: 'dXNlcg',
        userName: 'octocat@example.com',
        privateKey: 'AA==',
        addedAt: 0,
      ),
    ]);
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text('GitHub'));

    expect(find.text(t('passkeys.label')), findsOneWidget, reason: 'the sheet is open');
    expect(_picker, findsNothing);
    expect(find.text('Family'), findsNothing);
  });
}
