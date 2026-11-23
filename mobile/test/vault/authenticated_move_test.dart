import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/scrypt.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/crashing_store.dart';
import '../fakes/fake_unlock_keys.dart';
import '../helpers/old_biometric_entry.dart';
import 'key_unlock_fixtures_test.dart' show KeyUnlockFixture;
import 'old_vault.dart';
import 'rotation_helpers.dart';
import 'vault_store_key_unlock_test.dart' show TestKey;

/// What someone who can write the app's storage, and has nothing else,
/// puts there: the sync settings of a WebDAV account of theirs.
const _theirSync = {'enabled': true, 'url': 'https://dav.example', 'user': 'them'};

Uint8List _json(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

class _NoPrompt implements Biometrics {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// A vault from before values were authenticated moves over where the key
/// that wraps its private key is at hand (VaultStore._moveOver).
void main() {
  late Phone phone;
  late VaultSession made;
  late RecoveryKey kit;

  /// [phone] holding a vault as an older version left it, with every kind
  /// of value, a Recovery Kit and both biometric entries.
  Future<void> older(Phone on) async {
    phone = on;
    made = await phone.vault.setupVault('pw');
    await fillVault(phone.vault, phone.store, keyFuture, made);
    kit = newKit();
    await phone.vault.setRecoveryKey(made, kit);
    await makeOld(phone, made, 'pw', kit: kit);
    await phone.vault.enableBiometricUnlock(made, 'Turn it on');
    await writeOldBiometricEntry(phone.store, phone.vaults, made);
  }

  /// Checks that the vault moved over, open in [session]: every value kept
  /// and authenticated, the newer version's byte for byte, both biometric
  /// entries and the hardware key gone, and each wrap saying so.
  Future<void> expectMoved(VaultSession session) async {
    expect(session.authenticated, isTrue);
    expect(saysAuthenticated(phone), isTrue);
    expect(kitSaysAuthenticated(phone), isTrue);
    await expectEveryItem(phone.vault, session);
    await expectEveryValueAuthenticated(phone, session);
    expect(await openRaw(phone.store.getItem(keyFuture)!, session.secretKey), futurePlain);
    expect(phone.store.getItem(keyNativeBio), isNull);
    expect(phone.store.getItem(keyHardwareBio), isNull);
    expect(phone.unlockKeys.keys, isEmpty);
    expect(phone.vault.hasBiometricUnlock(), isFalse);
    // The old entry kept the private key beside its seal key
    expect((await phone.vault.loadKeyInfo(session))?.exposed, isTrue);
    // From now on a value anyone could seal is refused
    final genuine = phone.store.getItem(keySyncSettings)!;
    phone.store.setItem(keySyncSettings, await sealRaw(_json(_theirSync), session.publicKey));
    await expectLater(phone.vault.loadEncryptedValue(keySyncSettings, session), throwsA(isA<AesGcmAuthError>()));
    phone.store.setItem(keySyncSettings, genuine);
  }

  test('at a password unlock, keeping every value and losing both biometric entries', () async {
    await older(Phone(KeyValueStore.memory()));

    final session = await phone.vault.unlockAnyVault('pw', mainVault);

    expect(session.secretKey, made.secretKey);
    await expectMoved(session);
    final byKit = await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
    expect(byKit.authenticated, isTrue);
    await expectEveryItem(phone.vault, byKit);
    phone.store.setItem(keySyncSettings, await sealRaw(_json(_theirSync), made.publicKey));
    await expectLater(phone.vault.loadEncryptedValue(keySyncSettings, byKit), throwsA(isA<AesGcmAuthError>()));
    expect((await phone.vault.unlockAnyVault('pw', mainVault)).authenticated, isTrue);
  });

  test('a hidden vault when its password is typed, and no other vault', () async {
    await older(Phone(KeyValueStore.memory()));
    final diary = await phone.vault.createVault('Diary', 'diary', listed: false);
    phone.vaults.active = diary;
    final diarySession = await phone.vault.unlockVault('diary');
    await phone.vault.saveAccounts([rotationAccount], diarySession);
    await makeOld(phone, diarySession, 'diary', vault: diary);
    phone.vaults.active = mainVault;
    final first = phone.snapshot;

    final opened = await phone.vault.unlockAnyVault('diary', mainVault);

    expect(phone.vaults.active, diary);
    expect(opened.authenticated, isTrue);
    expect(saysAuthenticated(phone, diary), isTrue);
    await expectEveryValueAuthenticated(phone, opened, vault: diary);
    expect(await phone.vault.loadAccounts(opened), [rotationAccount]);
    expect(
      {for (final key in phone.vault.sealedValueKeys(mainVault)) key: phone.store.getItem(key)},
      {for (final key in phone.vault.sealedValueKeys(mainVault)) key: first[key]},
    );
    expect(saysAuthenticated(phone), isFalse);
  });

  test('at a password change, the session demanding it from then on', () async {
    await older(Phone(KeyValueStore.memory()));
    final opened = await phone.vault.unlockVault('pw');
    expect(opened.authenticated, isFalse);

    await phone.vault.changePassword(opened, 'new pw');

    await expectMoved(opened);
    expect((await phone.vault.unlockAnyVault('new pw', mainVault)).authenticated, isTrue);
    expect((await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key)).authenticated, isTrue);
  });

  test('at the new password set after a Recovery Kit unlock, which moves nothing itself', () async {
    await older(Phone(KeyValueStore.memory()));
    final before = configOf(phone);

    final recovered = await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);

    expect(recovered.authenticated, isFalse);
    expect(configOf(phone), before);
    await phone.vault.resetToPassword(recovered, 'after the kit');
    await expectMoved(recovered);
    final again = await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
    expect(again.authenticated, isTrue);
    await expectEveryItem(phone.vault, again);
  });

  test('at a change of how it opens', () async {
    await older(Phone(KeyValueStore.memory()));
    final key = TestKey();
    final opened = await phone.vault.unlockVault('pw');
    var proof = await phone.vault.enrolKey(
      opened,
      await phone.vault.proveOwner(password: 'pw'),
      salt: phone.vault.keyChallenge().salt,
      credential: key.credential,
      output: key.output,
      name: 'Example Key',
      pinBound: true,
    );
    expect(saysAuthenticated(phone), isFalse);

    proof = await phone.vault.setUnlockMode(opened, proof, UnlockMode.both);

    await expectMoved(opened);
    final step = await phone.vault.beginUnlock('pw', mainVault) as UnlockNeedsKey;
    expect((await phone.vault.unlockWithSecurityKey(mainVault, key.reading, pending: step.pending)).authenticated, isTrue);
  });

  test('at the key unlock of a vault that opens with a key alone, or with both, as the fixtures do', () async {
    for (final name in ['key', 'both']) {
      final fixture = KeyUnlockFixture(name);
      final store = KeyValueStore.memory({keyConfig: fixture.rawConfig});
      final real = VaultStore(
        store,
        VaultRegistry(store),
        deriveKey: (password, salt) async => scrypt(utf8.encode(password), salt, n: scryptN, r: scryptR, p: scryptP),
        unlockKeys: FakeUnlockKeys(),
      );
      final entry = fixture.keyUnlock.keys.first;
      final reading = (credential: entry.credential, output: fixture.outputs.first);
      Future<VaultSession> unlock() async {
        if (name == 'key') return real.unlockWithSecurityKey(mainVault, reading);
        final step = await real.beginUnlock(fixture.password, mainVault) as UnlockNeedsKey;
        return real.unlockWithSecurityKey(mainVault, reading, pending: step.pending);
      }

      final opened = await unlock();

      final config = jsonDecode(store.getItem(keyConfig)!) as Map<String, Object?>;
      expect(opened.authenticated, isTrue, reason: name);
      expect(fixture.isTheKey(opened.secretKey), isTrue, reason: name);
      expect(jsonEncode(config['keyUnlock']), jsonEncode(fixture.config['keyUnlock']), reason: name);
      expect(config['salt'], fixture.config['salt'], reason: name);
      final again = await unlock();
      expect(again.authenticated, isTrue, reason: name);
      expect(fixture.isTheKey(again.secretKey), isTrue, reason: name);
    }
  });

  test('not at a biometric unlock, which has no wrap key to make the wrap again with', () async {
    await older(Phone(KeyValueStore.memory()));
    phone.store.removeItem(keyNativeBio);
    final before = phone.snapshot;

    final unlock = await phone.vault.unlockWithBiometrics('Unlock', _NoPrompt());

    expect(unlock.outcome, BiometricOutcome.opened);
    expect(unlock.session!.authenticated, isFalse);
    expect(phone.snapshot, before);
  });

  test('keeps a kit wrap it cannot make again, and a kit unlock through it is authenticated all the same', () async {
    await older(Phone(KeyValueStore.memory()));
    // The kit's key, which the vault keeps for exports, is gone
    phone.store.removeItem('backmycodes_recovery');

    await phone.vault.unlockAnyVault('pw', mainVault);

    expect(saysAuthenticated(phone), isTrue);
    expect(kitSaysAuthenticated(phone), isFalse);
    final byKit = await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
    expect(byKit.authenticated, isTrue);
    await expectEveryItem(phone.vault, byKit);
  });

  test('then a key replacement gives an authenticated vault', () async {
    await older(Phone(KeyValueStore.memory()));
    final moved = await phone.vault.unlockAnyVault('pw', mainVault);
    final next = newKit();

    final replaced = await phone.vault.replaceKeyPair(moved, 'pw', kit: next);

    expect(replaced.authenticated, isTrue);
    expect(saysAuthenticated(phone), isTrue);
    expect(kitSaysAuthenticated(phone), isTrue);
    await expectEveryValueAuthenticated(phone, replaced);
    final byKit = await phone.vault.unlockWithRecoveryKey(next.kitId, next.key);
    expect(byKit.authenticated, isTrue);
    await expectEveryItem(phone.vault, byKit);
  });

  test('killed at any write, the vault opens with every item, and the next unlock finishes the move', () async {
    var killed = 0;
    for (var n = 1; ; n++) {
      final store = CrashingStore();
      await older(Phone(store));
      store.diesAt = store.writes + n;
      try {
        await phone.vault.unlockAnyVault('pw', mainVault);
        // The move made fewer than n writes: every write has had its turn
        expect(store.dead, isFalse);
        break;
      } on StoreDied {
        killed++;
      }
      final reason = 'killed at write $n of the move';
      final survived = Phone(store.reopen());
      phone = survived;
      expect(saysAuthenticated(survived), isFalse, reason: reason);
      // Opened as it was, by the kit, which moves nothing
      final byKit = await survived.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
      expect(byKit.authenticated, isFalse, reason: reason);
      await expectEveryItem(survived.vault, byKit);

      final session = await survived.vault.unlockAnyVault('pw', mainVault);

      expect(session.authenticated, isTrue, reason: reason);
      await expectEveryItem(survived.vault, session);
      await expectEveryValueAuthenticated(survived, session);
      expect(survived.store.getItem(keyNativeBio), isNull, reason: reason);
      expect(survived.store.getItem(keyHardwareBio), isNull, reason: reason);
    }
    // Every value, the key info, both entries and the config, which is the commit
    expect(killed, greaterThan(10));
  });
}
