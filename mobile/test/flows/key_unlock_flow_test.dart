import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/time.dart';
import 'package:kemlock/features/export/export_key.dart';
import 'package:kemlock/features/lock/key_reader.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/lock/unlock_method_sheet.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/vault/owner_check.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_files.dart';
import '../fakes/fake_security_keys.dart';
import '../features/lock/key_phone.dart' show SoftKey, pinBytes, testKeyPrompts;
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import '../vault/fast_kdf.dart';
import 'flow_kit.dart';

const _exportPassword = 'a long export password';

/// The phone's NFC and USB with software keys to hold to it, under the
/// app's own key reader.
class _Keys {
  final phone = FakeSecurityKeys();
  late final reader = CtapKeyReader(phone, now: phone.now);
  FakeDevice? _held;

  List<Override> get overrides => [
    keyReaderProvider.overrideWithValue(reader),
    securityKeysProvider.overrideWithValue(phone),
    exportDeriveKeyProvider.overrideWithValue(fastKdf),
  ];

  void hold(SoftKey soft) {
    takeAway();
    phone.arrive(_held = FakeKey(productName: 'Example Key', ctap: soft).device(kinds: {SecurityKeyLinkKind.nfc}));
  }

  void takeAway() {
    if (_held case final held?) phone.remove(held);
    _held = null;
  }
}

/// Opens "How this vault opens" from Settings.
Future<void> _openUnlockMethod(WidgetTester tester) async {
  await tapOn(tester, tab('nav.settings'));
  await tapOn(tester, find.text(t('unlockMethod.title')));
  expect(find.byType(UnlockMethodSheet), findsOneWidget);
}

/// The key's PIN in the sheet on top, with [soft] held to the phone.
Future<void> _giveKey(WidgetTester tester, _Keys keys, SoftKey soft) async {
  keys.hold(soft);
  await tester.enterText(field(t('lock.key.pin')).last, soft.pin!);
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await tester.pumpAndSettle();
}

/// Locks the vault: the lock screen is back.
Future<void> _lock(WidgetTester tester, TestApp app) async {
  app.controller.lock();
  await tester.pumpAndSettle();
  expect(find.byType(LockScreen), findsOneWidget);
}

/// The texts on screen, to compare one screen with another.
List<String> _texts(WidgetTester tester) => [for (final text in tester.widgetList<Text>(find.byType(Text))) text.data ?? ''];

