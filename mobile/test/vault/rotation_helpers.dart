import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/ml_kem.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/sealed_value.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

/// What the vault of the key replacement tests holds: one of every kind, the
/// sync and Vaultwarden settings, and a key no version knows yet.
const rotationAccount = OtpAccount(id: 'a1', issuer: 'ACME', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const rotationService = BackupService(
  id: 's1',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'abcd-1234')],
  addedAt: 0,
);
const rotationNote = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 0);
const rotationKey = VaultKey(
  id: 'k1',
  name: 'laptop',
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: 'MC4CAQAwBQYDK2VwBCIEIA==',
  publicKey: 'MCowBQYDK2VwAyEA',
  origin: KeyOrigin.generated,
  addedAt: 0,
);
const rotationPasskey = Passkey(
  id: 'p1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  userHandle: 'dXNlcg',
  userName: 'octocat',
  privateKey: 'MIGHAgEAMBMGByqGSM49AgEG',
  addedAt: 0,
);

/// The sync settings and state, as `sync_store.dart` keeps them.
const keySyncSettings = 'backmycodes_sync';
const keySyncState = 'backmycodes_sync_state';

/// A key a newer version might add.
const keyFuture = 'backmycodes_future_thing';

/// Plaintext a value of a newer version might hold, which decoding and
/// encoding JSON again would change (`é`, `1.0`): only resealing it as
/// it is keeps it byte for byte.
final futurePlain = Uint8List.fromList(utf8.encode(r'{"name":"café","n":1.0}'));

/// [plain] sealed to [publicKey] with nothing but that key, as versions
/// before authenticated seals sealed every value, and as anyone who can
/// write the storage can.
Future<String> sealRaw(Uint8List plain, Uint8List publicKey) async {
  final kem = MlKem1024.encapsulate(publicKey);
  final sealed = await aesGcmEncrypt(kem.sharedSecret, plain);
  return jsonEncode({'kemCT': b64(kem.cipherText), 'nonce': b64(sealed.nonce), 'ct': b64(sealed.ct)});
}

/// [plain] sealed for [storageKey] by [session]'s private key, as the store
/// seals every value, and as a newer version would seal its own.
Future<String> sealAs(String storageKey, Uint8List plain, VaultSession session) async =>
    jsonEncode(await sealValue(plain, session.publicKey, storageKey: storageKey, authKey: sealAuthKey(session.secretKey)));

/// What a value sealed as [sealRaw] or [sealAs] does holds, opened with [secretKey].
Future<Uint8List> openRaw(String raw, Uint8List secretKey) {
  final stored = jsonDecode(raw) as Map<String, Object?>;
  final secret = MlKem1024.decapsulate(unb64(stored['kemCT']! as String), secretKey);
  return aesGcmDecrypt(secret, unb64(stored['nonce']! as String), unb64(stored['ct']! as String));
}

/// Fills the active vault with one of every kind, the sync and Vaultwarden
/// settings, and [keyFuture], stored under [futureStorageKey], sealed as a
/// newer version would write it.
Future<void> fillVault(VaultStore vault, KeyValueStore store, String futureStorageKey, VaultSession session) async {
  await vault.saveAccounts([rotationAccount], session);
  await vault.saveBackupServices([rotationService], session);
  await vault.saveNotes([rotationNote], session);
  await vault.saveKeys([rotationKey], session);
  await vault.savePasskeys([rotationPasskey], session);
  await vault.saveEncryptedValue(keySyncSettings, {'enabled': true, 'passphraseKey': 'c2VjcmV0'}, session);
  await vault.saveEncryptedValue(keySyncState, {
    'personal': {'etag': '"1"'},
  }, session);
  await vault.saveEncryptedValue(keyVaultwardenSession, {'server': 'https://vw.example', 'refreshToken': 'r'}, session);
  store.setItem(futureStorageKey, await sealAs(futureStorageKey, futurePlain, session));
}

/// Checks that every item [fillVault] wrote reads back unchanged in [session].
Future<void> expectEveryItem(VaultStore vault, VaultSession session) async {
  expect(await vault.loadAccounts(session), [rotationAccount]);
  expect(await vault.loadBackupServices(session), [rotationService]);
  expect(await vault.loadNotes(session), [rotationNote]);
  expect(await vault.loadKeys(session), [rotationKey]);
  expect(await vault.loadPasskeys(session), [rotationPasskey]);
  expect(await vault.loadEncryptedValue(keySyncSettings, session), {'enabled': true, 'passphraseKey': 'c2VjcmV0'});
  expect(await vault.loadEncryptedValue(keySyncState, session), {
    'personal': {'etag': '"1"'},
  });
  expect(await vault.loadEncryptedValue(keyVaultwardenSession, session), {'server': 'https://vw.example', 'refreshToken': 'r'});
  expect(await vault.loadEncryptedValue(keyFuture, session), {'name': 'café', 'n': 1.0});
}

/// The app's registry and vault store over one key-value store, as a phone
/// has them at each start.
class Phone {
  Phone(this.store, {FakeUnlockKeys? unlockKeys}) : vaults = VaultRegistry(store), unlockKeys = unlockKeys ?? FakeUnlockKeys() {
    vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: this.unlockKeys);
  }

  final KeyValueStore store;
  final VaultRegistry vaults;
  final FakeUnlockKeys unlockKeys;
  late final VaultStore vault;

  /// Every stored key and its value.
  Map<String, String?> get snapshot => {for (final key in store.storedKeys()) key: store.getItem(key)};
}

/// A new Recovery Kit's key, as the kit sheet makes it.
RecoveryKey newKit({int threshold = 1, int shares = 1}) => RecoveryKey(
  kitId: b64url(randomBytes(5)),
  key: randomBytes(32),
  threshold: threshold,
  shares: shares,
  createdAt: '2026-11-16T00:00:00.000Z',
);
