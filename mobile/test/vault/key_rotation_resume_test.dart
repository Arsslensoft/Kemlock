import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/crashing_store.dart';
import 'rotation_helpers.dart';

class _NoFallback implements Biometrics {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// A replacement of the vault's key pair cut short is finished, or undone,
/// at the next unlock (openspec: replace-vault-key-pair, task 2.5).
void main() {
  late CrashingStore died;
  late Phone phone;

  setUp(() {
    died = CrashingStore();
    phone = Phone(died);
  });

  /// Runs [replace] on the phone until the write [after] the ones made so far dies.
  Future<void> killAt(int after, Future<void> Function() replace) async {
    died.diesAt = died.writes + after;
    await expectLater(replace(), throwsA(isA<StoreDied>()));
  }

  Future<void> expectSealedTo(Phone phone, VaultSession session, {required VaultSession not}) async {
    for (final key in phone.vault.sealedValueKeys(phone.vaults.active)) {
      final raw = phone.store.getItem(key)!;
      await openRaw(raw, session.secretKey);
      await expectLater(openRaw(raw, not.secretKey), throwsA(isA<AesGcmAuthError>()), reason: key);
    }
  }

  test('a password unlock finishes a replacement cut short after its commit', () async {
    final old = await phone.vault.setupVault('pw');
    await fillVault(phone.vault, phone.store, keyFuture, old);
    // The replacement's value, the config, one value sealed again, and then the app dies
    await killAt(4, () => phone.vault.replaceKeyPair(old, 'pw'));

    final next = Phone(died.reopen());
    expect(next.store.getItem(keyKeyRotation), isNotNull);
    final session = await next.vault.unlockAnyVault('pw', mainVault);

    expect(next.store.getItem(keyKeyRotation), isNull);
    expect(session.secretKey, isNot(old.secretKey));
    await expectEveryItem(next.vault, session);
    await expectSealedTo(next, session, not: old);
  });

  test('a Recovery Kit unlock finishes it too, with the new kit', () async {
    final old = await phone.vault.setupVault('pw');
    await fillVault(phone.vault, phone.store, keyFuture, old);
    final oldKit = newKit();
    await phone.vault.setRecoveryKey(old, oldKit);
    final kit = newKit();
    await killAt(4, () => phone.vault.replaceKeyPair(old, 'pw', kit: kit));

    final next = Phone(died.reopen());
    await expectLater(next.vault.unlockWithRecoveryKey(oldKit.kitId, oldKit.key), throwsA(isA<KitNotFoundError>()));
    final session = await next.vault.unlockWithRecoveryKey(kit.kitId, kit.key);

    expect(next.store.getItem(keyKeyRotation), isNull);
    await expectEveryItem(next.vault, session);
    await expectSealedTo(next, session, not: old);
  });

  test('a replacement cut short before its commit leaves the vault as it was, and its value goes', () async {
    final old = await phone.vault.setupVault('pw');
    await fillVault(phone.vault, phone.store, keyFuture, old);
    final oldKit = newKit();
    await phone.vault.setRecoveryKey(old, oldKit);
    final before = phone.snapshot;
    // The replacement's value is written; the config never is
    await killAt(2, () => phone.vault.replaceKeyPair(old, 'pw', kit: newKit()));

    final next = Phone(died.reopen());
    expect(next.store.getItem(keyKeyRotation), isNotNull);
    final session = await next.vault.unlockAnyVault('pw', mainVault);

    expect(session.secretKey, old.secretKey);
    expect(next.snapshot, before);
    await expectEveryItem(next.vault, session);
    expect((await next.vault.unlockWithRecoveryKey(oldKit.kitId, oldKit.key)).secretKey, old.secretKey);
  });

  test('a Recovery Kit unlock deletes a stale replacement value too', () async {
    final old = await phone.vault.setupVault('pw');
    final oldKit = newKit();
    await phone.vault.setRecoveryKey(old, oldKit);
    await killAt(2, () => phone.vault.replaceKeyPair(old, 'pw', dropKit: true));

    final next = Phone(died.reopen());
    await next.vault.unlockWithRecoveryKey(oldKit.kitId, oldKit.key);

    expect(next.store.getItem(keyKeyRotation), isNull);
  });

  test('finishes the replacement of the hidden vault that opened, and leaves the listed one alone', () async {
    final first = await phone.vault.setupVault('first');
    await fillVault(phone.vault, phone.store, keyFuture, first);
    final diary = await phone.vault.createVault('Diary', 'diary', listed: false);
    final diarySession = await phone.vault.unlockAnyVault('diary', mainVault);
    await fillVault(phone.vault, phone.store, phone.vaults.vaultKey(keyFuture), diarySession);
    final listedBefore = {for (final key in phone.vaults.keysOf(mainVault)) key: phone.store.getItem(key)};
    await killAt(4, () => phone.vault.replaceKeyPair(diarySession, 'diary'));

    final next = Phone(died.reopen());
    final session = await next.vault.unlockAnyVault('diary', mainVault);

    expect(next.vaults.active, diary);
    expect(next.store.getItem(next.vaults.vaultKey(keyKeyRotation, diary)), isNull);
    await expectEveryItem(next.vault, session);
    expect({for (final key in next.vaults.keysOf(mainVault)) key: next.store.getItem(key)}, listedBefore);
  });

  test('a vault with no replacement under way opens by password, kit or biometrics without a write', () async {
    final old = await phone.vault.setupVault('pw');
    await fillVault(phone.vault, phone.store, keyFuture, old);
    final kit = newKit();
    await phone.vault.setRecoveryKey(old, kit);
    await phone.vault.enableBiometricUnlock(old, 'Unlock');
    // Any write from here on dies
    died.diesAt = died.writes + 1;

    await phone.vault.unlockAnyVault('pw', mainVault);
    await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
    final biometric = await phone.vault.unlockWithBiometrics('Unlock', _NoFallback());

    expect(biometric.outcome, BiometricOutcome.opened);
    expect(died.dead, isFalse);
  });
}
