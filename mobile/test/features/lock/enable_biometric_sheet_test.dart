import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/lock/enable_biometric_sheet.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/test_app.dart';
import 'lock_phone.dart';

void main() {
  const androidLabel = 'enableBiometric.platform.android.label';

  /// Opens the vault on [phone] and the sheet over a page.
  Future<VaultSession> open(WidgetTester tester, LockPhone phone) async {
    usePhone(tester);
    final session = await phone.createVault(tester, 'secret');
    await phone.pump(tester, const SheetOpener(showEnableBiometricSheet));
    await phone.controller.open(session);
    await tapOn(tester, find.text('Open'));
    return session;
  }

  testWidgets('offers the phone’s biometrics by their name on Android', (tester) async {
    await open(tester, LockPhone(biometrics: PromptBiometrics()));
    final label = t(androidLabel);

    expect(find.text(t('enableBiometric.unlock', {'label': label})), findsOneWidget);
    expect(find.text(t('enableBiometric.platform.android.hint')), findsOneWidget);
    expect(buttonLabelled(t('enableBiometric.enable', {'label': label})), findsOneWidget);
    expect(find.bySemanticsLabel(t('enableBiometric.unlock', {'label': label})), findsWidgets);
  });

  testWidgets('calls them Face ID or Touch ID on an iPhone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await open(tester, LockPhone(biometrics: PromptBiometrics()));
      final label = t('enableBiometric.platform.ios.label');

      expect(find.text(t('enableBiometric.unlock', {'label': label})), findsOneWidget);
      expect(find.text(t('enableBiometric.platform.ios.hint')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('turns biometric unlock on with one prompt, holding auto-lock meanwhile', (tester) async {
    final phone = LockPhone(biometrics: PromptBiometrics());
    final session = await open(tester, phone);
    final holds = phone.container.read(autoLockHoldsProvider);
    bool? heldDuringPrompt;
    phone.unlockKeys.onPrompt = () => heldDuringPrompt = holds.isHeld;
    final label = t(androidLabel);

    await tapOn(tester, buttonLabelled(t('enableBiometric.enable', {'label': label})));

    // The hardware key's prompt is the only one; local_auth's holds no key
    expect(phone.unlockKeys.prompts, [
      t('enableBiometric.prompt', {'label': label}),
    ]);
    expect(phone.unlockKeys.calls, ['seal main']);
    expect(phone.biometrics.prompts, isEmpty);
    expect(heldDuringPrompt, isTrue);
    expect(holds.isHeld, isFalse);
    expect(phone.vaultStore.hasBiometricUnlock(), isTrue);
    expect(phone.store.getItem('backmycodes_hardware_bio'), isNotNull);
    expect(phone.store.getItem('backmycodes_native_bio'), isNull);
    final opened = await tester.runAsync(() => phone.vaultStore.unlockWithBiometrics('Unlock', phone.biometrics));
    expect(opened!.session!.secretKey, session.secretKey);
    expect(find.text(t('enableBiometric.done.title', {'label': label})), findsOneWidget);
    expect(find.text(t('enableBiometric.done.body', {'label': label})), findsOneWidget);

    await tapOn(tester, buttonLabelled(t('enableBiometric.done')));
    expect(find.text(t('enableBiometric.done.title', {'label': label})), findsNothing);
  });

  testWidgets('leaves it off when the prompt is cancelled', (tester) async {
    final phone = LockPhone(biometrics: PromptBiometrics());
    await open(tester, phone);
    phone.unlockKeys.cancelNext();

    await tapOn(tester, buttonLabelled(t('enableBiometric.enable', {'label': t(androidLabel)})));

    expect(phone.vaultStore.hasBiometricUnlock(), isFalse);
    expect(find.byType(AppAlert), findsNothing);
    expect(isEnabled(tester, t('enableBiometric.enable', {'label': t(androidLabel)})), isTrue);
  });

  testWidgets('shows what went wrong with the prompt', (tester) async {
    final phone = LockPhone(biometrics: PromptBiometrics());
    await open(tester, phone);
    phone.unlockKeys.failNext('Biometrics are locked out.');

    await tapOn(tester, buttonLabelled(t('enableBiometric.enable', {'label': t(androidLabel)})));

    expect(find.text('Biometrics are locked out.'), findsOneWidget);
    expect(phone.vaultStore.hasBiometricUnlock(), isFalse);

    await tapOn(tester, find.bySemanticsLabel(t('passkey.close')));
    expect(find.text('Biometrics are locked out.'), findsNothing);
  });

  testWidgets('fails plainly when the phone has no biometrics the key can use', (tester) async {
    // local_auth would offer a weak face unlock, but the hardware key needs Class 3
    final phone = LockPhone(biometrics: PromptBiometrics(), unlockKeys: FakeUnlockKeys(available: false));
    await open(tester, phone);

    await tapOn(tester, buttonLabelled(t('enableBiometric.enable', {'label': t(androidLabel)})));

    expect(find.text(t('enableBiometric.error')), findsOneWidget);
    expect(phone.unlockKeys.prompts, isEmpty);
    expect(phone.biometrics.prompts, isEmpty);
    expect(phone.vaultStore.hasBiometricUnlock(), isFalse);
  });

  testWidgets('can be put off', (tester) async {
    final phone = LockPhone(biometrics: PromptBiometrics());
    await open(tester, phone);

    await tapOn(tester, buttonLabelled(t('enableBiometric.notNow')));

    expect(find.text(t('enableBiometric.platform.android.hint')), findsNothing);
    expect(phone.biometrics.prompts, isEmpty);
    expect(phone.vaultStore.hasBiometricUnlock(), isFalse);
  });
}
