import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/lock/unlock_attempts.dart';
import 'package:kemlock/features/settings/vaults_sheet.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/old_biometric_entry.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../../vault/rotation_helpers.dart' show newKit;

/// A phone with one vault, its password "first password", and the sheet
/// open over a page, as Settings opens it.
class _Phone {
  final store = KeyValueStore.memory();
  late final vaults = VaultRegistry(store);
  final keys = FakeUnlockKeys();
  late final vaultStore = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys);
  late ProviderContainer container;

  Future<void> open(WidgetTester tester, {Future<void> Function()? before}) async {
    // A phone, tall enough for the whole form under the sheet's handle
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await vaultStore.setupVault('first password');
      await before?.call();
    });
    container = await pumpScreen(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(onPressed: () => showVaultsSheet(context), child: const Text('Open')),
          ),
        ),
      ),
      store: store,
      overrides: [vaultRegistryProvider.overrideWithValue(vaults), vaultStoreProvider.overrideWithValue(vaultStore)],
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  VaultState get state => container.read(vaultControllerProvider);
}

Finder _field(String label) => find.widgetWithText(TextField, label);

/// Opens the new vault's form and fills it in.
Future<void> _fillNewVault(WidgetTester tester, String name, String password, {String? confirm}) async {
  await tester.tap(find.text(t('vaults.new')));
  await tester.pumpAndSettle();
  await tester.enterText(_field(t('vaults.field.name')), name);
  await tester.enterText(_field(t('setup.field.password')), password);
  await tester.enterText(_field(t('setup.field.confirm')), confirm ?? password);
  await tester.pump();
}

