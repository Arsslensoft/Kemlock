import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/vault/owner_check.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../helpers/old_biometric_entry.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../lock/lock_phone.dart';

const _reason = 'Confirm it’s you to export the vault';

/// The open vault, whose locks the test counts; [reopen] opens it again
/// with a new session, as an unlock does.
class _OpenVault extends VaultController {
  _OpenVault(this._session);

  final VaultSession _session;
  var locks = 0;

  @override
  VaultState build() => VaultState(
    phase: VaultPhase.unlocked,
    session: _session,
    vault: const VaultInfo(id: 'test'),
  );

  @override
  void lock() {
    locks++;
    state = VaultState(phase: VaultPhase.locked, vault: state.vault);
  }

  void reopen(VaultSession session) => state = VaultState(phase: VaultPhase.unlocked, session: session, vault: state.vault);
}

void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vaultStore;
  late PromptBiometrics biometrics;
  late VaultSession session;

  /// What each check answered, in order.
  late List<bool> answers;

  setUp(() async {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = VaultStore(store, vaults, deriveKey: fastKdf);
    biometrics = PromptBiometrics();
    session = await vaultStore.setupVault('the master password');
    answers = [];
  });

  /// A page whose one button runs the check, with the vault set up above,
  /// open in [vault] when given.
  Future<void> pump(WidgetTester tester, {VaultController? vault}) => pumpScreen(
    tester,
    Scaffold(
      body: Center(
        child: Consumer(
          builder: (context, ref, _) =>
              TextButton(onPressed: () => unawaited(checkOwner(context, ref, _reason).then(answers.add)), child: const Text('Export')),
        ),
      ),
    ),
    store: store,
    overrides: [
      vaultRegistryProvider.overrideWithValue(vaults),
      vaultStoreProvider.overrideWithValue(vaultStore),
      biometricsProvider.overrideWithValue(biometrics),
      if (vault != null) vaultControllerProvider.overrideWith(() => vault),
    ],
  );

  Future<void> ask(WidgetTester tester) async {
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
  }

  Finder passwordField() => find.widgetWithText(TextField, t('unlock.field.password'));

  Future<void> typePassword(WidgetTester tester, String password) async {
    await tester.enterText(passwordField(), password);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('confirmOwner.continue')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  group('a vault that opens with biometrics', () {
    setUp(() => writeOldBiometricEntry(store, vaults, session));

    testWidgets('asks for them, with the reason, and takes their answer', (tester) async {
      await pump(tester);

      await ask(tester);
      biometrics.passes = false;
      await ask(tester);

      expect(biometrics.prompts, [_reason, _reason]);
      expect(answers, [true, false]);
      // Refusing the prompt is a no, not a way round it
      expect(passwordField(), findsNothing);
    });

    testWidgets('asks for the master password when the prompt can’t run', (tester) async {
      biometrics.error = const BiometricError('Too many attempts');
      await pump(tester);

      await ask(tester);
      expect(passwordField(), findsOneWidget);
      await typePassword(tester, 'the master password');

      expect(answers, [true]);
    });
  });

  group('a vault without biometric unlock', () {
    testWidgets('asks for its master password, and a wrong one stays in the dialog', (tester) async {
      await pump(tester);

      await ask(tester);
      expect(biometrics.prompts, isEmpty);
      expect(find.text(_reason), findsOneWidget);
      expect(find.text(t('confirmOwner.body')), findsOneWidget);
      await typePassword(tester, 'not the password');
      expect(find.text(t('confirmOwner.wrong')), findsOneWidget);
      expect(answers, isEmpty);

      await typePassword(tester, 'the master password');
      expect(passwordField(), findsNothing);
      expect(answers, [true]);
    });

    testWidgets('a cancelled dialog is a no', (tester) async {
      await pump(tester);

      await ask(tester);
      await tester.tap(find.text(t('export.cancel')));
      await tester.pumpAndSettle();

      expect(answers, [false]);
    });

    testWidgets('the password of another vault on the phone is a wrong one', (tester) async {
      await vaultStore.setupVault('another vault’s password', id: 'other');
      expect(vaults.active, isNot('other'));
      await pump(tester);

      await ask(tester);
      await typePassword(tester, 'another vault’s password');

      expect(find.text(t('confirmOwner.wrong')), findsOneWidget);
      expect(answers, isEmpty);
    });
  });

  group('three wrong master passwords in a row', () {
    Future<void> cancel(WidgetTester tester) async {
      await tester.tap(find.text(t('export.cancel')));
      await tester.pumpAndSettle();
    }

    testWidgets('lock the vault, counted from one dialog to the next, and say so before the last', (tester) async {
      final vault = _OpenVault(session);
      await pump(tester, vault: vault);

      await ask(tester);
      await typePassword(tester, 'wrong once');
      expect(find.text(t('confirmOwner.wrong')), findsOneWidget);
      expect(find.text(t('confirmOwner.lastTry')), findsNothing);
      await typePassword(tester, 'wrong twice');
      expect(find.text(t('confirmOwner.lastTry')), findsOneWidget);
      // Closing the dialog doesn't start the count again
      await cancel(tester);
      expect(vault.locks, 0);

      await ask(tester);
      expect(find.text(t('confirmOwner.lastTry')), findsOneWidget);
      await typePassword(tester, 'wrong a third time');

      // Any further guess goes through the lock screen, which counts it
      expect(vault.locks, 1);
      expect(passwordField(), findsNothing);
      expect(answers, [false, false]);
    });

    testWidgets('start again after a right one, and when the vault opens again', (tester) async {
      final vault = _OpenVault(session);
      await pump(tester, vault: vault);

      await ask(tester);
      await typePassword(tester, 'wrong once');
      await typePassword(tester, 'wrong twice');
      await typePassword(tester, 'the master password');
      expect(answers, [true]);

      await ask(tester);
      expect(find.text(t('confirmOwner.lastTry')), findsNothing);
      await typePassword(tester, 'wrong once');
      await typePassword(tester, 'wrong twice');
      await cancel(tester);
      // Locked and opened again elsewhere, by the lock screen: a new session
      vault.reopen(VaultSession(publicKey: session.publicKey, secretKey: session.secretKey));
      await tester.pump();

      await ask(tester);
      expect(find.text(t('confirmOwner.lastTry')), findsNothing);
      await typePassword(tester, 'wrong once');

      expect(find.text(t('confirmOwner.wrong')), findsOneWidget);
      expect(vault.locks, 0);
      expect(answers, [true, false]);
    });
  });
}
