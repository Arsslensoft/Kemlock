import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/ml_kem.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/unlock_keys.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/sealed_value.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/crashing_store.dart';
import '../fakes/fake_unlock_keys.dart';
import '../helpers/old_biometric_entry.dart';
import 'fast_kdf.dart';
import 'rotation_helpers.dart';

const _account = OtpAccount(id: 'a1', issuer: 'ACME', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

/// Replacing a vault's key pair in the store (openspec: replace-vault-key-pair).
void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vault;

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
  });

  // Task 2.2
  group('the values to seal again', () {
    /// A value shaped like a sealed one, whatever it holds.
    String sealedShape() => jsonEncode({'kemCT': 'AAAA', 'nonce': 'AAAA', 'ct': 'AAAA'});

    test("lists the first vault's sealed values, one a newer version wrote among them", () async {
      final session = await vault.setupVault('pw');
      await vault.saveAccounts([_account], session);
      await vault.saveNotes(const [], session);
      await vault.saveEncryptedValue('backmycodes_sync', {'enabled': true}, session);
      await vault.saveEncryptedValue('backmycodes_future_thing', {'from': 'later'}, session);

      expect(vault.sealedValueKeys(mainVault)..sort(), [
        'backmycodes_future_thing',
        'backmycodes_key_info',
        'backmycodes_note_data',
        'backmycodes_sync',
        'backmycodes_vault_data',
      ]);
    });

    test("lists a suffixed vault's own, and none of the first vault's", () async {
      final first = await vault.setupVault('pw');
      await vault.saveAccounts([_account], first);
      final work = await vault.createVault('Work', 'work', listed: true);
      final workSession = await vault.unlockAnyVault('work', work);
      await vault.saveAccounts([_account], workSession);
      await vault.saveEncryptedValue('backmycodes_future_thing', {'from': 'later'}, workSession);

      expect(vault.sealedValueKeys(work)..sort(), [
        'backmycodes_future_thing::$work',
        'backmycodes_key_info::$work',
        'backmycodes_vault_data::$work',
      ]);
      expect(vault.sealedValueKeys(mainVault)..sort(), ['backmycodes_key_info', 'backmycodes_vault_data']);
    });

    test('leaves out the config, the replacement value and both biometric entries, whatever they hold', () async {
      await vault.setupVault('pw');
      for (final key in [keyKeyRotation, keyNativeBio, keyHardwareBio]) {
        store.setItem(key, sealedShape());
      }

      // Only what setup wrote
      expect(vault.sealedValueKeys(mainVault), [keyKeyInfo]);
    });

    test('leaves alone what isn’t exactly a sealed value', () async {
      await vault.setupVault('pw');
      store.setItem('backmycodes_extra_field', jsonEncode({'kemCT': 'AAAA', 'nonce': 'AAAA', 'ct': 'AAAA', 'v': 2}));
      store.setItem('backmycodes_not_strings', jsonEncode({'kemCT': 1, 'nonce': 'AAAA', 'ct': 'AAAA'}));
      store.setItem('backmycodes_a_list', jsonEncode(['kemCT', 'nonce', 'ct']));
      store.setItem('backmycodes_not_json', 'kemCT nonce ct');
      store.setItem(prefsKey, jsonEncode({'clearClipboard': true}));

      // Only what setup wrote
      expect(vault.sealedValueKeys(mainVault), [keyKeyInfo]);
    });

    test("lists none of the device's keys", () async {
      await vault.setupVault('pw');
      store.setItem(keyUnlockErase, sealedShape());
      store.setItem(keyLocale, sealedShape());

      // Only what setup wrote
      expect(vault.sealedValueKeys(mainVault), [keyKeyInfo]);
    });
  });

  // Task 2.3
  group('replacing the key pair', () {
    Map<String, Object?> config([String id = mainVault]) =>
        jsonDecode(store.getItem(vaults.vaultKey(keyConfig, id))!) as Map<String, Object?>;

    test('every item, the sync and Vaultwarden settings and the unknown key read back unchanged', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);

      final next = await vault.replaceKeyPair(old, 'pw');

      await expectEveryItem(vault, next);
      expect(await vault.loadAccounts(await vault.unlockAnyVault('pw', mainVault)), [rotationAccount]);
    });

    test("the contacts, other people's public keys, open under the new pair", () async {
      const contact = Contact(
        id: 'c1',
        name: 'Grace Hopper',
        publicKey: 'mDMEavvBvhYJKwYBBAHaRw8BAQdA',
        source: ContactSource.qr,
        checkedAt: 1_799_000_000_000,
        checkedFingerprint: '894F6AAC8FCE0FAF7EE21BB6B405E72AFBA23495',
        addedAt: 1,
      );
      final old = await vault.setupVault('pw');
      await vault.saveContacts(const [contact], old);
      expect(vault.sealedValueKeys(mainVault), contains('backmycodes_contact_data'));

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(await vault.loadContacts(next), [contact]);
      expect(await vault.loadContacts(await vault.unlockAnyVault('pw', mainVault)), [contact]);
      await expectLater(openRaw(store.getItem('backmycodes_contact_data')!, old.secretKey), throwsA(isA<AesGcmAuthError>()));
    });

    test('seals the unknown value again byte for byte', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(await openRaw(store.getItem(keyFuture)!, next.secretKey), futurePlain);
    });

    test('the old private key opens neither the config nor any value, and is nowhere in storage', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(config()['publicKey'], b64(next.publicKey));
      expect((await vault.unlockAnyVault('pw', mainVault)).secretKey, next.secretKey);
      expect(next.secretKey, isNot(old.secretKey));
      final sealed = vault.sealedValueKeys(mainVault);
      expect(sealed, hasLength(10));
      for (final key in sealed) {
        await expectLater(openRaw(store.getItem(key)!, old.secretKey), throwsA(isA<AesGcmAuthError>()), reason: key);
      }
      expect(store.getItem(keyKeyRotation), isNull);
      for (final key in store.storedKeys()) {
        expect(store.getItem(key), isNot(contains(b64(old.secretKey))), reason: key);
      }
    });

    test('keeps the salt, the scrypt parameters, the name and a key it doesn’t know in the config', () async {
      final old = await vault.setupVault('pw', name: 'Personal');
      store.setItem(
        keyConfig,
        jsonEncode({
          ...config(),
          'webauthn': {'id': 'from the web build'},
        }),
      );
      final before = config();

      final next = await vault.replaceKeyPair(old, 'pw');

      final after = config();
      expect(after.keys, before.keys);
      for (final field in ['salt', 'scrypt', 'name', 'webauthn']) {
        expect(after[field], before[field], reason: field);
      }
      for (final field in ['skNonce', 'skEnc', 'publicKey']) {
        expect(after[field], isNot(before[field]), reason: field);
      }
      expect(after['publicKey'], b64(next.publicKey));
    });

    test('changes nothing when the password is wrong', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);
      final before = {for (final key in store.storedKeys()) key: store.getItem(key)};

      await expectLater(vault.replaceKeyPair(old, 'not it'), throwsA(isA<IncorrectPasswordError>()));

      expect({for (final key in store.storedKeys()) key: store.getItem(key)}, before);
    });

    test('a hidden vault sharing the salt is still found with one derivation', () async {
      var derivations = 0;
      vault = VaultStore(
        store,
        vaults,
        deriveKey: (password, salt) {
          derivations++;
          return fastKdf(password, salt);
        },
        unlockKeys: FakeUnlockKeys(),
      );
      final first = await vault.setupVault('first');
      final diary = await vault.createVault('Diary', 'diary', listed: false);
      vaults.active = mainVault;
      await vault.replaceKeyPair(first, 'first');
      vaults.active = diary;
      final diarySession = await vault.unlockAnyVault('diary', mainVault);
      await vault.saveAccounts([rotationAccount], diarySession);
      await vault.replaceKeyPair(diarySession, 'diary');
      vaults.active = mainVault;

      derivations = 0;
      await vault.unlockAnyVault('diary', mainVault);

      expect(vaults.active, diary);
      expect(derivations, 1);
      expect(config(diary)['salt'], config()['salt']);
    });

    test("replaces one vault's key pair and leaves another's alone", () async {
      final first = await vault.setupVault('first');
      await vault.saveAccounts([rotationAccount], first);
      final work = await vault.createVault('Work', 'work', listed: true);
      final workBefore = {for (final key in vaults.keysOf(work)) key: store.getItem(key)};
      vaults.active = mainVault;

      await vault.replaceKeyPair(first, 'first');

      expect({for (final key in vaults.keysOf(work)) key: store.getItem(key)}, workBefore);
    });

    test('refuses a session that isn’t the vault’s own key pair, changing nothing', () async {
      await vault.setupVault('pw');
      final pair = MlKem1024.keygen();
      final before = {for (final key in store.storedKeys()) key: store.getItem(key)};

      await expectLater(
        vault.replaceKeyPair(VaultSession(publicKey: pair.publicKey, secretKey: pair.secretKey), 'pw'),
        throwsA(isA<StateError>()),
      );
      expect({for (final key in store.storedKeys()) key: store.getItem(key)}, before);
    });
  });

  // Task 2.6
  group('a value neither key opens', () {
    /// A value sealed to a key pair the vault never had, as damage might leave.
    Future<String> sealedToAThirdKey() async => sealRaw(futurePlain, MlKem1024.keygen().publicKey);

    test('stops the replacement with an error, keeping the previous key, and the rest reads back', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);
      final bad = await sealedToAThirdKey();
      store.setItem('backmycodes_damaged', bad);

      final error = await vault
          .replaceKeyPair(old, 'pw')
          .then<KeyReplacementIncomplete?>((_) => null, onError: (Object e) => e as KeyReplacementIncomplete);

      expect(error!.unreadable, ['backmycodes_damaged']);
      expect(store.getItem('backmycodes_damaged'), bad);
      expect(store.getItem(keyKeyRotation), isNotNull);
      final session = await vault.unlockAnyVault('pw', mainVault);
      expect(session.secretKey, error.session.secretKey);
      await expectEveryItem(vault, session);
      // Kept for a later try, so the previous key is still at hand
      expect(store.getItem(keyKeyRotation), isNotNull);
    });

    test('a retry once the value is gone finishes the replacement', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);
      store.setItem('backmycodes_damaged', await sealedToAThirdKey());
      await expectLater(vault.replaceKeyPair(old, 'pw'), throwsA(isA<KeyReplacementIncomplete>()));

      store.removeItem('backmycodes_damaged');
      final session = await vault.unlockAnyVault('pw', mainVault);

      expect(store.getItem(keyKeyRotation), isNull);
      await expectEveryItem(vault, session);
      for (final key in vault.sealedValueKeys(mainVault)) {
        await expectLater(openRaw(store.getItem(key)!, old.secretKey), throwsA(isA<AesGcmAuthError>()), reason: key);
      }
    });

    test('a damaged value that only looks sealed stops it too, and the unlock still opens the vault', () async {
      final old = await vault.setupVault('pw');
      await vault.saveAccounts([_account], old);
      store.setItem('backmycodes_damaged', jsonEncode({'kemCT': 'AAAA', 'nonce': 'AAAA', 'ct': 'not base64!'}));

      await expectLater(vault.replaceKeyPair(old, 'pw'), throwsA(isA<KeyReplacementIncomplete>()));
      final session = await vault.unlockAnyVault('pw', mainVault);

      expect(await vault.loadAccounts(session), [_account]);
    });
  });

  // Task 3.2
  group('the Recovery Kit', () {
    /// A kit made as the kit sheet makes one, with its pieces.
    ({RecoveryKey kit, List<String> pieces}) kitWithPieces(int threshold, int shares) {
      final made = makeKit(threshold, shares);
      return (
        kit: RecoveryKey(kitId: made.kitId, key: made.key, threshold: threshold, shares: shares, createdAt: '2026-11-16T00:00:00.000Z'),
        pieces: made.pieces,
      );
    }

    Uint8List rebuilt(List<String> pieces) => rebuildKey([for (final piece in pieces) parsePiece(piece)]);

    test('any two of the three new pieces open the vault, and no old piece does', () async {
      final old = await vault.setupVault('pw');
      final before = kitWithPieces(2, 3);
      await vault.setRecoveryKey(old, before.kit);
      final after = kitWithPieces(2, 3);

      final next = await vault.replaceKeyPair(old, 'pw', kit: after.kit);

      for (final pair in [
        [0, 1],
        [0, 2],
        [1, 2],
      ]) {
        final key = rebuilt([for (final i in pair) after.pieces[i]]);
        expect((await vault.unlockWithRecoveryKey(after.kit.kitId, key)).secretKey, next.secretKey, reason: '$pair');
      }
      await expectLater(
        vault.unlockWithRecoveryKey(before.kit.kitId, rebuilt(before.pieces.take(2).toList())),
        throwsA(isA<KitNotFoundError>()),
      );
      expect(vault.recoveryKitInfo(), RecoveryKitInfo(kitId: after.kit.kitId, threshold: 2, shares: 3, createdAt: after.kit.createdAt));
      expect((await vault.loadRecoveryKey(next))?.kitId, after.kit.kitId);
    });

    test('an export made afterwards carries the new kit and not the old', () async {
      final old = await vault.setupVault('pw');
      final oldKit = newKit();
      await vault.setRecoveryKey(old, oldKit);
      final kit = newKit();
      final next = await vault.replaceKeyPair(old, 'pw', kit: kit);

      final text = await exportVault([_account], const [], 'export pw', recoveryKey: await vault.loadRecoveryKey(next), deriveKey: fastKdf);

      expect(exportRecoveryKit(text)?.kitId, kit.kitId);
      expect((await importVaultWithRecoveryKey(text, kit.key)).accounts, [_account]);
      await expectLater(importVaultWithRecoveryKey(text, oldKit.key), throwsA(isA<AesGcmAuthError>()));
    });

    test('an export made before still opens with its password and with the old kit', () async {
      final old = await vault.setupVault('pw');
      final oldKit = newKit();
      await vault.setRecoveryKey(old, oldKit);
      final text = await exportVault([_account], const [], 'export pw', recoveryKey: await vault.loadRecoveryKey(old), deriveKey: fastKdf);

      await vault.replaceKeyPair(old, 'pw', kit: newKit());

      expect((await importVault(text, 'export pw', deriveKey: fastKdf)).accounts, [_account]);
      expect((await importVaultWithRecoveryKey(text, oldKit.key)).accounts, [_account]);
    });

    test('going on without a kit leaves none, and the old pieces open nothing', () async {
      final old = await vault.setupVault('pw');
      final oldKit = newKit();
      await vault.setRecoveryKey(old, oldKit);

      final next = await vault.replaceKeyPair(old, 'pw', dropKit: true);

      expect(vault.recoveryKitInfo(), isNull);
      expect(await vault.loadRecoveryKey(next), isNull);
      expect(store.getItem('backmycodes_recovery'), isNull);
      await expectLater(vault.unlockWithRecoveryKey(oldKit.kitId, oldKit.key), throwsA(isA<KitNotFoundError>()));
    });

    test('a vault without a kit gets none, and can’t be given one this way', () async {
      final old = await vault.setupVault('pw');
      final before = Map.of({for (final key in store.storedKeys()) key: store.getItem(key)});

      await expectLater(vault.replaceKeyPair(old, 'pw', kit: newKit()), throwsA(isA<ArgumentError>()));
      expect({for (final key in store.storedKeys()) key: store.getItem(key)}, before);
      final next = await vault.replaceKeyPair(old, 'pw');

      expect(vault.recoveryKitInfo(), isNull);
      expect(await vault.loadRecoveryKey(next), isNull);
    });

    test('a vault with a kit needs a new one or the choice to go without', () async {
      final old = await vault.setupVault('pw');
      await vault.setRecoveryKey(old, newKit());

      await expectLater(vault.replaceKeyPair(old, 'pw'), throwsA(isA<ArgumentError>()));
      expect(store.getItem(keyKeyRotation), isNull);
    });

    test('gives new exports no kit while the stored kit key isn’t the one the config names', () async {
      final session = await vault.setupVault('pw');
      await vault.setRecoveryKey(session, newKit());
      final config = jsonDecode(store.getItem(keyConfig)!) as Map<String, Object?>;
      store.setItem(
        keyConfig,
        jsonEncode({
          ...config,
          'recovery': {...config['recovery']! as Map<String, Object?>, 'kitId': 'another'},
        }),
      );

      expect(await vault.loadRecoveryKey(session), isNull);
    });
  });

  // Task 4.1, in the store
  group('biometric unlock', () {
    test('both entries and the hardware key are gone before the config changes', () async {
      final keys = FakeUnlockKeys();
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys);
      final old = await vault.setupVault('pw');
      await vault.enableBiometricUnlock(old, 'Unlock');
      await writeOldBiometricEntry(store, vaults, old);
      final atCommit = <Object?>[];
      store.listen(keyConfig, () => atCommit.addAll([store.getItem(keyNativeBio), store.getItem(keyHardwareBio), keys.keys[mainVault]]));

      await vault.replaceKeyPair(old, 'pw');

      expect(atCommit, [null, null, null]);
      expect(keys.calls, contains('delete main'));
      expect(vault.hasBiometricUnlock(), isFalse);
    });

    test('turning it on again writes only the hardware entry, which opens the new key pair', () async {
      final keys = FakeUnlockKeys();
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys);
      final old = await vault.setupVault('pw');
      await writeOldBiometricEntry(store, vaults, old);

      final next = await vault.replaceKeyPair(old, 'pw');
      await vault.enableBiometricUnlock(next, 'Unlock');

      expect(store.getItem(keyNativeBio), isNull);
      expect(store.getItem(keyHardwareBio), isNotNull);
      final unlock = await vault.unlockWithBiometrics('Unlock', _NoFallback());
      expect(unlock.outcome, BiometricOutcome.opened);
      expect(unlock.session!.secretKey, next.secretKey);
    });

    test('a hardware key that fails to go doesn’t stop the replacement', () async {
      final keys = _FailingDelete();
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys);
      final old = await vault.setupVault('pw');
      await vault.enableBiometricUnlock(old, 'Unlock');

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(vault.hasBiometricUnlock(), isFalse);
      expect((await vault.unlockAnyVault('pw', mainVault)).secretKey, next.secretKey);
    });
  });

  // openspec: add-security-key-codes, task 3.2
  test('what the vault remembers of a security key is sealed again, and opens afterwards', () async {
    const onKey = KeyAccount(id: 'ka1', device: '0102030405060708', name: 'Example:alice', issuer: 'Example', label: 'alice', addedAt: 0);
    final accessKey = randomBytes(16);
    final old = await vault.setupVault('pw');
    await vault.saveKeyAccounts([onKey], old);
    await vault.saveKeyAccess({onKey.device: accessKey}, old);
    final before = {
      for (final key in ['backmycodes_key_account_data', 'backmycodes_key_access']) key: store.getItem(key),
    };

    final next = await vault.replaceKeyPair(old, 'pw');

    for (final MapEntry(:key, :value) in before.entries) {
      expect(store.getItem(key), isNot(value), reason: '$key is sealed to the new key pair');
      await expectLater(
        openRaw(store.getItem(key)!, old.secretKey),
        throwsA(isA<AesGcmAuthError>()),
        reason: 'the old private key no longer opens $key',
      );
    }
    expect(await vault.loadKeyAccounts(next), [onKey]);
    expect(await vault.loadKeyAccess(next), {onKey.device: accessKey});
    final reopened = await vault.unlockVault('pw');
    expect(await vault.loadKeyAccounts(reopened), [onKey]);
    expect(await vault.loadKeyAccess(reopened), {onKey.device: accessKey});
  });

  // Task 4.2, in the store
  group('the passkey inbox key', () {
    test('gets a new key, and keeps the old one as the previous one', () async {
      final old = await vault.setupVault('pw');
      final inbox = randomBytes(138);
      await vault.savePasskeyInboxKey(inbox, old);

      final next = await vault.replaceKeyPair(old, 'pw');

      final current = await vault.loadPasskeyInboxKey(next);
      expect(current, isNotNull);
      expect(current, isNot(inbox));
      expect(await vault.loadPreviousPasskeyInboxKey(next), inbox);
      // A P-256 key, as the inbox needs
      await P256KeyPair.fromPkcs8(current!);
    });

    test('a vault without passkeys gets no inbox key', () async {
      final old = await vault.setupVault('pw');

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(store.getItem('backmycodes_passkey_inbox'), isNull);
      expect(await vault.loadPasskeyInboxKey(next), isNull);
    });

    test('a replacement finished at the next unlock hands over the key it made, once', () async {
      final first = Phone(CrashingStore());
      final old = await first.vault.setupVault('pw');
      final inbox = randomBytes(138);
      await first.vault.savePasskeyInboxKey(inbox, old);
      // How many writes a whole replacement makes, on a copy
      final dry = CrashingStore(values: first.snapshot.cast());
      await Phone(dry).vault.replaceKeyPair(old, 'pw');
      // The real one dies at its last write, which deletes the replacement's value
      final died = CrashingStore(values: first.snapshot.cast(), diesAt: dry.writes);
      await expectLater(Phone(died).vault.replaceKeyPair(old, 'pw'), throwsA(isA<StoreDied>()));
      final next = Phone(died.reopen());
      expect(next.store.getItem(keyKeyRotation), isNotNull);
      // Read without finishing the replacement: the key the run that died handed over
      final handedOver = await next.vault.loadPasskeyInboxKey(await next.vault.unlockVault('pw'));

      final session = await next.vault.unlockAnyVault('pw', mainVault);

      expect(next.store.getItem(keyKeyRotation), isNull);
      expect(handedOver, isNot(inbox));
      expect(await next.vault.loadPasskeyInboxKey(session), handedOver);
      expect(await next.vault.loadPreviousPasskeyInboxKey(session), inbox);
    });

    test('forgets the previous key alone, keeping the current one', () async {
      final old = await vault.setupVault('pw');
      await vault.savePasskeyInboxKey(randomBytes(138), old);
      final next = await vault.replaceKeyPair(old, 'pw');
      final current = await vault.loadPasskeyInboxKey(next);

      await vault.dropPreviousPasskeyInboxKey(next);

      expect(await vault.loadPreviousPasskeyInboxKey(next), isNull);
      expect(await vault.loadPasskeyInboxKey(next), current);
    });
  });

  // Task 5.1
  group('what the vault knows about its key pair', () {
    final now = DateTime.utc(2026, 11, 16, 9, 41);

    setUp(() => vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys(), clock: () => now));

    test('a new vault’s key pair was made now, and never exposed', () async {
      final session = await vault.setupVault('pw');

      expect(await vault.loadKeyInfo(session), KeyInfo(madeAt: now, exposed: false, asked: false));
    });

    test('so is a vault made beside another, under its own id', () async {
      await vault.setupVault('pw');
      final work = await vault.createVault('Work', 'work', listed: true);
      final session = await vault.unlockAnyVault('work', work);

      expect(await vault.loadKeyInfo(session), KeyInfo(madeAt: now, exposed: false, asked: false));
    });

    test('a replaced key pair was made when the replacement started, and isn’t exposed', () async {
      final old = await vault.setupVault('pw');
      // As an exposed vault that was asked has it
      await vault.saveEncryptedValue(keyKeyInfo, {'exposed': true, 'asked': true}, old);
      final later = DateTime.utc(2026, 12, 1);
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys(), clock: () => later);

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(await vault.loadKeyInfo(next), KeyInfo(madeAt: later, exposed: false, asked: false));
    });

    test('marking a vault asked keeps the rest', () async {
      final session = await vault.setupVault('pw');
      await vault.saveEncryptedValue(keyKeyInfo, {'madeAt': 5, 'exposed': true, 'asked': false}, session);

      await vault.markKeyAsked(session);

      expect(await vault.loadKeyInfo(session), KeyInfo(madeAt: DateTime.fromMillisecondsSinceEpoch(5), exposed: true, asked: true));
    });
  });

  // Task 5.2
  group('a vault from before this version', () {
    /// A vault as an older version left it: no key info.
    Future<VaultSession> older() async {
      final session = await vault.setupVault('pw');
      store.removeItem(keyKeyInfo);
      return session;
    }

    test('is exposed when it has an old biometric entry', () async {
      await writeOldBiometricEntry(store, vaults, await older());

      final session = await vault.unlockAnyVault('pw', mainVault);

      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: false));
    });

    test('is exposed when it has a hardware entry only, which may have been an old one', () async {
      await vault.enableBiometricUnlock(await older(), 'Unlock');

      final session = await vault.unlockAnyVault('pw', mainVault);

      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: false));
    });

    test('isn’t known to be exposed without either', () async {
      await older();

      final session = await vault.unlockAnyVault('pw', mainVault);

      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: false, asked: false));
    });

    test('is classified at a Recovery Kit unlock too, and once', () async {
      final kit = newKit();
      final old = await older();
      await vault.setRecoveryKey(old, kit);
      await writeOldBiometricEntry(store, vaults, old);

      final session = await vault.unlockWithRecoveryKey(kit.kitId, kit.key);
      await vault.markKeyAsked(session);
      await vault.unlockAnyVault('pw', mainVault);

      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: true));
    });

    test('the v0.1.0 vault opens with its classification written, and moves over with nothing else changed', () async {
      final fixture = jsonDecode(File('test/fixtures/legacy-v0.1.0.json').readAsStringSync()) as Map<String, Object?>;
      final storage = (fixture['vaultStorage']! as Map<String, Object?>).cast<String, String>();
      store = KeyValueStore.memory(storage);
      vaults = VaultRegistry(store);
      vault = VaultStore(store, vaults, deriveKey: deriveVaultKey);

      final session = await vault.unlockAnyVault((fixture['passwords']! as Map<String, Object?>)['vault']! as String, mainVault);

      final after = {for (final key in store.storedKeys()) key: store.getItem(key)};
      expect(after.keys.toSet().difference(storage.keys.toSet()), {keyKeyInfo});
      expect(await vault.loadKeyInfo(session), KeyInfo(exposed: storage.containsKey(keyNativeBio), asked: false));
      // Moved over (sealed_value.dart): the config's wrap says so, and is all of it that changed
      Map<String, Object?> wrapless(String raw) => (jsonDecode(raw) as Map<String, Object?>)
        ..remove('skNonce')
        ..remove('skEnc');
      expect(session.authenticated, isTrue);
      expect(isAuthenticatedWrapNonce((jsonDecode(after[keyConfig]!) as Map<String, Object?>)['skNonce']), isTrue);
      expect(wrapless(after[keyConfig]!), wrapless(storage[keyConfig]!));
      // Each value sealed again, byte for byte what it held
      for (final key in storage.keys.where((key) => key != keyConfig)) {
        expect(await openRaw(after[key]!, session.secretKey), await openRaw(storage[key]!, session.secretKey), reason: key);
      }
    });
  });

  // Task 5.3
  group('the biometric migration marks the vault exposed', () {
    late FakeUnlockKeys keys;
    final made = DateTime.utc(2026, 1, 2);

    setUp(() {
      keys = FakeUnlockKeys();
      vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys, clock: () => made);
    });

    /// A vault as an older version left it: no key info.
    Future<VaultSession> older() async {
      final session = await vault.setupVault('pw');
      store.removeItem(keyKeyInfo);
      return session;
    }

    test('when it moves an old entry to the hardware ("Old only"), keeping when the key pair was made', () async {
      final old = await vault.setupVault('pw');
      await writeOldBiometricEntry(store, vaults, old);

      final unlock = await vault.unlockWithBiometrics('Unlock', _NoFallback());

      expect(unlock.outcome, BiometricOutcome.moved);
      expect(await vault.loadKeyInfo(unlock.session!), KeyInfo(madeAt: made, exposed: true, asked: false));
    });

    test('when it deletes the old entry once the hardware one opened the vault ("Both")', () async {
      final old = await older();
      await vault.enableBiometricUnlock(old, 'Unlock');
      await writeOldBiometricEntry(store, vaults, old);
      // Classified without the entries, as if they came after
      store.setItem(keyKeyInfo, await sealAs(keyKeyInfo, utf8.encode(jsonEncode({'exposed': false, 'asked': true})), old));

      final unlock = await vault.unlockWithBiometrics('Unlock', _NoFallback());

      expect(unlock.outcome, BiometricOutcome.opened);
      expect(store.getItem(keyNativeBio), isNull);
      expect(await vault.loadKeyInfo(unlock.session!), const KeyInfo(exposed: true, asked: true));
    });

    test('when it deletes an old entry a phone without strong biometrics can’t move', () async {
      await writeOldBiometricEntry(store, vaults, await older());
      keys.available = false;

      final unlock = await vault.unlockWithBiometrics('Unlock', _NoFallback());
      final session = await vault.unlockAnyVault('pw', mainVault);

      expect(unlock.outcome, BiometricOutcome.unsupported);
      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: false));
    });

    test('when biometrics changed, or biometric unlock is turned off, with an old entry', () async {
      final old = await older();
      await vault.enableBiometricUnlock(old, 'Unlock');
      await writeOldBiometricEntry(store, vaults, old);
      keys.invalidate(mainVault);

      expect((await vault.unlockWithBiometrics('Unlock', _NoFallback())).outcome, BiometricOutcome.invalidated);
      expect(await vault.loadKeyInfo(await vault.unlockAnyVault('pw', mainVault)), const KeyInfo(exposed: true, asked: false));

      final other = await vault.createVault('Work', 'work', listed: true);
      final work = await vault.unlockAnyVault('work', other);
      store.removeItem(vaults.vaultKey(keyKeyInfo, other));
      await writeOldBiometricEntry(store, vaults, work, other);
      await vault.removeBiometricUnlock();
      expect(await vault.loadKeyInfo(work), const KeyInfo(exposed: true, asked: false));
    });

    test('without the private key, keeps key info a vault has, so a dismissed offer stays dismissed', () async {
      final old = await older();
      await writeOldBiometricEntry(store, vaults, old);
      final session = await vault.unlockAnyVault('pw', mainVault);
      await vault.markKeyAsked(session);
      // The password unlock deleted the old entry; an earlier version, back for a while, writes one again
      await writeOldBiometricEntry(store, vaults, old);
      keys.available = false;

      await vault.unlockWithBiometrics('Unlock', _NoFallback());

      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: true));
    });

    test('marks nothing where there was no old entry', () async {
      final old = await vault.setupVault('pw');
      await vault.enableBiometricUnlock(old, 'Unlock');

      final unlock = await vault.unlockWithBiometrics('Unlock', _NoFallback());
      await vault.removeBiometricUnlock();

      expect(await vault.loadKeyInfo(unlock.session!), KeyInfo(madeAt: made, exposed: false, asked: false));
    });
  });

  // Task 6.1, in the store
  group('other loads and saves while the key is replaced', () {
    test('a save already under way lands before the replacement starts, and is sealed again', () async {
      final old = await vault.setupVault('pw');
      final atStart = <String?>[];
      store.listen(keyKeyRotation, () => atStart.add(store.getItem('backmycodes_vault_data')));

      final saving = vault.saveAccounts([_account], old);
      final next = await vault.replaceKeyPair(old, 'pw');
      await saving;

      expect(atStart.first, isNotNull);
      expect(await vault.loadAccounts(next), [_account]);
      await expectLater(openRaw(store.getItem('backmycodes_vault_data')!, old.secretKey), throwsA(isA<AesGcmAuthError>()));
    });

    test('a save started during the replacement waits for it, and seals to the new pair', () async {
      final old = await vault.setupVault('pw');
      await vault.saveAccounts([_account], old);
      final atCommit = <String?>[];
      store.listen(keyConfig, () => atCommit.add(store.getItem('backmycodes_backup_data')));

      final replacing = vault.replaceKeyPair(old, 'pw');
      // Given the session the caller held when it started
      final saving = vault.saveBackupServices([rotationService], old);
      final next = await replacing;
      await saving;

      expect(atCommit, [null]);
      expect(await vault.loadBackupServices(next), [rotationService]);
      await expectLater(openRaw(store.getItem('backmycodes_backup_data')!, old.secretKey), throwsA(isA<AesGcmAuthError>()));
      expect(store.getItem(keyKeyRotation), isNull);
    });

    test('a save that waited for a replacement with the wrong password seals to the key pair it was given', () async {
      final old = await vault.setupVault('pw');

      final replacing = vault.replaceKeyPair(old, 'not it');
      final saving = vault.saveAccounts([_account], old);
      await expectLater(replacing, throwsA(isA<IncorrectPasswordError>()));
      await saving;

      expect(await vault.loadAccounts(old), [_account]);
    });

    test('refuses a second replacement while one runs', () async {
      final old = await vault.setupVault('pw');

      final first = vault.replaceKeyPair(old, 'pw');
      await expectLater(vault.replaceKeyPair(old, 'pw'), throwsA(isA<StateError>()));
      await first;
    });
  });
  // openspec: add-security-key-unlock, task 4.5
  group('with the proof of what opens the vault', () {
    test('a password vault’s proof replaces its key pair as its password does', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);

      final next = await vault.replaceKeyPair(old, 'not used', proof: await vault.proveOwner(password: 'pw'));

      expect(next.secretKey, isNot(old.secretKey));
      expect((await vault.unlockAnyVault('pw', mainVault)).secretKey, next.secretKey);
      await expectEveryItem(vault, next);
      expect(store.getItem(keyKeyRotation), isNull);
    });

    test('a proof that does not open the vault replaces nothing', () async {
      final old = await vault.setupVault('pw');
      final proof = await vault.proveOwner(password: 'pw');
      await vault.changePassword(old, 'another password', proof: proof);
      final before = store.getItem(keyConfig);

      // The proof is of the vault as it was: its password key opens nothing now
      await expectLater(vault.replaceKeyPair(old, 'another password', proof: proof), throwsA(isA<IncorrectPasswordError>()));

      expect(store.getItem(keyConfig), before);
      expect(store.getItem(keyKeyRotation), isNull);
    });

    test('a vault with keys enrolled keeps its keyUnlock byte for byte', () async {
      final old = await vault.setupVault('pw');
      final credential = randomBytes(64);
      final output = randomBytes(32);
      await vault.enrolKey(
        old,
        await vault.proveOwner(password: 'pw'),
        salt: vault.keyChallenge().salt,
        credential: credential,
        output: output,
        name: 'Example Key',
        pinBound: true,
      );
      final before = jsonEncode((jsonDecode(store.getItem(keyConfig)!) as Map<String, Object?>)['keyUnlock']);

      final next = await vault.replaceKeyPair(old, 'pw');

      expect(jsonEncode((jsonDecode(store.getItem(keyConfig)!) as Map<String, Object?>)['keyUnlock']), before);
      // The enrolled key still gives the key secret, which never sat under the old key pair
      expect((await vault.proveOwner(password: 'pw', key: (credential: credential, output: output))).keySecret, hasLength(32));
      expect((await vault.unlockAnyVault('pw', mainVault)).secretKey, next.secretKey);
    });
  });
}

class _NoFallback implements Biometrics {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

class _FailingDelete extends FakeUnlockKeys {
  @override
  Future<void> delete(String vault) async => throw const UnlockKeyFailed('The Keystore is busy');
}
