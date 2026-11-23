import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/pkcs8.dart';
import 'package:kemlock/crypto/keys/sshsig.dart';
import 'package:kemlock/features/export/export_key.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/keys/generate_key_sheet.dart';
import 'package:kemlock/features/keys/import_key_sheet.dart';
import 'package:kemlock/features/keys/sign_sheet.dart';
import 'package:kemlock/features/keys/verify_sheet.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/files.dart';

import '../fakes/fake_files.dart';
import '../features/keys/keys_kit.dart' show FakeKeyGeneration, keyFixture;
import '../features/keys/ssh_kit.dart' show sshFixtureFingerprints, sshFixtureKey, sshsigFile;
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import '../vault/fast_kdf.dart';
import 'flow_kit.dart';

const _exportPassword = 'a long export password';
final _scan = Uint8List.fromList([for (var i = 0; i < 70000; i++) (i * 7 + 3) & 0xff]);

/// Keys, a note and its file from end to end, through the screens: made on
/// a phone, exported to an archive from Settings, the phone wiped from the
/// lock screen, a new vault set up, the archive imported, and everything
/// found again.
void main() {
  testWidgets('a vault of codes, keys and a note with a file comes back from an archive after a wipe', (tester) async {
    final scratch = Directory.systemTemp.createTempSync('kemlock-flow-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final files = FakeFiles();
    final generations = <FakeKeyGeneration>[];
    final app = TestApp(now: () => rfcTime);
    await startApp(
      tester,
      app,
      overrides: [
        files.asOverride,
        exportDeriveKeyProvider.overrideWithValue(fastKdf),
        exportScratchProvider.overrideWithValue(() async => scratch),
        keyReaderProvider.overrideWithValue((input, {passphrase}) => crypto.readPrivateKey(input, passphrase: passphrase)),
        keyGeneratorProvider.overrideWithValue((request) {
          final generation = FakeKeyGeneration(request);
          generations.add(generation);
          return generation;
        }),
      ],
    );

    /// Lets real work (isolates, file IO, Ed25519) finish.
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pumpAndSettle();
      }
    }

    Future<void> openAdd(String rowId) async {
      // The last add's toast sits over the tab bar until it times out
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
      await tapOn(tester, find.text(t(rowId)));
    }

    // The first phone: a code, a note with a file, a generated key and an imported one
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', rfcSecret);
    await tapOn(tester, tab('nav.vault'));

    await openAdd('vault.add.note');
    await tester.enterText(field(t('notes.field.title')), 'Passport');
    await tester.enterText(field(t('notes.field.text')), 'In the drawer, left side');
    files.nextPick = PickedFile(name: 'passport-scan.pdf', bytes: _scan, mimeType: 'application/pdf');
    await tapOn(tester, find.text(t('notes.attach')));
    await tapOn(tester, find.text(t('notes.attach.file')));
    await settle();
    expect(find.text('passport-scan.pdf'), findsOneWidget);
    await tapOn(tester, find.widgetWithText(FilledButton, t('notes.save')));
    await settle();

    await openAdd('vault.add.generateKey');
    await tester.enterText(find.widgetWithText(TextField, t('keys.generate.name')), 'laptop');
    await tapOn(tester, find.text(t('keys.generate.button')));
    await tester.runAsync(generations.single.finish);
    await settle();

    await openAdd('vault.add.importKey');
    final fixture = keyFixture('openssh/ed25519');
    files.nextPick = PickedFile(name: 'id_ed25519', bytes: fixture.readAsBytesSync());
    await tapOn(tester, find.text(t('keys.import.file')));
    await settle();
    await tapOn(tester, find.text(t('keys.import.add')));
    await settle();
    // The toasts of the adds would sit over the sheets to come
    await tester.pump(const Duration(seconds: 10));

    final before = app.state;
    expect((before.accounts.length, before.notes.single.files.single.size, before.keys.length), (1, _scan.length, 2));

    // Exported from Settings, under a password, to an archive with the file in it
    await tapOn(tester, tab('nav.settings'));
    await tapOn(tester, find.text(t('app.menu.export')));
    await tester.enterText(field(t('export.field.password')), _exportPassword);
    await tester.enterText(field(t('export.field.confirm')), _exportPassword);
    await tester.pump();
    await tester.ensureVisible(find.text(t('export.button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('export.button')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle();
    // Whoever holds the open vault shows it is them before anything leaves it; then the archive is written
    await confirmOwner(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await settle();
    await pumpUntil(tester, find.text(t('export.success')));
    await tapOn(tester, find.text(t('export.close')));
    final saved = files.saved.single;
    expect(saved.name, matches(RegExp(r'^kemlock-export-.*\.zip$')));
    expect(saved.mimeType, 'application/zip');

    // Wiped from the lock screen, files and all
    app.controller.lock();
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await submitPassword(tester, 'not the password');
      await settle();
    }
    await tapOn(tester, find.text(t('unlock.error.resetLink')));
    await tapOn(tester, find.text(t('unlock.wipe.confirm')));
    await settle();
    expect(app.attachments.files.values.every((vault) => vault.isEmpty), isTrue);

    // A new vault, and the archive imported into it from Settings
    await createVault(tester, password: 'Another-Horse-7');
    expect(app.state.notes, isEmpty);
    files.nextPick = PickedFile(name: saved.name, bytes: saved.bytes, mimeType: 'application/zip');
    await tapOn(tester, tab('nav.settings'));
    await tapOn(tester, find.text(t('app.menu.import')));
    await tapOn(tester, find.text(t('import.browse')));
    await tester.enterText(field(t('import.field.password')), _exportPassword);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('import.decrypt')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle();
    final importOne = find.text(t('import.button.merge', {'count': 1}));
    await pumpUntil(tester, importOne);
    await tester.ensureVisible(importOne);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(importOne);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle();

    // Everything is back: the code, both keys, the note, and its file, which opens
    final after = app.state;
    expect(after.keys.map((key) => (key.name, key.origin, key.publicKey)).toSet(), {
      for (final key in before.keys) (key.name, key.origin, key.publicKey),
    });
    expect(after.keys.map((key) => key.origin).toSet(), {KeyOrigin.generated, KeyOrigin.imported});
    final note = after.notes.single;
    expect((note.title, note.text, note.files.single.name), ('Passport', 'In the drawer, left side', 'passport-scan.pdf'));
    final stored = app.attachments.files[after.vault.id]![note.files.single.id]!.sealed;
    expect(kma1DecryptSync(stored, unb64(note.files.single.key)), _scan);

    await tapOn(tester, tab('nav.codes'));
    expect(accountRow('GitHub'), findsOneWidget);
    expect(code(rfcCode), findsOneWidget);

    await tapOn(tester, tab('nav.vault'));
    for (final name in ['Passport', 'laptop', before.keys.firstWhere((key) => key.origin == KeyOrigin.imported).name]) {
      expect(find.text(name), findsWidgets, reason: name);
    }
    await tapOn(tester, find.text('Passport'));
    await settle();
    expect(find.text('passport-scan.pdf'), findsOneWidget);
  });

  testWidgets('signing and verifying with an SSH key in a hidden vault leaves the phone as it was', (tester) async {
    final files = FakeFiles();
    final app = TestApp();
    await tester.runAsync(() async {
      await app.createVault(masterPassword);
      await app.vaultStore.createVault('Diary', 'Diary-Horse-9', listed: false);
    });
    await startApp(
      tester,
      app,
      overrides: [
        files.asOverride,
        sshSignerProvider.overrideWithValue((pkcs8, namespace, message) async => sshsigSign(await readPkcs8(pkcs8), namespace, message)),
        sshCheckerProvider.overrideWithValue(sshCheck),
      ],
    );
    await app.unlock(tester, 'Diary-Horse-9');
    expect(app.state.vault.hidden, isTrue);
    expect(await app.controller.addKey(await sshFixtureKey('ed25519', title: 'laptop')), isTrue);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();
      }
    }

    /// Everything the phone keeps: the key-value store, and the app's files.
    Map<String, Object?> kept() => {
      'store': {for (final key in app.store.storedKeys()) key: app.store.getItem(key)},
      'files': {for (final MapEntry(key: vault, value: stored) in app.attachments.files.entries) vault: stored.keys.toList()},
    };
    final before = kept();
    final revision = app.state.revision;
    final key = app.state.keys.single.toJson();

    // Sign typed text with the key
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text('laptop'));
    await tapOn(tester, find.text(t('keys.sign.action')));
    await tapOn(tester, find.descendant(of: find.byType(SignSheet), matching: find.text(t('keys.sign.text'))));
    await tester.enterText(find.widgetWithText(TextField, t('keys.sign.text')), 'hello');
    await tester.pump();
    await tapOn(tester, find.byKey(const ValueKey('sign-submit')));
    await settle();
    final signature = tester.widget<SelectableText>(find.byKey(const ValueKey('signature'))).data!;
    expect(signature, sshsigFile('ed25519-file-hello.txt.sig').readAsStringSync().trimRight());
    Navigator.of(tester.element(find.byType(SignSheet)), rootNavigator: true).pop();
    await tester.pumpAndSettle();

    // Verify it, from the same key's sheet
    await tapOn(tester, find.text(t('keys.verify.action')));
    await tester.enterText(find.widgetWithText(TextField, t('keys.verify.signature')), signature);
    await tapOn(tester, find.descendant(of: find.byType(VerifySheet), matching: find.text(t('keys.sign.text'))));
    await tester.enterText(find.widgetWithText(TextField, t('keys.sign.text')), 'hello');
    await tester.pump();
    await tapOn(tester, find.byKey(const ValueKey('verify-submit')));
    await settle();
    expect(find.text(t('keys.verify.good.own', {'name': 'laptop'})), findsOneWidget);
    Navigator.of(tester.element(find.byType(VerifySheet)), rootNavigator: true).pop();
    await tester.pumpAndSettle();

    // No key was added or changed, and nothing new is kept
    expect(app.state.revision, revision);
    expect(app.state.keys.single.toJson(), key);
    expect(kept(), before);
    expect(files.saved, isEmpty);

    // Locked, the phone holds what it held, and nothing of it names the signature or the key
    app.controller.lock();
    await tester.pumpAndSettle();
    expect(kept(), before);
    final stored = storedText(app);
    for (final trace in ['SSH SIGNATURE', 'U1NIU0lH', sshFixtureFingerprints['ed25519']!, 'laptop', 'sshsig', 'signature']) {
      expect(stored, isNot(contains(trace)), reason: trace);
    }
    expect(find.textContaining('laptop'), findsNothing);
  });
}
