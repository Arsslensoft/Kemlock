import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/ml_kem.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/sealed_value.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../helpers/old_biometric_entry.dart';
import 'old_vault.dart';
import 'rotation_helpers.dart';

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

/// The vault's values are authenticated to its private key and to the key
/// each sits under (sealed_value.dart).
void main() {
  late Phone phone;

  setUp(() => phone = Phone(KeyValueStore.memory()));

  group('a sealed value', () {
    test('has the shape of any other, and opens as versions before it open one', () async {
      final pair = MlKem1024.keygen();
      final sealed = await sealValue(_json('hi'), pair.publicKey, storageKey: 'k', authKey: sealAuthKey(pair.secretKey));

      expect(sealed.keys, ['kemCT', 'nonce', 'ct']);
      expect(utf8.decode(await openRaw(jsonEncode(sealed), pair.secretKey)), '"hi"');
    });

    test('is authenticated only for the storage key and the key pair it was sealed for', () async {
      final pair = MlKem1024.keygen();
      final other = MlKem1024.keygen();
      final sealed = await sealValue(_json(1), pair.publicKey, storageKey: 'backmycodes_sync', authKey: sealAuthKey(pair.secretKey));
      final byAnyone = await sealValue(_json(1), pair.publicKey, storageKey: 'backmycodes_sync');
      final byOther = await sealValue(_json(1), pair.publicKey, storageKey: 'backmycodes_sync', authKey: sealAuthKey(other.secretKey));

      Future<bool> verified(Map<String, String> value, String key) async =>
          (await openSealedValue(value, pair.secretKey, storageKey: key)).verified;
      expect(await verified(sealed, 'backmycodes_sync'), isTrue);
      expect(await verified(sealed, 'backmycodes_sync::0a0b0c0d0e0f'), isFalse);
      expect(await verified(sealed, 'backmycodes_vault_data'), isFalse);
      expect(await verified(byAnyone, 'backmycodes_sync'), isFalse);
      expect(await verified(byOther, 'backmycodes_sync'), isFalse);
      expect((await openSealedValue(byAnyone, pair.secretKey, storageKey: 'backmycodes_sync')).plain, _json(1));
    });

    test('opens with no other key pair', () async {
      final pair = MlKem1024.keygen();
      final sealed = await sealValue(_json(1), pair.publicKey, storageKey: 'k', authKey: sealAuthKey(pair.secretKey));

      await expectLater(openSealedValue(sealed, MlKem1024.keygen().secretKey, storageKey: 'k'), throwsA(isA<AesGcmAuthError>()));
    });

    test('the nonce of a wrap says whether the values are authenticated', () {
      final first = authenticatedWrapNonce();

      expect(first, hasLength(12));
      expect(isAuthenticatedWrapNonce(b64(first)), isTrue);
      expect(first, isNot(authenticatedWrapNonce()));
      expect(isAuthenticatedWrapNonce(b64(Uint8List(12))), isFalse);
      expect(isAuthenticatedWrapNonce(b64(first.sublist(0, 11))), isFalse);
      expect(isAuthenticatedWrapNonce(b64([...first, 0])), isFalse);
      expect(isAuthenticatedWrapNonce('not base64 !'), isFalse);
      expect(isAuthenticatedWrapNonce(null), isFalse);
      expect(isAuthenticatedWrapNonce(12), isFalse);
    });
  });

  group('a new vault', () {
    test('is authenticated from the start, and so is every way it opens', () async {
      final session = await phone.vault.setupVault('pw');
      final kit = newKit();
      await phone.vault.setRecoveryKey(session, kit);
      await phone.vault.enableBiometricUnlock(session, 'Turn it on');

      expect(session.authenticated, isTrue);
      expect(saysAuthenticated(phone), isTrue);
      expect(isAuthenticatedWrapNonce((configOf(phone)['recovery']! as Map<String, Object?>)['nonce']), isTrue);
      expect(isAuthenticatedWrapNonce((jsonDecode(phone.store.getItem(keyHardwareBio)!) as Map<String, Object?>)['nonce']), isTrue);
      expect((await phone.vault.unlockAnyVault('pw', mainVault)).authenticated, isTrue);
      expect((await phone.vault.unlockVault('pw')).authenticated, isTrue);
      expect((await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key)).authenticated, isTrue);
      expect((await phone.vault.unlockWithBiometrics('Unlock', _NoPrompt())).session!.authenticated, isTrue);
      await expectEveryValueAuthenticated(phone, session);

      final work = await phone.vault.createVault('Work', 'work', listed: false);
      expect(saysAuthenticated(phone, work), isTrue);
      expect((await phone.vault.unlockAnyVault('work', mainVault)).authenticated, isTrue);
    });

    test('refuses a value sealed with the public key alone, as anyone can seal one', () async {
      final session = await phone.vault.setupVault('pw');
      await phone.vault.saveAccounts([rotationAccount], session);
      phone.store.setItem(keySyncSettings, await sealRaw(_json(_theirSync), session.publicKey));
      final opened = await phone.vault.unlockAnyVault('pw', mainVault);

      await expectLater(phone.vault.loadEncryptedValue(keySyncSettings, opened), throwsA(isA<AesGcmAuthError>()));
      expect(await phone.vault.loadAccounts(opened), [rotationAccount]);
      // A whole list of accounts of theirs
      phone.store.setItem('backmycodes_vault_data', await sealRaw(_json([]), session.publicKey));
      await expectLater(phone.vault.loadAccounts(opened), throwsA(isA<AesGcmAuthError>()));
    });

    test('refuses a value of its own moved to another key', () async {
      final session = await phone.vault.setupVault('pw');
      await phone.vault.saveEncryptedValue(keySyncSettings, {'enabled': false}, session);
      await phone.vault.saveEncryptedValue(keySyncState, _theirSync, session);
      phone.store.setItem(keySyncSettings, phone.store.getItem(keySyncState)!);

      await expectLater(phone.vault.loadEncryptedValue(keySyncSettings, session), throwsA(isA<AesGcmAuthError>()));
      expect(await phone.vault.loadEncryptedValue(keySyncState, session), _theirSync);
    });

    test('its values open in a session that demands nothing of them', () async {
      final session = await phone.vault.setupVault('pw');
      await fillVault(phone.vault, phone.store, keyFuture, session);

      await expectEveryItem(phone.vault, VaultSession(publicKey: session.publicKey, secretKey: session.secretKey));
    });
  });

  group('a vault from before values were authenticated', () {
    late VaultSession session;

    setUp(() async {
      session = await phone.vault.setupVault('pw');
      await fillVault(phone.vault, phone.store, keyFuture, session);
      await makeOld(phone, session, 'pw');
      phone.store.setItem(keySyncSettings, await sealRaw(_json(_theirSync), session.publicKey));
    });

    test('reads every value as it always did, those anyone could have sealed included', () async {
      final opened = await phone.vault.unlockVault('pw');

      expect(opened.authenticated, isFalse);
      expect(await phone.vault.loadAccounts(opened), [rotationAccount]);
      expect(await phone.vault.loadEncryptedValue(keySyncSettings, opened), _theirSync);
    });

    test('gets no wrap that would say its values are authenticated, which would shut them out', () async {
      final opened = await phone.vault.unlockVault('pw');
      final kit = newKit();
      await phone.vault.setRecoveryKey(opened, kit);
      await phone.vault.enableBiometricUnlock(opened, 'Turn it on');

      expect(isAuthenticatedWrapNonce((configOf(phone)['recovery']! as Map<String, Object?>)['nonce']), isFalse);
      expect(isAuthenticatedWrapNonce((jsonDecode(phone.store.getItem(keyHardwareBio)!) as Map<String, Object?>)['nonce']), isFalse);
      final byKit = await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
      expect(byKit.authenticated, isFalse);
      expect(await phone.vault.loadEncryptedValue(keySyncSettings, byKit), _theirSync);
      expect((await phone.vault.unlockWithBiometrics('Unlock', _NoPrompt())).session!.authenticated, isFalse);
    });
  });

  // What the store itself writes with the public key alone, when the private key isn't there
  group('key info', () {
    late VaultSession session;

    setUp(() async => session = await phone.vault.setupVault('pw'));

    Future<void> forge(Map<String, Object?> info) async => phone.store.setItem(keyKeyInfo, await sealRaw(_json(info), session.publicKey));

    test('sealed with the public key alone may say the key pair is exposed, never that it is fine', () async {
      await forge({'madeAt': 1, 'exposed': true, 'asked': true});
      expect(await phone.vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: false));

      await forge({'madeAt': 1, 'exposed': false, 'asked': true});
      expect(await phone.vault.loadKeyInfo(session), isNull);
    });

    test('sealed with the public key alone is believed as before in a vault from before', () async {
      await makeOld(phone, session, 'pw');
      await forge({'madeAt': 1, 'exposed': false, 'asked': true});

      expect(
        await phone.vault.loadKeyInfo(await phone.vault.unlockVault('pw')),
        KeyInfo(madeAt: DateTime.fromMillisecondsSinceEpoch(1), exposed: false, asked: true),
      );
    });

    test('an old entry gone while the vault was shut still says it is exposed, and asking about it is kept', () async {
      phone.store.removeItem(keyKeyInfo);
      await writeOldBiometricEntry(phone.store, phone.vaults, session);
      phone.unlockKeys.available = false;
      // The phone can't take the entry into its hardware: it goes, and the key info says why, with the public key alone
      expect((await phone.vault.unlockWithBiometrics('Unlock', _NoPrompt())).outcome, BiometricOutcome.unsupported);

      final opened = await phone.vault.unlockAnyVault('pw', mainVault);
      expect(await phone.vault.loadKeyInfo(opened), const KeyInfo(exposed: true, asked: false));
      await phone.vault.markKeyAsked(opened);
      expect(await phone.vault.loadKeyInfo(opened), const KeyInfo(exposed: true, asked: true));
    });

    test('that says the key pair is fine without being authenticated is made again at the next unlock', () async {
      await forge({'madeAt': 1, 'exposed': false, 'asked': true});
      await phone.vault.enableBiometricUnlock(session, 'Turn it on');

      final opened = await phone.vault.unlockAnyVault('pw', mainVault);

      // A hardware entry may have been an old one moved over, as for a vault first opened by this version
      expect(await phone.vault.loadKeyInfo(opened), const KeyInfo(exposed: true, asked: false));
      await expectEveryValueAuthenticated(phone, opened);
    });
  });

  group('replacing the key pair', () {
    test('of an authenticated vault gives one whose values and wraps are authenticated', () async {
      final old = await phone.vault.setupVault('pw');
      await fillVault(phone.vault, phone.store, keyFuture, old);
      await phone.vault.setRecoveryKey(old, newKit());
      final kit = newKit();

      final next = await phone.vault.replaceKeyPair(old, 'pw', kit: kit);

      expect(next.authenticated, isTrue);
      expect(saysAuthenticated(phone), isTrue);
      expect(isAuthenticatedWrapNonce((configOf(phone)['recovery']! as Map<String, Object?>)['nonce']), isTrue);
      await expectEveryValueAuthenticated(phone, next);
      final byKit = await phone.vault.unlockWithRecoveryKey(kit.kitId, kit.key);
      expect(byKit.authenticated, isTrue);
      await expectEveryItem(phone.vault, byKit);
      phone.store.setItem(keySyncSettings, await sealRaw(_json(_theirSync), next.publicKey));
      await expectLater(phone.vault.loadEncryptedValue(keySyncSettings, byKit), throwsA(isA<AesGcmAuthError>()));
    });

    test('of a vault from before keeps its wraps saying nothing, and every value', () async {
      final old = await phone.vault.setupVault('pw');
      await fillVault(phone.vault, phone.store, keyFuture, old);
      await makeOld(phone, old, 'pw');
      final opened = await phone.vault.unlockVault('pw');

      final next = await phone.vault.replaceKeyPair(opened, 'pw');

      expect(next.authenticated, isFalse);
      expect(saysAuthenticated(phone), isFalse);
      await expectEveryItem(phone.vault, next);
      // Sealed again by the new private key all the same
      await expectEveryValueAuthenticated(phone, next);
    });
  });
}
