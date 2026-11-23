import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/lock/change_password_sheet.dart';
import 'package:kemlock/features/lock/enable_biometric_sheet.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/lock/setup_screen.dart';
import 'package:kemlock/platform/shared_items.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../fakes/fake_shared_items.dart';
import '../features/lock/lock_phone.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';
import '../vault/rotation_helpers.dart' show newKit;

/// A biometric prompt that stays up.
/// Renders setup, the lock screen, biometric unlock and changing the
/// password, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/lock_test.dart
void main() {
  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextField, label), text);
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> submitPassword(WidgetTester tester, String password) async {
    await tester.enterText(find.widgetWithText(TextField, t('unlock.field.password')), password);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> pressCreate(WidgetTester tester) async {
    await tester.ensureVisible(buttonLabelled(t('setup.button')));
    await tester.pump();
    await tester.tap(buttonLabelled(t('setup.button')));
    await tester.pump();
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('setup: the form, $name', (tester) async {
      usePhoneScreen(tester);
      await LockPhone().pump(tester, const SetupScreen(), brightness: brightness, reducedMotion: false);
      await type(tester, t('setup.field.password'), 'Correct-Horse');
      await type(tester, t('setup.field.confirm'), 'Correct-Horse');
      await takeScreenshot(tester, 'lock_setup_form_$name');
    });

    testScreenshot('setup: a weak password that does not match, $name', (tester) async {
      usePhoneScreen(tester);
      await LockPhone().pump(tester, const SetupScreen(), brightness: brightness, reducedMotion: false);
      await type(tester, t('setup.field.password'), 'hunter2');
      await type(tester, t('setup.field.confirm'), 'hunter3');
      await takeScreenshot(tester, 'lock_setup_weak_$name');
    });

    testScreenshot('setup: making the vault, $name', (tester) async {
      usePhoneScreen(tester);
      await LockPhone().pump(tester, const SetupScreen(), brightness: brightness, reducedMotion: false);
      await type(tester, t('setup.field.password'), 'Correct-Horse-9');
      await type(tester, t('setup.field.confirm'), 'Correct-Horse-9');
      await pressCreate(tester);
      // The first step is done and the key pair is being made
      await tester.pump(const Duration(milliseconds: 360));
      await tester.pump(const Duration(milliseconds: 250));
      await captureScreenshot('lock_setup_forging_$name');
      await tester.pump(const Duration(seconds: 3));
    });

    testScreenshot('setup: the vault is ready, $name', (tester) async {
      usePhoneScreen(tester);
      await LockPhone().pump(tester, const SetupScreen(), brightness: brightness, reducedMotion: false);
      await type(tester, t('setup.field.password'), 'Correct-Horse-9');
      await type(tester, t('setup.field.confirm'), 'Correct-Horse-9');
      await pressCreate(tester);
      await tester.pump(const Duration(milliseconds: 350 + 3 * 280 + 50));
      await tester.pump(const Duration(milliseconds: 600));
      await captureScreenshot('lock_setup_ready_$name');
      await tester.pump(const Duration(seconds: 2));
    });

    testScreenshot('lock: the password, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await phone.pump(tester, const LockScreen(), brightness: brightness, reducedMotion: false);
      await takeScreenshot(tester, 'lock_password_$name');
    });

    testScreenshot('lock: a shared item waiting, $name', (tester) async {
      usePhoneScreen(tester);
      final shared = FakeSharedItems();
      final phone = LockPhone(extra: [shared.asOverride]);
      await phone.createVault(tester, 'secret');
      await phone.pump(tester, const LockScreen(), brightness: brightness, reducedMotion: false);
      shared.send(const SharedText('Meet me at the usual place at nine.'));
      await takeScreenshot(tester, 'lock_shared_waiting_$name');
      // Its timer would outlive the test
      phone.container.read(pendingShareProvider.notifier).drop();
    });

    testScreenshot('lock: several vaults after three wrong passwords, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone();
      await phone.createVault(tester, 'secret');
      await phone.addVault(tester, 'Work', 'work-secret');
      await phone.addVault(tester, 'Family', 'family-secret');
      await phone.pump(tester, const LockScreen(), brightness: brightness, reducedMotion: false);
      for (var i = 0; i < 3; i++) {
        await submitPassword(tester, 'wrong');
      }
      await takeScreenshot(tester, 'lock_vaults_error_$name');
    });

    testScreenshot('lock: biometric unlock, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await phone.enableBiometrics(tester, session);
      phone.unlockKeys.cancelNext();
      await phone.pump(tester, const LockScreen(), brightness: brightness, reducedMotion: false);
      await settleForScreenshot(tester);
      // Between the halos' starts, so both rings show
      await tester.pump(const Duration(milliseconds: 1900));
      await captureScreenshot('lock_biometric_$name');
    });

    testScreenshot('sheets: enable biometric unlock, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone(biometrics: PromptBiometrics());
      final session = await phone.createVault(tester, 'secret');
      await phone.pump(tester, const SheetOpener(showEnableBiometricSheet), brightness: brightness, reducedMotion: false);
      await phone.controller.open(session);
      await tester.tap(find.text('Open'));
      await takeScreenshot(tester, 'lock_enable_biometric_$name');
    });

    testScreenshot('sheets: change the password, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone();
      final session = await phone.createVault(tester, 'secret');
      await phone.pump(tester, const SheetOpener(showChangePasswordSheet), brightness: brightness, reducedMotion: false);
      await phone.controller.open(session);
      await tester.tap(find.text('Open'));
      await settleForScreenshot(tester);
      await type(tester, t('changePw.field.current'), 'secret');
      await type(tester, t('changePw.field.new'), 'a-new-secret');
      await type(tester, t('changePw.field.confirm'), 'a-new-secre');
      await takeScreenshot(tester, 'lock_change_password_$name');
    });
  }

  testScreenshot('lock: waiting for the biometric prompt, dark', (tester) async {
    usePhoneScreen(tester);
    final phone = LockPhone(biometrics: PromptBiometrics());
    final session = await phone.createVault(tester, 'secret');
    await phone.enableBiometrics(tester, session);
    phone.unlockKeys.promptWaits = Completer<void>().future;
    await phone.pump(tester, const LockScreen(), reducedMotion: false);
    await takeScreenshot(tester, 'lock_biometric_waiting_dark');
  });

  testScreenshot('lock: opening, light', (tester) async {
    usePhoneScreen(tester);
    final phone = LockPhone();
    await phone.createVault(tester, 'secret');
    await phone.pump(tester, const LockScreen(), brightness: Brightness.light, reducedMotion: false);
    await settleForScreenshot(tester);
    await submitPassword(tester, 'secret');
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot('lock_opening_light');
  });

  testScreenshot('sheets: biometric unlock enabled, dark', (tester) async {
    usePhoneScreen(tester);
    final phone = LockPhone(biometrics: PromptBiometrics());
    final session = await phone.createVault(tester, 'secret');
    await phone.pump(tester, const SheetOpener(showEnableBiometricSheet), reducedMotion: false);
    await phone.controller.open(session);
    await tester.tap(find.text('Open'));
    await settleForScreenshot(tester);
    await tester.tap(buttonLabelled(t('enableBiometric.enable', {'label': t('enableBiometric.platform.android.label')})));
    await takeScreenshot(tester, 'lock_enable_biometric_done_dark');
  });

  testScreenshot('sheets: biometric unlock failed, light', (tester) async {
    usePhoneScreen(tester);
    final phone = LockPhone(biometrics: PromptBiometrics());
    phone.unlockKeys.failNext('Too many attempts. Biometric sensor disabled.');
    final session = await phone.createVault(tester, 'secret');
    await phone.pump(tester, const SheetOpener(showEnableBiometricSheet), brightness: Brightness.light, reducedMotion: false);
    await phone.controller.open(session);
    await tester.tap(find.text('Open'));
    await settleForScreenshot(tester);
    await tester.tap(buttonLabelled(t('enableBiometric.enable', {'label': t('enableBiometric.platform.android.label')})));
    await takeScreenshot(tester, 'lock_enable_biometric_error_light');
  });

  // openspec: add-security-key-unlock, task 5.7
  /// The first vault, "Personal", password "secret", with a kit and one key
  /// enrolled, set to open in [mode]. No key is needed: the store takes
  /// what one gave.
  Future<void> keyed(WidgetTester tester, LockPhone phone, UnlockMode mode) async {
    final session = await phone.createVault(tester, 'secret');
    phone.vaultStore.renameVault(mainVault, 'Personal');
    await tester.runAsync(() async {
      final store = phone.vaultStore;
      await store.setRecoveryKey(session, newKit());
      final proof = await store.enrolKey(
        session,
        await store.proveOwner(password: 'secret'),
        salt: store.keyChallenge().salt,
        credential: randomBytes(64),
        output: randomBytes(32),
        name: 'Example Key',
        pinBound: true,
      );
      await store.setUnlockMode(session, proof, mode);
    });
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('lock: the key step after the password, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone();
      await keyed(tester, phone, UnlockMode.both);
      await phone.pump(tester, const LockScreen(), brightness: brightness, reducedMotion: false);
      await submitPassword(tester, 'secret');
      await tester.enterText(find.widgetWithText(TextField, t('lock.key.pin')), '123456');
      await takeScreenshot(tester, 'lock_key_step_$name');
    });

    testScreenshot('lock: a vault that opens with its key, $name', (tester) async {
      usePhoneScreen(tester);
      final phone = LockPhone();
      await keyed(tester, phone, UnlockMode.key);
      await phone.pump(tester, const LockScreen(), brightness: brightness, reducedMotion: false);
      await takeScreenshot(tester, 'lock_key_only_$name');
    });
  }
}