Future<void> _create(WidgetTester tester) async {
  await tester.tap(find.text(t('vaults.new.create')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('adds a vault that the lock screen lists', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Work', 'work password');
    await _create(tester);

    expect(phone.vaults.listedVaultIds(), hasLength(2));
    final work = phone.vaults.listedVaultIds()[1];
    expect(phone.vaults.vaultName(work), 'Work');
    expect(find.text(t('vaults.created', {'name': 'Work'})), findsOneWidget);
    // Back on the list, with the new vault to switch to
    expect(find.text(t('vaults.title')), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    await tester.runAsync(() => phone.vaultStore.unlockAnyVault('work password', work));
  });

  testWidgets('adds a hidden vault', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Diary', 'diary password');
    await tester.tap(find.text(t('vaults.new.hide')));
    await tester.pump();
    expect(find.text(t('vaults.new.hideHint')), findsOneWidget);
    await _create(tester);

    expect(phone.vaults.hiddenVaultIds(), hasLength(1));
    expect(phone.vaults.listedVaultIds(), [mainVault]);
    expect(find.text(t('vaults.created.hidden', {'name': 'Diary'})), findsOneWidget);
  });

  testWidgets('refuses a password another vault uses', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Work', 'first password');
    await _create(tester);

    expect(find.text(t('vaults.error.passwordInUse')), findsOneWidget);
    expect(phone.vaults.allVaultIds(), [mainVault]);
  });

  group('whether a password opens a vault already, which says so of a hidden one too', () {
    UnlockFailures count(_Phone phone) => UnlockFailures.parse(phone.store.getItem('backmycodes_unlock_failures'));

    testWidgets('is counted as a try on the lock screen when it does, and given back when it made the vault', (tester) async {
      final phone = _Phone();
      await phone.open(tester);
      final states = <VaultPhase>[];
      phone.container.listen(vaultControllerProvider, (_, next) => states.add(next.phase));

      await _fillNewVault(tester, 'Work', 'first password');
      await _create(tester);
      expect(find.text(t('vaults.error.passwordInUse')), findsOneWidget);
      expect(count(phone).count, 1);

      await tester.enterText(_field(t('setup.field.password')), 'work password');
      await tester.enterText(_field(t('setup.field.confirm')), 'work password');
      await tester.pump();
      await _create(tester);

      expect(phone.vaults.allVaultIds(), hasLength(2));
      expect(count(phone).count, 1, reason: 'the password that made the vault is given back');
      expect(states, isNot(contains(VaultPhase.locked)), reason: 'far from the erase, nothing locks');
    });

    testWidgets('locks the vault once the count reaches the erase, for the lock screen to erase every vault', (tester) async {
      final phone = _Phone();
      await phone.open(tester);
      writeUnlockErase(phone.store, 10);
      phone.store.setItem('backmycodes_unlock_failures', '{"count":9}');
      final states = <VaultPhase>[];
      phone.container.listen(vaultControllerProvider, (_, next) => states.add(next.phase));

      await _fillNewVault(tester, 'Work', 'first password');
      await _create(tester);

      expect(count(phone).count, 10);
      expect(states, [VaultPhase.locked]);
    });
  });

  testWidgets('keeps the new vault’s password from the phone’s password manager and the keyboard’s learning', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Work', 'a long new password');

    for (final label in [t('setup.field.password'), t('setup.field.confirm')]) {
      final field = tester.widget<TextField>(_field(label));
      // Null keeps it out of autofill, which the empty default doesn't
      expect(field.autofillHints, isNull, reason: label);
      expect(field.enableIMEPersonalizedLearning, isFalse, reason: label);
    }
  });

  testWidgets('asks for a password of twelve characters or more', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Work', 'eleven-char');
    await _create(tester);

    expect(find.text(t('changePw.error.tooShort')), findsOneWidget);
    expect(phone.vaults.allVaultIds(), [mainVault]);
  });

  testWidgets('waits for the passwords to match', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Work', 'work password', confirm: 'work passwrd');

    expect(find.text(t('setup.field.mismatch')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('vaults.new.create'))).onPressed, isNull);
  });

  testWidgets('goes back to the list on cancel', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await _fillNewVault(tester, 'Work', 'work password');
    await tester.tap(find.text(t('changePw.cancel')));
    await tester.pumpAndSettle();

    expect(find.text(t('vaults.body')), findsOneWidget);
    expect(_field(t('vaults.field.name')), findsNothing);
    expect(phone.vaults.allVaultIds(), [mainVault]);
  });

  testWidgets('renames the open vault and can hide it from the lock screen', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await tester.enterText(_field(t('vaults.field.thisName')), 'Personal');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(phone.vaults.vaultName(mainVault), 'Personal');
    expect(phone.state.vault.name, 'Personal');

    await tester.tap(find.text(t('vaults.showOnLock')));
    await tester.pump();
    expect(phone.vaults.isListed(mainVault), isFalse);
    expect(find.text(t('vaults.hidden.alone')), findsOneWidget);
    expect(phone.state.vault.hidden, isTrue);
  });

  testWidgets('hiding a vault turns its biometric unlock off: both entries and the hardware key go', (tester) async {
    final phone = _Phone();
    await phone.open(
      tester,
      before: () async {
        final session = await phone.vaultStore.unlockVault('first password');
        await phone.vaultStore.enableBiometricUnlock(session, 'Turn it on');
        await writeOldBiometricEntry(phone.store, phone.vaults, session);
      },
    );
    expect(phone.vaultStore.hasBiometricUnlock(), isTrue);

    await tester.tap(find.text(t('vaults.showOnLock')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(phone.vaults.isListed(mainVault), isFalse);
    expect(phone.store.getItem('backmycodes_hardware_bio'), isNull);
    expect(phone.store.getItem('backmycodes_native_bio'), isNull);
    expect(phone.keys.keys, isEmpty);
    expect(phone.vaultStore.hasBiometricUnlock(), isFalse);
  });

  testWidgets('keeps a name typed just before the sheet closes', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await tester.enterText(_field(t('vaults.field.thisName')), 'Personal');
    await tester.tap(find.text(t('export.close')));
    await tester.pumpAndSettle();

    expect(find.byType(VaultsSheet), findsNothing);
    expect(phone.vaults.vaultName(mainVault), 'Personal');
  });

  testWidgets('switches to another listed vault by locking', (tester) async {
    final phone = _Phone();
    late String work;
    await phone.open(tester, before: () async => work = await phone.vaultStore.createVault('Work', 'work password', listed: true));

    expect(find.text(t('vaults.switchHint')), findsOneWidget);
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    expect(find.byType(VaultsSheet), findsNothing);
    expect(phone.vaults.active, work);
    expect(phone.state.phase, VaultPhase.locked);
  });

  testWidgets('deletes the open vault after a confirmation', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await tester.tap(find.text(t('vaults.delete')));
    await tester.pumpAndSettle();
    expect(find.text(t('vaults.delete.title', {'name': t('vaults.defaultName')})), findsOneWidget);
    await tester.tap(find.text(t('vaults.delete.confirm')));
    await tester.pumpAndSettle();

    expect(find.byType(VaultsSheet), findsNothing);
    expect(phone.vaults.allVaultIds(), isEmpty);
    expect(phone.state.phase, VaultPhase.setup);
  });

  testWidgets('keeps the vault when the deletion is cancelled', (tester) async {
    final phone = _Phone();
    await phone.open(tester);

    await tester.tap(find.text(t('vaults.delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('changePw.cancel')));
    await tester.pumpAndSettle();

    expect(find.byType(VaultsSheet), findsOneWidget);
    expect(phone.vaults.allVaultIds(), [mainVault]);
  });

  // openspec: add-security-key-unlock, task 6.8
  testWidgets('refuses to hide a vault that opens with a key alone, and says to give it a password first', (tester) async {
    final phone = _Phone();
    await phone.open(
      tester,
      before: () async {
        final store = phone.vaultStore;
        final session = await store.unlockVault('first password');
        await store.setRecoveryKey(session, newKit());
        final proof = await store.enrolKey(
          session,
          await store.proveOwner(password: 'first password'),
          salt: store.keyChallenge().salt,
          credential: randomBytes(64),
          output: randomBytes(32),
          name: 'Example Key',
          pinBound: true,
        );
        await store.setUnlockMode(session, proof, UnlockMode.key);
      },
    );

    await tester.tap(find.text(t('vaults.showOnLock')));
    await tester.pump();

    expect(find.text(t('unlockMethod.hideKeyOnly')), findsOneWidget);
    expect(phone.vaults.isListed(mainVault), isTrue);
    expect(phone.state.vault.hidden, isFalse);
  });
}
