import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/lock/replace_key_sheet.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../features/lock/lock_phone.dart' show buttonLabelled;
import '../helpers/app_harness.dart';
import '../helpers/old_biometric_entry.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

const _account = OtpAccount(id: 'a1', issuer: 'ACME', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

class _NoFallback implements Biometrics {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// Replacing an exposed vault's key, through the real router (openspec:
/// replace-vault-key-pair, task 6.5): a vault from before this version, with
/// a 2-of-3 Recovery Kit and the biometric entry that kept its key in the
/// app's storage, on a phone with the hardware keys faked.
void main() {
  testWidgets('an exposed vault is offered a new key, gets one with a new kit, and biometric unlock again', (tester) async {
    final app = TestApp(biometrics: FakeBiometrics());
    late VaultSession old;
    await tester.runAsync(() async {
      old = await app.createVault(masterPassword);
      await app.vaultStore.saveAccounts([_account], old);
      await app.vaultStore.setRecoveryKey(
        old,
        RecoveryKey(kitId: 'OLDKT', key: randomBytes(32), threshold: 2, shares: 3, createdAt: '2026-01-01T00:00:00.000Z'),
      );
      await writeOldBiometricEntry(app.store, app.vaults, old);
      // As an older version left it: nothing known about the key pair
      app.store.removeItem(keyKeyInfo);
    });
    app.store.setItem('backmycodes_locale', 'en');

    // The lock screen's automatic prompt moves the old entry to the hardware and opens the vault
    await startApp(tester, app);
    await pumpUntil(tester, find.byType(ReplaceKeySheet));
    expect(find.text(t('replaceKey.exposed')), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byType(ReplaceKeySheet), matching: find.byType(TextField)), masterPassword);
    await tester.pump();
    await tapOn(tester, find.text(t('replaceKey.continue')));
    await tapOn(tester, find.text(t('replaceKey.kit.make')));
    expect(find.text(t('recovery.kit.pieces.people', {'needed': 2, 'total': 3})), findsOneWidget);
    await tapOn(tester, find.text(t('recovery.kit.replacement.saved')));
    await tapOn(tester, find.text(t('recovery.kit.replacement.use')));

    // Biometric unlock went with the old key, and is offered again
    final label = t('enableBiometric.platform.android.label');
    await pumpUntil(tester, buttonLabelled(t('enableBiometric.enable', {'label': label})));
    expect(app.vaultStore.hasBiometricUnlock(), isFalse);
    await tapOn(tester, buttonLabelled(t('enableBiometric.enable', {'label': label})));
    // Its Done, over the last screen's
    await tapOn(tester, buttonLabelled(t('enableBiometric.done')).last);

    // The last screen lists what the vault has
    expect(find.text(t('replaceKey.done.title')), findsOneWidget);
    expect(find.text(t('replaceKey.done.codes')), findsOneWidget);
    expect(find.text(t('replaceKey.done.backupCodes')), findsNothing);
    await tapOn(tester, buttonLabelled(t('enableBiometric.done')));
    expect(find.byType(ReplaceKeySheet), findsNothing);

    // The new kit and key pair are the vault's; the old kit opens nothing
    final kit = app.vaultStore.recoveryKitInfo()!;
    expect((kit.threshold, kit.shares, kit.kitId == 'OLDKT'), (2, 3, false));
    expect(app.store.getItem(keyKeyRotation), isNull);
    expect(app.store.getItem(keyNativeBio), isNull);
    await goTo(tester, app, '/settings');
    expect(find.text(t('settings.health.key')), findsNothing);

    // Biometric unlock is on again, with the new key pair
    final session = app.container.read(vaultControllerProvider).session!;
    expect(session.secretKey, isNot(old.secretKey));
    final unlock = (await tester.runAsync(() => app.vaultStore.unlockWithBiometrics('Unlock', _NoFallback())))!;
    expect(unlock.outcome, BiometricOutcome.opened);
    expect(unlock.session!.secretKey, session.secretKey);
    expect(await tester.runAsync(() => app.vaultStore.loadAccounts(session)), [_account]);
    expect(app.vaults.allVaultIds(), [mainVault]);
  });
}
