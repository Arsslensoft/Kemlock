import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/ml_kem.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/unlock_keys.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import '../helpers/old_biometric_entry.dart';
import 'fast_kdf.dart';

const _secret = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';

OtpAccount account(String id) => OtpAccount(id: id, issuer: 'Issuer $id', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

const _onKey = KeyAccount(
  id: 'ka1',
  device: '0102030405060708',
  keyName: 'YubiKey 5C NFC',
  name: 'Example:alice@example.org',
  issuer: 'Example',
  label: 'alice@example.org',
  tags: ['work'],
  addedAt: 0,
);

const _acme = OtpAccount(id: 'a1', issuer: 'ACME', label: '', secret: _secret, addedAt: 0);
const _github = BackupService(
  id: 's1',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'abcd-1234')],
  addedAt: 0,
);

/// `local_auth`'s prompt, which the fallback shows.
class _Prompt implements Biometrics {
  bool passes = true;
  final List<String> prompts = [];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate(String reason) async {
    prompts.add(reason);
    return passes;
  }
}

void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;
  late FakeUnlockKeys keys;
  late VaultStore vault;

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    keys = FakeUnlockKeys();
    vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys);
  });

  Map<String, Object?> config([String id = mainVault]) =>
      jsonDecode(store.getItem(vaults.vaultKey(keyConfig, id))!) as Map<String, Object?>;

  group('setup and unlock', () {
    test('reports whether a vault exists', () async {
      expect(vault.isVaultSetup(), isFalse);
      await vault.setupVault('pw');
      expect(vault.isVaultSetup(), isTrue);
    });

    test('stores only the wrapped private key and the scrypt parameters', () async {
      final session = await vault.setupVault('pw');

      expect(config().keys.toList()..sort(), ['publicKey', 'salt', 'scrypt', 'skEnc', 'skNonce']);
      expect(config()['scrypt'], {'N': 131072, 'r': 8, 'p': 1});
      // ML-KEM-1024 key sizes (FIPS 203)
      expect(session.publicKey, hasLength(1568));
      expect(session.secretKey, hasLength(3168));
      expect(store.getItem(keyConfig), isNot(contains(b64(session.secretKey))));
    });

    test('unlocks with the right password and recovers the same key pair', () async {
      final created = await vault.setupVault('right password');
      final unlocked = await vault.unlockVault('right password');

      expect(unlocked.secretKey, created.secretKey);
      expect(unlocked.publicKey, created.publicKey);
    });

    test("seals to the private key's own public key, whatever the config says", () async {
      final created = await vault.setupVault('pw');
      // Someone who can write the app's files puts a public key of theirs in the config
      final theirs = MlKem1024.keygen();
      store.setItem(vaults.vaultKey(keyConfig, mainVault), jsonEncode({...config(), 'publicKey': b64(theirs.publicKey)}));

      final unlocked = await vault.unlockVault('pw');
      expect(unlocked.publicKey, created.publicKey);

      await vault.saveAccounts([_acme], unlocked);
      expect(await vault.loadAccounts(unlocked), [_acme]);
      // What was saved doesn't open with their private key
      await expectLater(
        vault.loadAccounts(VaultSession(publicKey: theirs.publicKey, secretKey: theirs.secretKey)),
        throwsA(isA<AesGcmAuthError>()),
      );
    });

    test('rejects the wrong password', () async {
      await vault.setupVault('right password');

      await expectLater(vault.unlockVault('wrong password'), throwsA(isA<AesGcmAuthError>()));
    });

    test('refuses to unlock when no vault exists', () async {
      await expectLater(vault.unlockVault('pw'), throwsA(isA<VaultMissingError>()));
    });
  });

  group('encrypted storage', () {
    late VaultSession session;
    setUp(() async => session = await vault.setupVault('correct horse battery staple'));

    test('returns an empty list when nothing has been saved', () async {
      expect(await vault.loadAccounts(session), isEmpty);
      expect(await vault.loadBackupServices(session), isEmpty);
    });

    test('round-trips accounts and backup services', () async {
      await vault.saveAccounts([_acme], session);
      await vault.saveBackupServices([_github], session);

      expect(await vault.loadAccounts(session), [_acme]);
      expect(await vault.loadBackupServices(session), [_github]);
    });

    test('keeps backup services apart from accounts', () async {
      await vault.saveAccounts([account('a')], session);
      await vault.saveBackupServices([_github], session);

      expect(await vault.loadAccounts(session), [account('a')]);
    });

    test('never writes secrets to storage in plaintext', () async {
      await vault.saveAccounts([_acme], session);
      await vault.saveBackupServices([_github], session);

      final everything = store.storedKeys().map(store.getItem).join('\n');
      expect(everything, isNot(contains(_secret)));
      expect(everything, isNot(contains('abcd-1234')));
      expect(everything, isNot(contains('GitHub')));
    });

    test('uses a fresh ML-KEM encapsulation for every save', () async {
      await vault.saveAccounts([_acme], session);
      final first = jsonDecode(store.getItem('backmycodes_vault_data')!) as Map<String, Object?>;
      await vault.saveAccounts([_acme], session);
      final second = jsonDecode(store.getItem('backmycodes_vault_data')!) as Map<String, Object?>;

      expect(second.keys, ['kemCT', 'nonce', 'ct']);
      expect(second['kemCT'], isNot(first['kemCT']));
      expect(second['nonce'], isNot(first['nonce']));
      expect(second['ct'], isNot(first['ct']));
    });

    test('rejects tampered ciphertext', () async {
      await vault.saveAccounts([_acme], session);
      final stored = jsonDecode(store.getItem('backmycodes_vault_data')!) as Map<String, Object?>;
      final ct = unb64(stored['ct']! as String);
      ct[0] ^= 0xff;
      store.setItem('backmycodes_vault_data', jsonEncode({...stored, 'ct': b64(ct)}));

      await expectLater(vault.loadAccounts(session), throwsA(isA<AesGcmAuthError>()));
    });

    test('saves and removes any JSON value under its own key', () async {
      await vault.saveEncryptedValue('backmycodes_sync', {'personal': null, 'spaces': <Object?>[]}, session);

      expect(await vault.loadEncryptedValue('backmycodes_sync', session), {'personal': null, 'spaces': <Object?>[]});
      vault.removeEncryptedValue('backmycodes_sync');
      expect(await vault.loadEncryptedValue('backmycodes_sync', session), isNull);
    });

    test('keeps fields of accounts it does not know', () async {
      final future = OtpAccount.fromJson({..._acme.toJson(), 'icon': 'github'});
      await vault.saveAccounts([future], session);

      expect((await vault.loadAccounts(session)).single.toJson()['icon'], 'github');
    });

    group('contacts', () {
      const key = 'backmycodes_contact_data';
      const grace = Contact(
        id: 'c1',
        name: 'Grace Hopper',
        publicKey: 'mDMEavvBvhYJKwYBBAHaRw8BAQdA',
        source: ContactSource.qr,
        checkedAt: 1_799_000_000_000,
        checkedFingerprint: '894F6AAC8FCE0FAF7EE21BB6B405E72AFBA23495',
        addedAt: 1,
      );
      const alan = Contact(id: 'c2', name: 'Alan Turing', publicKey: 'mDMEavvBxRYJ', source: ContactSource.file, addedAt: 2);

      test('a vault never given a contact has no such key in storage', () async {
        await vault.saveAccounts([_acme], session);

        expect(await vault.loadContacts(session), isEmpty);
        expect(store.getItem(key), isNull);
        expect(vault.sealedValueKeys(mainVault), isNot(contains(key)));
      });

      test('saved contacts load back, with their checks', () async {
        await vault.saveContacts([grace, alan], session);

        expect(await vault.loadContacts(session), [grace, alan]);
        expect(await vault.loadAccounts(session), isEmpty);
      });

      test('the stored value is exactly kemCT, nonce and ct, and names nobody', () async {
        await vault.saveContacts([grace], session);

        final stored = jsonDecode(store.getItem(key)!) as Map<String, Object?>;
        expect(stored.keys.toSet(), {'kemCT', 'nonce', 'ct'});
        expect(stored.values, everyElement(isA<String>()));
        expect(store.getItem(key), isNot(contains('Grace')));
        expect(store.getItem(key), isNot(contains(grace.publicKey)));
      });

      test('it is among the values a key pair replacement seals again', () async {
        await vault.saveContacts([grace], session);

        expect(vault.sealedValueKeys(mainVault), contains(key));
      });

      test('each vault keeps its own', () async {
        await vault.saveContacts([grace], session);
        final work = await vault.createVault('Work', 'work', listed: true);
        final workSession = await vault.unlockAnyVault('work', work);

        expect(await vault.loadContacts(workSession), isEmpty);
        expect(store.getItem('$key::$work'), isNull);
      });
    });
  });

  group('changePassword', () {
    test('re-wraps the same key pair under the new password', () async {
      final session = await vault.setupVault('old password');
      await vault.saveAccounts([_acme], session);

      final updated = await vault.changePassword(session, 'new password');

      expect(updated.secretKey, session.secretKey);
      await expectLater(vault.unlockVault('old password'), throwsA(isA<AesGcmAuthError>()));
      final reopened = await vault.unlockVault('new password');
      expect(await vault.loadAccounts(reopened), [_acme]);
    });

    test('keeps passkeys the web build registered, and the name', () async {
      final session = await vault.setupVault('old password');
      final passkeys = [
        {'credentialId': 'cred', 'mode': 'gate', 'nickname': 'Key', 'registeredAt': 'x'},
      ];
      store.setItem(keyConfig, jsonEncode({...config(), 'passkeys': passkeys, 'name': 'Personal'}));

      await vault.changePassword(session, 'new password');

      expect(config()['passkeys'], passkeys);
      expect(config()['name'], 'Personal');
    });

    test('keeps the salt the vaults share, so a wrong password still costs one derivation with a hidden vault there', () async {
      var derivations = 0;
      vault = VaultStore(
        store,
        vaults,
        deriveKey: (password, salt) {
          derivations++;
          return fastKdf(password, salt);
        },
        unlockKeys: keys,
      );
      final session = await vault.setupVault('old password');
      final diary = await vault.createVault('Diary', 'diary', listed: false);
      final salt = config()['salt'];

      await vault.changePassword(session, 'new password');

      expect(config()['salt'], salt);
      expect(config(diary)['salt'], salt);
      derivations = 0;
      await expectLater(vault.beginUnlock('wrong', mainVault), throwsA(isA<IncorrectPasswordError>()));
      expect(derivations, 1);
      await expectLater(vault.unlockAnyVault('old password', mainVault), throwsA(isA<IncorrectPasswordError>()));
      expect((await vault.unlockAnyVault('new password', mainVault)).secretKey, session.secretKey);
      expect((await vault.unlockAnyVault('diary', mainVault)).secretKey, isNot(session.secretKey));
    });
  });

  test("clears every password's key it derives once it is used, the session's private key left as it is", () async {
    final derived = <Uint8List>[];
    vault = VaultStore(
      store,
      vaults,
      deriveKey: (password, salt) async {
        final key = await fastKdf(password, salt);
        derived.add(key);
        return key;
      },
      unlockKeys: keys,
    );

    final session = await vault.setupVault('pw');
    await vault.saveAccounts([_acme], session);
    await vault.createVault('Diary', 'diary', listed: false);
    vaults.active = mainVault;
    final opened = await vault.unlockAnyVault('pw', mainVault);
    await expectLater(vault.beginUnlock('wrong', mainVault), throwsA(isA<IncorrectPasswordError>()));
    await vault.unlockVault('pw');
    await vault.changePassword(opened, 'new pw');
    final next = await vault.replaceKeyPair(opened, 'new pw');

    expect(derived, hasLength(greaterThan(6)));
    for (final key in derived) {
      expect(key, everyElement(0));
    }
    expect(opened.secretKey, isNot(everyElement(0)));
    expect(await vault.loadAccounts(next), [_acme]);
    expect((await vault.unlockAnyVault('new pw', mainVault)).secretKey, next.secretKey);
  });

  test('wipes every vault and its data', () async {
    final session = await vault.setupVault('pw');
    await vault.saveAccounts([_acme], session);
    await vault.saveBackupServices([_github], session);

    vault.wipeVault();

    expect(vault.isVaultSetup(), isFalse);
    expect(store.getItem('backmycodes_vault_data'), isNull);
    expect(store.getItem('backmycodes_backup_data'), isNull);
  });

  group('several vaults', () {
    test("keeps each vault's accounts apart", () async {
      final main = await vault.setupVault('first');
      await vault.saveAccounts([account('personal')], main);

      final work = await vault.createVault('Work', 'second', listed: true);
      final session = await vault.unlockAnyVault('second', work);

      expect(vaults.active, work);
      expect(await vault.loadAccounts(session), isEmpty);
      await vault.saveAccounts([account('work')], session);
      expect(store.getItem('backmycodes_vault_data::$work'), isNotNull);

      final back = await vault.unlockAnyVault('first', mainVault);
      expect(await vault.loadAccounts(back), [account('personal')]);
    });

    test('lists a new vault on the lock screen unless it is hidden', () async {
      await vault.setupVault('first');
      final work = await vault.createVault('Work', 'second', listed: true);
      final secret = await vault.createVault('Diary', 'third', listed: false);

      expect(vaults.listedVaultIds(), [mainVault, work]);
      expect(vaults.hiddenVaultIds(), [secret]);
      expect(vaults.vaultName(work), 'Work');
    });

    test("shares the first vault's salt, so hidden vaults cost one derivation", () async {
      await vault.setupVault('first');
      final work = await vault.createVault('Work', 'second', listed: true);

      expect(config(work)['salt'], config()['salt']);
    });

    test('opens a hidden vault when its password is typed on any vault', () async {
      await vault.setupVault('first');
      final secret = await vault.createVault('Diary', 'third', listed: false);

      await vault.unlockAnyVault('third', mainVault);

      expect(vaults.active, secret);
    });

    test('does not open another listed vault with its password', () async {
      await vault.setupVault('first');
      await vault.createVault('Work', 'second', listed: true);

      // The user chose the first vault; typing Work's password there is a wrong password
      await expectLater(vault.unlockAnyVault('second', mainVault), throwsA(isA<IncorrectPasswordError>()));
    });

    test('refuses a password another vault already uses', () async {
      await vault.setupVault('first');
      await vault.createVault('Diary', 'third', listed: false);

      await expectLater(vault.createVault('Work', 'first', listed: true), throwsA(isA<PasswordInUseError>()));
      await expectLater(vault.createVault('Work', 'third', listed: true), throwsA(isA<PasswordInUseError>()));
    });

    test('opens the first vault after hiding it', () async {
      await vault.setupVault('first');
      final decoy = await vault.createVault('Everyday', 'second', listed: true);
      vaults.setListed(mainVault, false);

      await vault.unlockAnyVault('first', decoy);

      expect(vaults.active, mainVault);
    });

    test('renames a vault, and clears the name when given none', () async {
      await vault.setupVault('first');

      vault.renameVault(mainVault, '  Personal ');
      expect(vaults.vaultName(mainVault), 'Personal');
      vault.renameVault(mainVault, '');
      expect(vaults.vaultName(mainVault), isNull);
      expect(config().containsKey('name'), isFalse);
    });

    test('deletes one vault and leaves the others', () async {
      final main = await vault.setupVault('first');
      await vault.saveAccounts([account('personal')], main);
      final work = await vault.createVault('Work', 'second', listed: true);
      await vault.saveAccounts([account('work')], await vault.unlockAnyVault('second', work));

      vaults.removeVaultData(work);

      expect(vaults.allVaultIds(), [mainVault]);
      expect(vaults.active, mainVault);
      expect(await vault.loadAccounts(main), [account('personal')]);
    });
  });

  group('biometric unlock', () {
    test('opens the vault from the entry the Capacitor app wrote', () async {
      final session = await vault.setupVault('pw');
      final sealKey = randomBytes(32);
      final sealed = await aesGcmEncrypt(sealKey, session.secretKey);
      store.setItem(
        'backmycodes_native_bio',
        jsonEncode({'sealKey': b64(sealKey), 'nativeSkNonce': b64(sealed.nonce), 'nativeSkEnc': b64(sealed.ct)}),
      );

      expect(vault.hasBiometricUnlock(), isTrue);
      expect((await vault.unlockWithBiometrics('Unlock', _Prompt())).session!.secretKey, session.secretKey);
    });

    test('removes the old entry, and then opens nothing', () async {
      final session = await vault.setupVault('pw');
      await writeOldBiometricEntry(store, vaults, session);

      await vault.removeBiometricUnlock();

      expect(vault.hasBiometricUnlock(), isFalse);
      expect(store.getItem('backmycodes_native_bio'), isNull);
      await expectLater(vault.unlockWithBiometrics('Unlock', _Prompt()), throwsA(isA<VaultMissingError>()));
    });

    test('keeps opening the vault after the master password changes', () async {
      final session = await vault.setupVault('old password');
      await writeOldBiometricEntry(store, vaults, session);

      await vault.changePassword(session, 'new password');

      expect(vault.hasBiometricUnlock(), isTrue);
      // The old entry moves over, then the new one opens it
      expect((await vault.unlockWithBiometrics('Unlock', _Prompt())).session!.secretKey, session.secretKey);
      await vault.changePassword(session, 'newer password');
      final again = await vault.unlockWithBiometrics('Unlock', _Prompt());
      expect(again.outcome, BiometricOutcome.opened);
      expect(again.session!.secretKey, session.secretKey);
    });

    test("keeps each vault's entry apart", () async {
      final main = await vault.setupVault('first');
      await writeOldBiometricEntry(store, vaults, main);
      await vault.createVault('Work', 'second', listed: true);
      await vault.unlockAnyVault('second', vaults.listedVaultIds().last);

      expect(vault.hasBiometricUnlock(), isFalse);
    });
  });

  group('the hardware entry', () {
    Map<String, Object?> entry([String id = mainVault]) =>
        jsonDecode(store.getItem(vaults.vaultKey('backmycodes_hardware_bio', id))!) as Map<String, Object?>;

    test('keeps only the private key sealed under a key the hardware holds', () async {
      final session = await vault.setupVault('pw');

      await vault.enableBiometricUnlock(session, 'Turn it on');

      expect(entry().keys, ['v', 'nonce', 'ct']);
      expect(entry()['v'], 1);
      expect(keys.calls, ['seal main']);
      expect(keys.prompts, ['Turn it on']);
      expect(vault.hasBiometricUnlock(), isTrue);
      expect(store.getItem('backmycodes_native_bio'), isNull);
      // The private key opens with the hardware's key, and that key is nowhere in storage
      final sealKey = keys.keys[mainVault]!;
      expect(await aesGcmDecrypt(sealKey, unb64(entry()['nonce']! as String), unb64(entry()['ct']! as String)), session.secretKey);
      final everything = store.storedKeys().map(store.getItem).join('\n');
      expect(everything, isNot(contains(b64(sealKey))));
      expect(everything, isNot(contains(b64(session.secretKey))));
    });

    test('keeps the wrap an Android phone gives back beside it', () async {
      keys.android = true;
      final session = await vault.setupVault('pw');

      await vault.enableBiometricUnlock(session, 'Turn it on');

      expect(entry().keys, ['v', 'nonce', 'ct', 'wrap']);
      expect(entry()['wrap'], keys.wraps[mainVault]);
      expect(store.storedKeys().map(store.getItem).join('\n'), isNot(contains(b64(keys.keys[mainVault]!))));
    });

    test('writes nothing when the prompt is cancelled or fails', () async {
      final session = await vault.setupVault('pw');

      keys.cancelNext();
      await expectLater(vault.enableBiometricUnlock(session, 'Turn it on'), throwsA(isA<UnlockKeyCancelled>()));
      keys.available = false;
      await expectLater(vault.enableBiometricUnlock(session, 'Turn it on'), throwsA(isA<UnlockKeyUnavailable>()));

      expect(vault.hasBiometricUnlock(), isFalse);
      expect(store.getItem('backmycodes_hardware_bio'), isNull);
    });

    test("keeps each vault's entry and key apart", () async {
      final main = await vault.setupVault('first');
      await vault.enableBiometricUnlock(main, 'Turn it on');
      final work = await vault.createVault('Work', 'second', listed: true);
      final workSession = await vault.unlockAnyVault('second', work);
      expect(vault.hasBiometricUnlock(), isFalse);

      await vault.enableBiometricUnlock(workSession, 'Turn it on');

      expect(keys.calls, ['seal main', 'seal $work']);
      expect(keys.keys[mainVault], isNot(keys.keys[work]));
      expect(entry(work)['ct'], isNot(entry()['ct']));
      await vault.removeBiometricUnlock();
      expect(vault.hasBiometricUnlock(), isFalse);
      expect(keys.keys.keys, [mainVault]);
      vaults.active = mainVault;
      expect(vault.hasBiometricUnlock(), isTrue);
    });

    test('counts the old entry as biometric unlock too, and turning it off removes both and the key', () async {
      final session = await vault.setupVault('pw');
      await writeOldBiometricEntry(store, vaults, session);
      expect(vault.hasBiometricUnlock(), isTrue);
      await vault.enableBiometricUnlock(session, 'Turn it on');

      await vault.removeBiometricUnlock();

      expect(vault.hasBiometricUnlock(), isFalse);
      expect(store.getItem('backmycodes_native_bio'), isNull);
      expect(store.getItem('backmycodes_hardware_bio'), isNull);
      expect(keys.calls.last, 'delete main');
      expect(keys.keys, isEmpty);
    });
  });

  group('unlocking by biometrics', () {
    late _Prompt prompt;
    late VaultSession session;
    String? oldEntry() => store.getItem('backmycodes_native_bio');
    String? newEntry() => store.getItem('backmycodes_hardware_bio');

    setUp(() async {
      prompt = _Prompt();
      session = await vault.setupVault('pw');
    });

    Future<BiometricUnlock> unlock() => vault.unlockWithBiometrics('Unlock', prompt);

    test('opens the vault from the hardware entry alone', () async {
      await vault.enableBiometricUnlock(session, 'Turn it on');

      final result = await unlock();

      expect(result.outcome, BiometricOutcome.opened);
      expect(result.session!.secretKey, session.secretKey);
      expect(result.session!.publicKey, session.publicKey);
      expect(keys.prompts, ['Turn it on', 'Unlock']);
      expect(prompt.prompts, isEmpty);
    });

    test('moves the old entry over with the one prompt of the unlock, keeping it beside the new one', () async {
      await writeOldBiometricEntry(store, vaults, session);
      final before = oldEntry();

      final result = await unlock();

      expect(result.outcome, BiometricOutcome.moved);
      expect(result.session!.secretKey, session.secretKey);
      expect(keys.calls, ['seal main']);
      expect(keys.prompts, ['Unlock']);
      expect(prompt.prompts, isEmpty);
      expect(oldEntry(), before);
      expect(newEntry(), isNotNull);
    });

    test('deletes the old entry once the new one has opened the vault', () async {
      await writeOldBiometricEntry(store, vaults, session);
      await unlock();

      final result = await unlock();

      expect(result.outcome, BiometricOutcome.opened);
      expect(result.session!.secretKey, session.secretKey);
      expect(keys.calls, ['seal main', 'open main']);
      expect(oldEntry(), isNull);
      expect(newEntry(), isNotNull);
      expect(vault.hasBiometricUnlock(), isTrue);
    });

    test('falls back to the old entry when the new one fails, and writes the new one again next time', () async {
      keys.android = true;
      await writeOldBiometricEntry(store, vaults, session);
      await unlock();
      keys.failNext('Keystore operation failed');

      final result = await unlock();

      expect(result.outcome, BiometricOutcome.fellBack);
      expect(result.session!.secretKey, session.secretKey);
      expect(prompt.prompts, ['Unlock']);
      expect(newEntry(), isNull);
      expect(keys.keys, isEmpty);
      expect(keys.calls, ['seal main', 'open main', 'delete main']);
      expect(oldEntry(), isNotNull);

      expect((await unlock()).outcome, BiometricOutcome.moved);
      expect(newEntry(), isNotNull);
    });

    test('changes nothing when the fallback prompt is cancelled', () async {
      await writeOldBiometricEntry(store, vaults, session);
      await unlock();
      final entries = (oldEntry(), newEntry());
      keys.failNext();
      prompt.passes = false;

      final result = await unlock();

      expect(result, (session: null, outcome: BiometricOutcome.cancelled));
      expect((oldEntry(), newEntry()), entries);
      expect(keys.keys, contains(mainVault));
    });

    test('shows a failure of the hardware entry when there is no old entry to fall back to', () async {
      await vault.enableBiometricUnlock(session, 'Turn it on');
      keys.failNext('The Keystore is busy');

      await expectLater(unlock(), throwsA(isA<UnlockKeyFailed>().having((e) => e.message, 'message', 'The Keystore is busy')));
      expect(prompt.prompts, isEmpty);
      expect(newEntry(), isNotNull);
    });

    // local_auth's prompt takes weaker biometrics than the hardware's: falling back after a lockout got round it
    for (final withOld in [false, true]) {
      test('shows a failed prompt, such as a lockout, and never falls back, ${withOld ? 'with' : 'without'} the old entry', () async {
        if (withOld) {
          await writeOldBiometricEntry(store, vaults, session);
          await unlock();
        } else {
          await vault.enableBiometricUnlock(session, 'Turn it on');
        }
        final before = {for (final key in store.storedKeys()) key: store.getItem(key)};
        final held = {...keys.keys};
        keys.failPromptNext('Too many attempts');

        await expectLater(unlock(), throwsA(isA<UnlockKeyPromptFailed>().having((e) => e.message, 'message', 'Too many attempts')));

        expect(prompt.prompts, isEmpty);
        expect({for (final key in store.storedKeys()) key: store.getItem(key)}, before);
        expect(keys.keys, held);
      });
    }

    for (final withOld in [false, true]) {
      test('deletes ${withOld ? 'both entries' : 'the entry'} and the key once biometrics changed, never falling back', () async {
        if (withOld) {
          await writeOldBiometricEntry(store, vaults, session);
          await unlock();
        } else {
          await vault.enableBiometricUnlock(session, 'Turn it on');
        }
        keys.invalidate(mainVault);

        final result = await unlock();

        expect(result, (session: null, outcome: BiometricOutcome.invalidated));
        expect(prompt.prompts, isEmpty);
        expect((oldEntry(), newEntry()), (null, null));
        expect(keys.keys, isEmpty);
        expect(keys.calls.last, 'delete main');
        expect(vault.hasBiometricUnlock(), isFalse);
      });
    }

    for (final entries in ['new', 'old', 'both']) {
      test('changes nothing when the prompt is cancelled, with the $entries entry', () async {
        if (entries != 'new') await writeOldBiometricEntry(store, vaults, session);
        if (entries == 'new') await vault.enableBiometricUnlock(session, 'Turn it on');
        if (entries == 'both') await unlock();
        final before = {for (final key in store.storedKeys()) key: store.getItem(key)};
        final held = {...keys.keys};
        keys.cancelNext();

        final result = await unlock();

        expect(result, (session: null, outcome: BiometricOutcome.cancelled));
        expect({for (final key in store.storedKeys()) key: store.getItem(key)}, before);
        expect(keys.keys, held);
        expect(prompt.prompts, isEmpty);
      });
    }

    test('deletes an old entry that can never move on a phone without strong biometrics', () async {
      await writeOldBiometricEntry(store, vaults, session);
      keys.available = false;

      final result = await unlock();

      expect(result, (session: null, outcome: BiometricOutcome.unsupported));
      expect(oldEntry(), isNull);
      expect(vault.hasBiometricUnlock(), isFalse);
      expect(keys.prompts, isEmpty);
    });

    // The old entry keeps the private key beside what opens it: an unlock that had no need of it deletes it
    test('a password unlock deletes the old entry, says the key was exposed, and leaves no biometric unlock', () async {
      await writeOldBiometricEntry(store, vaults, session);

      final opened = await vault.unlockAnyVault('pw', mainVault);

      expect(oldEntry(), isNull);
      expect(newEntry(), isNull);
      expect(vault.hasBiometricUnlock(), isFalse);
      expect((await vault.loadKeyInfo(opened))!.exposed, isTrue);
      expect(keys.calls, isEmpty);
    });

    test('a password unlock deletes the old entry and keeps the hardware entry written beside it', () async {
      await writeOldBiometricEntry(store, vaults, session);
      await unlock();
      final hardware = newEntry();

      await vault.unlockAnyVault('pw', mainVault);

      expect(oldEntry(), isNull);
      expect(newEntry(), hardware);
      expect(vault.hasBiometricUnlock(), isTrue);
      expect((await unlock()).outcome, BiometricOutcome.opened);
    });

    test('a wrong password leaves the old entry as it was', () async {
      await writeOldBiometricEntry(store, vaults, session);
      final before = oldEntry();

      await expectLater(vault.unlockAnyVault('nope', mainVault), throwsA(isA<IncorrectPasswordError>()));

      expect(oldEntry(), before);
    });

    test('a Recovery Kit unlock deletes the old entry', () async {
      final kit = RecoveryKey(kitId: 'kit-1', key: randomBytes(32), threshold: 2, shares: 3, createdAt: '2026-11-21T00:00:00.000Z');
      await vault.setRecoveryKey(session, kit);
      await writeOldBiometricEntry(store, vaults, session);

      final opened = await vault.unlockWithRecoveryKey(kit.kitId, kit.key);

      expect(oldEntry(), isNull);
      expect((await vault.loadKeyInfo(opened))!.exposed, isTrue);
    });

    test('a hidden vault, which biometrics never open, loses its old entry when its password opens it', () async {
      final diary = await vault.createVault('Diary', 'other', listed: false);
      final hidden = await vault.unlockAnyVault('other', mainVault);
      await writeOldBiometricEntry(store, vaults, hidden, diary);
      await writeOldBiometricEntry(store, vaults, session, mainVault);

      await vault.unlockAnyVault('other', mainVault);

      expect(store.getItem(vaults.vaultKey('backmycodes_native_bio', diary)), isNull);
      // The vault on screen did not open, and keeps its own
      expect(oldEntry(), isNotNull);
    });

    test('opens the vault of each listed vault with its own key', () async {
      await vault.enableBiometricUnlock(session, 'Turn it on');
      final work = await vault.createVault('Work', 'second', listed: true);
      final workSession = await vault.unlockAnyVault('second', work);
      await vault.enableBiometricUnlock(workSession, 'Turn it on');

      expect((await unlock()).session!.secretKey, workSession.secretKey);
      vaults.active = mainVault;
      expect((await unlock()).session!.secretKey, session.secretKey);
      expect(keys.calls, ['seal main', 'seal $work', 'open $work', 'open main']);
    });
  });

  group('Recovery Kit', () {
    RecoveryKey kit({int threshold = 2, int shares = 3}) => RecoveryKey(
      kitId: b64url(randomBytes(5)),
      key: randomBytes(32),
      threshold: threshold,
      shares: shares,
      createdAt: '2026-10-13T00:00:00.000Z',
    );

    test('opens the vault when the password is forgotten', () async {
      final session = await vault.setupVault('forgotten');
      await vault.saveAccounts([account('a1')], session);
      final rk = kit();
      await vault.setRecoveryKey(session, rk);

      final recovered = await vault.unlockWithRecoveryKey(rk.kitId, rk.key);

      expect(await vault.loadAccounts(recovered), [account('a1')]);
      // The user sets a new password straight after; the kit keeps working
      await vault.changePassword(recovered, 'remembered');
      await vault.unlockVault('remembered');
      expect((await vault.unlockWithRecoveryKey(rk.kitId, rk.key)).secretKey, session.secretKey);
    });

    test('ignores a kit record that someone else sealed into storage', () async {
      final session = await vault.setupVault('pw');
      final rk = kit();
      await vault.setRecoveryKey(session, rk);
      // Anyone can seal to the public key: a record naming the vault's kit, with a key of theirs
      final theirs = RecoveryKey(kitId: rk.kitId, key: randomBytes(32), threshold: 1, shares: 1, createdAt: rk.createdAt);
      await vault.saveEncryptedValue('backmycodes_recovery', {
        'kitId': theirs.kitId,
        'key': b64(theirs.key),
        'threshold': 1,
        'shares': 1,
        'createdAt': theirs.createdAt,
      }, session);

      // Not handed to an export to wrap its key under
      expect(await vault.loadRecoveryKey(session), isNull);
      // The real kit still opens the vault
      expect((await vault.unlockWithRecoveryKey(rk.kitId, rk.key)).secretKey, session.secretKey);
    });

    test('reports how the kit was made, and nothing once removed', () async {
      final session = await vault.setupVault('pw');
      final rk = kit(threshold: 2, shares: 3);
      await vault.setRecoveryKey(session, rk);

      expect(vault.recoveryKitInfo(), RecoveryKitInfo(kitId: rk.kitId, threshold: 2, shares: 3, createdAt: rk.createdAt));
      expect((await vault.loadRecoveryKey(session))?.key, rk.key);

      vault.removeRecoveryKey();
      expect(vault.recoveryKitInfo(), isNull);
      expect(await vault.loadRecoveryKey(session), isNull);
      await expectLater(vault.unlockWithRecoveryKey(rk.kitId, rk.key), throwsA(isA<KitNotFoundError>()));
    });

    test('stops an old kit working once a new one replaces it', () async {
      final session = await vault.setupVault('pw');
      final first = kit();
      await vault.setRecoveryKey(session, first);
      final second = kit();
      await vault.setRecoveryKey(session, second);

      await expectLater(vault.unlockWithRecoveryKey(first.kitId, first.key), throwsA(isA<KitNotFoundError>()));
      expect((await vault.unlockWithRecoveryKey(second.kitId, second.key)).secretKey, session.secretKey);
    });

    test('rejects a key rebuilt from the wrong pieces', () async {
      final session = await vault.setupVault('pw');
      final rk = kit();
      await vault.setRecoveryKey(session, rk);

      await expectLater(vault.unlockWithRecoveryKey(rk.kitId, Uint8List(32)), throwsA(isA<AesGcmAuthError>()));
    });

    test('finds the hidden vault a kit belongs to', () async {
      await vault.setupVault('first');
      final diary = await vault.createVault('Diary', 'third', listed: false);
      final session = await vault.unlockAnyVault('third', mainVault);
      final rk = kit();
      await vault.setRecoveryKey(session, rk);
      vaults.active = mainVault;

      await vault.unlockWithRecoveryKey(rk.kitId, rk.key);

      expect(vaults.active, diary);
    });
  });

  // openspec: replace-vault-key-pair, task 2.1
  group('loading while the key pair is being replaced', () {
    VaultSession newPair() {
      final pair = MlKem1024.keygen();
      return VaultSession(publicKey: pair.publicKey, secretKey: pair.secretKey);
    }

    /// The replacement's own value, as it is once the config names [next]: the old key, sealed to the new one.
    Future<void> startReplacing(VaultSession old, VaultSession next, [String id = mainVault]) async {
      vaults.active = id;
      await vault.saveEncryptedValue(keyKeyRotation, {'v': 1, 'previous': b64(old.secretKey), 'recovery': null, 'startedAt': 0}, next);
    }

    test('opens a value still sealed to the previous key', () async {
      final old = await vault.setupVault('pw');
      await vault.saveAccounts([account('a1')], old);
      final next = newPair();
      await startReplacing(old, next);

      expect(await vault.loadAccounts(next), [account('a1')]);
    });

    test('opens a value already sealed to the new key', () async {
      final old = await vault.setupVault('pw');
      final next = newPair();
      await startReplacing(old, next);
      await vault.saveAccounts([account('a2')], next);

      expect(await vault.loadAccounts(next), [account('a2')]);
    });

    test('still refuses a value sealed to neither key', () async {
      final old = await vault.setupVault('pw');
      final next = newPair();
      await startReplacing(old, next);
      await vault.saveAccounts([account('a3')], newPair());

      await expectLater(vault.loadAccounts(next), throwsA(isA<AesGcmAuthError>()));
    });

    test('falls back to nothing when the replacement value is sealed to a key the vault never got', () async {
      final old = await vault.setupVault('pw');
      await vault.saveAccounts([account('a1')], old);
      // Cut short before the commit: the config still names the old key, so the session is the old one
      await startReplacing(old, newPair());
      final other = newPair();

      expect(await vault.loadAccounts(old), [account('a1')]);
      await expectLater(vault.loadAccounts(other), throwsA(isA<AesGcmAuthError>()));
    });

    test('without a replacement, a value sealed to another key throws as before', () async {
      final old = await vault.setupVault('pw');
      await vault.saveAccounts([account('a1')], old);

      expect(store.getItem(keyKeyRotation), isNull);
      await expectLater(vault.loadAccounts(newPair()), throwsA(isA<AesGcmAuthError>()));
      expect(await vault.loadAccounts(old), [account('a1')]);
    });

    test("uses each vault's own replacement value", () async {
      final first = await vault.setupVault('first');
      await vault.saveAccounts([account('a1')], first);
      final work = await vault.createVault('Work', 'work', listed: true);
      final workSession = await vault.unlockAnyVault('work', work);
      await vault.saveAccounts([account('w1')], workSession);
      final next = newPair();
      await startReplacing(first, next);

      vaults.active = work;
      await expectLater(vault.loadAccounts(next), throwsA(isA<AesGcmAuthError>()));
      vaults.active = mainVault;
      expect(await vault.loadAccounts(next), [account('a1')]);
    });
  });

  // openspec: add-security-key-codes, tasks 3.2 and 3.4
  group('what the vault remembers of a security key', () {
    Map<String, String?> snapshot() => {for (final key in store.storedKeys()) key: store.getItem(key)};
    final accessKey = Uint8List.fromList(List.generate(16, (i) => i * 3));

    test('a vault that never read a key stores neither value', () async {
      final session = await vault.setupVault('pw');
      await vault.saveAccounts([_acme], session);

      expect(await vault.loadKeyAccounts(session), isEmpty);
      expect(await vault.loadKeyAccess(session), isEmpty);
      await vault.saveKeyAccounts(const [], session);
      await vault.saveKeyAccess(const {}, session);

      expect(store.getItem('backmycodes_key_account_data'), isNull);
      expect(store.getItem('backmycodes_key_access'), isNull);
    });

    test('both are sealed like the accounts, and read back', () async {
      final session = await vault.setupVault('pw');

      await vault.saveKeyAccounts([_onKey], session);
      await vault.saveKeyAccess({_onKey.device: accessKey}, session);

      for (final key in ['backmycodes_key_account_data', 'backmycodes_key_access']) {
        final stored = jsonDecode(store.getItem(key)!) as Map<String, Object?>;
        expect(stored.keys.toList()..sort(), ['ct', 'kemCT', 'nonce'], reason: key);
        expect(store.getItem(key), isNot(contains('alice')), reason: key);
        expect(store.getItem(key), isNot(contains(_onKey.device)), reason: key);
      }
      expect(await vault.loadKeyAccounts(session), [_onKey]);
      expect(await vault.loadKeyAccess(session), {_onKey.device: accessKey});
      expect(vault.sealedValueKeys(mainVault), containsAll(['backmycodes_key_account_data', 'backmycodes_key_access']));
    });

    test('each goes from storage once it is empty again', () async {
      final session = await vault.setupVault('pw');
      await vault.saveKeyAccounts([_onKey], session);
      await vault.saveKeyAccess({_onKey.device: accessKey}, session);

      await vault.saveKeyAccounts(const [], session);
      await vault.saveKeyAccess(const {}, session);

      expect(store.getItem('backmycodes_key_account_data'), isNull);
      expect(store.getItem('backmycodes_key_access'), isNull);
    });

    test('a key read in a hidden vault changes nothing outside that vault’s own sealed values', () async {
      final listed = await vault.setupVault('first');
      await vault.saveAccounts([_acme], listed);
      await vault.saveKeyAccounts([_onKey.copyWith(id: 'listed-one', device: 'aaaaaaaaaaaaaaaa')], listed);
      final hidden = await vault.createVault('Diary', 'third', listed: false);
      final diary = await vault.unlockAnyVault('third', mainVault);
      expect(vaults.active, hidden);
      await vault.saveAccounts([account('d1')], diary);
      final before = snapshot();

      await vault.saveKeyAccounts([_onKey], diary);
      await vault.saveKeyAccess({_onKey.device: accessKey}, diary);

      final after = snapshot();
      final added = after.keys.toSet().difference(before.keys.toSet());
      expect(added, {'backmycodes_key_account_data::$hidden', 'backmycodes_key_access::$hidden'});
      for (final key in before.keys) {
        expect(after[key], before[key], reason: '$key is the registry, a preference or another vault’s');
      }
      // Nothing readable names the key, its accounts or that a key was read.
      for (final value in after.values) {
        expect(value, isNot(contains('YubiKey')));
        expect(value, isNot(contains('alice@example.org')));
        expect(value, isNot(contains(_onKey.device)));
      }
      expect(vaults.hiddenVaultIds(), [hidden]);

      // The listed vault lists only what it read itself.
      vaults.active = mainVault;
      expect([for (final entry in await vault.loadKeyAccounts(listed)) entry.id], ['listed-one']);
      expect(await vault.loadKeyAccess(listed), isEmpty);
    });
  });
}