// openspec: add-security-key-unlock, section 7
void main() {
  testWidgets('password and security key, turned on, open the vault together; the kit brings it back to a password alone', (tester) async {
    final keys = _Keys();
    final blue = SoftKey(pin: '123456');
    final app = TestApp();
    await startApp(tester, app, overrides: keys.overrides);
    await createVault(tester);
    // The vault's Recovery Kit, of one piece
    final kit = makeKit(1, 1);
    await tester.runAsync(
      () => app.vaultStore.setRecoveryKey(
        app.controller.state.session!,
        RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
      ),
    );

    // Settings › How this vault opens › Password and security key
    await _openUnlockMethod(tester);
    await tapOn(tester, find.text(t('unlockMethod.mode.both')));
    await tapOn(tester, find.text(t('unlockMethod.continue.key')));
    await tester.enterText(field(t('unlock.field.password')).last, masterPassword);
    await tapOn(tester, find.widgetWithText(FilledButton, t('unlockMethod.continue')));
    await _giveKey(tester, keys, blue);
    expect(find.text(t('unlockMethod.done.both')), findsOneWidget);
    await tapOn(tester, find.text(t('replaceKey.notNow')));
    keys.takeAway();

    // Locked: the password, then the key
    await _lock(tester, app);
    await submitPassword(tester, masterPassword);
    await tester.pumpAndSettle();
    expect(find.text(t('lock.key.title')), findsNothing);
    expect(field(t('lock.key.pin')), findsOneWidget);
    expect(app.controller.state.phase, VaultPhase.locked);
    await _giveKey(tester, keys, blue);
    await pumpUntil(tester, tab('nav.codes'));
    expect(app.controller.state.isUnlocked, isTrue);

    // Locked again, and the key lost: the kit, and a new password
    keys.takeAway();
    await _lock(tester, app);
    await submitPassword(tester, masterPassword);
    await tester.pumpAndSettle();
    await tapOn(tester, find.text(t('lock.key.lost')));
    await tester.enterText(field(t('recovery.collect.field')), kit.pieces.single);
    await tester.pump();
    await tapOn(tester, find.widgetWithText(FilledButton, t('recovery.collect.add')));
    expect(find.text(t('unlockMethod.recovery.keys')), findsOneWidget);
    await tester.enterText(field(t('changePw.field.new')), 'After-The-Kit-1');
    await tester.enterText(field(t('changePw.field.confirm')), 'After-The-Kit-1');
    await tester.pump();
    await tapOn(tester, find.widgetWithText(FilledButton, t('recovery.unlock.save')));
    await pumpUntil(tester, tab('nav.codes'));

    // It opens with the new password alone, and no key is listed
    await _openUnlockMethod(tester);
    expect(find.text(t('unlockMethod.keys').toUpperCase()), findsNothing);
    await tapOn(tester, find.byIcon(Icons.close_rounded).last);
    await _lock(tester, app);
    await submitPassword(tester, 'After-The-Kit-1');
    await pumpUntil(tester, tab('nav.codes'));
    expect(app.vaultStore.unlockMode(), UnlockMode.password);
    expect(app.vaultStore.enrolledKeys(), isEmpty);
  });

  testWidgets('a key-only vault and a hidden vault needing both on one phone: each opens, and the lock screen stays as it was', (
    tester,
  ) async {
    final keys = _Keys();
    final blue = SoftKey(pin: '123456');
    final green = SoftKey(pin: '654321');
    final app = TestApp();
    late String diary;
    await tester.runAsync(() async {
      final store = app.vaultStore;
      Future<void> keyUp(VaultSession session, String password, SoftKey soft, UnlockMode mode) async {
        await store.setRecoveryKey(
          session,
          RecoveryKey(kitId: 'KIT${soft.pin}', key: makeKit(1, 1).key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
        );
        keys.hold(soft);
        final challenge = store.keyChallenge();
        final enrolment = await keys.reader.enrol(
          pin: pinBytes(soft.pin!),
          salt: challenge.salt,
          exclude: const [],
          prompts: testKeyPrompts,
        );
        final proof = await store.enrolKey(
          session,
          await store.proveOwner(password: password),
          salt: challenge.salt,
          credential: enrolment.credential,
          output: enrolment.output,
          name: 'Key',
          pinBound: enrolment.pinBound,
        );
        await store.setUnlockMode(session, proof, mode);
        keys.takeAway();
      }

      // Personal opens with its key alone
      await keyUp(await store.setupVault(masterPassword), masterPassword, blue, UnlockMode.key);
      // Diary is hidden and needs its password and its key
      diary = await store.createVault('Diary', 'Diary-Horse-4', listed: false);
      await keyUp(await store.unlockAnyVault('Diary-Horse-4', mainVault), 'Diary-Horse-4', green, UnlockMode.both);
      app.vaults.active = mainVault;
    });
    await startApp(tester, app, overrides: keys.overrides);
    final before = _texts(tester);
    expect(find.text(t('lock.key.keyOnlyUnnamed')), findsOneWidget);

    // "Open another vault", the hidden vault's password, its key
    await tapOn(tester, find.text(t('lock.key.another')));
    await submitPassword(tester, 'Diary-Horse-4');
    await tester.pumpAndSettle();
    expect(find.text(t('lock.key.bothHidden')), findsOneWidget);
    expect(find.textContaining('Diary'), findsNothing);
    await _giveKey(tester, keys, green);
    await pumpUntil(tester, tab('nav.codes'));
    expect(app.vaults.active, diary);

    // Locked, the screen is the listed vault's key step, as before
    keys.takeAway();
    await _lock(tester, app);
    expect(_texts(tester), before);

    // And the listed vault opens with its key
    await _giveKey(tester, keys, blue);
    await pumpUntil(tester, tab('nav.codes'));
    expect(app.vaults.active, mainVault);
  });

  testWidgets('a vault needing both exports a file that opens elsewhere with its password alone, and syncs as a password vault does', (
    tester,
  ) async {
    final keys = _Keys();
    final blue = SoftKey(pin: '123456');
    final files = FakeFiles();
    final app = TestApp(now: () => rfcTime);
    await startApp(tester, app, overrides: [...keys.overrides, files.asOverride]);
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', rfcSecret);
    await tester.runAsync(
      () => app.vaultStore.setRecoveryKey(
        app.controller.state.session!,
        RecoveryKey(kitId: 'KITID', key: makeKit(1, 1).key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
      ),
    );
    await _openUnlockMethod(tester);
    await tapOn(tester, find.text(t('unlockMethod.mode.both')));
    await tapOn(tester, find.text(t('unlockMethod.continue.key')));
    await tester.enterText(field(t('unlock.field.password')).last, masterPassword);
    await tapOn(tester, find.widgetWithText(FilledButton, t('unlockMethod.continue')));
    await _giveKey(tester, keys, blue);
    await tapOn(tester, find.text(t('replaceKey.notNow')));
    expect(app.vaultStore.unlockMode(), UnlockMode.both);

    // The export, from Settings, under its own password
    await tapOn(tester, find.text(t('app.menu.export')));
    await tester.enterText(field(t('export.field.password')), _exportPassword);
    await tester.enterText(field(t('export.field.confirm')), _exportPassword);
    await tester.pump();
    await tapOn(tester, find.text(t('export.button')));
    // Before anything leaves the vault, what opens it: its password, then its key
    final dialog = find.byType(OwnerPasswordDialog);
    await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), masterPassword);
    await tester.pump();
    await tapOn(tester, find.descendant(of: dialog, matching: find.text(t('confirmOwner.continue'))));
    await _giveKey(tester, keys, blue);
    await pumpUntil(tester, find.text(t('export.success')));
    expect(dialog, findsNothing);
    await tapOn(tester, find.text(t('export.close')));
    final backup = utf8.decode(files.saved.single.bytes);

    // A sync file of what the vault holds is what a password vault holding the same writes, but for its random
    // values: each file is written from its own vault's storage, sealed under the sync passphrase alone
    final (keyedFile, plainFile, fromKeyed, fromPlain) = (await tester.runAsync(() async {
      final syncKey = await deriveSyncKey('a sync passphrase', newKdf(), derive: fastKdf);
      final keyed = SyncDoc(accounts: await app.vaultStore.loadAccounts(app.controller.state.session!));
      final plain = TestApp(now: () => rfcTime);
      final plainSession = await plain.vaultStore.setupVault('Another-Horse-7');
      await plain.vaultStore.saveAccounts(app.controller.state.accounts, plainSession);
      final other = SyncDoc(accounts: await plain.vaultStore.loadAccounts(plainSession));
      final keyedFile = await encryptSyncFile(keyed, syncKey);
      final plainFile = await encryptSyncFile(other, syncKey);
      return (keyedFile, plainFile, await decryptSyncFile(keyedFile, syncKey), await decryptSyncFile(plainFile, syncKey));
    }))!;
    expect(keyedFile, isNot(plainFile));
    expect(jsonEncode(fromKeyed.toJson()), jsonEncode(fromPlain.toJson()));
    expect(fromKeyed.accounts.single.issuer, 'GitHub');

    // The new phone: the file opens with its password, and no key is asked
    final newFiles = FakeFiles()..nextPick = FakeFiles.text('kemlock-export.json', backup);
    await startApp(tester, TestApp(now: () => rfcTime), overrides: [...keys.overrides, newFiles.asOverride]);
    await createVault(tester, password: 'Another-Horse-7');
    await tapOn(tester, tab('nav.settings'));
    await tapOn(tester, find.text(t('app.menu.import')));
    await tapOn(tester, find.text(t('import.browse')));
    await tester.enterText(field(t('import.field.password')), _exportPassword);
    await tester.pump();
    await tapOn(tester, find.text(t('import.decrypt')));
    final importOne = find.text(t('import.button.merge', {'count': 1}));
    await pumpUntil(tester, importOne);
    await tapOn(tester, importOne);
    expect(find.text(t('lock.key.pin')), findsNothing);
    await tapOn(tester, tab('nav.codes'));
    expect(accountRow('GitHub'), findsOneWidget);
    expect(code(rfcCode), findsOneWidget);
  });
}
