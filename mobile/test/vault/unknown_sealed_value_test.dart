import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/spaces/space_head_store.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

/// A key no version knows yet, sealed to the vault the way every value is,
/// as a newer version might add one.
const _future = 'backmycodes_future_thing';

/// What a Kemlock Server sign-in seals, as `km_session.dart` names it, the progress of a move off the old sync,
/// and the anchors of the spaces' chains: the device's own and the value the vault's sync carries between the
/// account's devices (`space_head_store.dart`).
const _kemlockKeys = [keyKemlockSession, keyKemlockAccount, keyKemlockCache, keyKemlockMove, keySpaceHeads, keySpaceAnchorsSynced];

const _account = OtpAccount(id: 'a1', issuer: 'ACME', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
const _service = BackupService(
  id: 's1',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'abcd-1234')],
  addedAt: 0,
);
const _note = SecureNote(id: 'n1', title: 'Passport', text: 'In the drawer', addedAt: 0);
const _key = VaultKey(
  id: 'k1',
  name: 'laptop',
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: 'MC4CAQAwBQYDK2VwBCIEIA==',
  publicKey: 'MCowBQYDK2VwAyEA',
  origin: KeyOrigin.generated,
  addedAt: 0,
);
const _passkey = Passkey(
  id: 'p1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  userHandle: 'dXNlcg',
  userName: 'octocat',
  privateKey: 'MIGHAgEAMBMGByqGSM49AgEG',
  addedAt: 0,
);

/// What today's code does with a sealed value under a key it doesn't know
/// (openspec: replace-vault-key-pair, task 1.1): it leaves it alone. A
/// replacement of the vault's key has to keep that true, so a key a newer
/// version wrote survives an older one.
void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vault;

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
  });

  test('saving and loading every known kind leaves it byte for byte', () async {
    final session = await vault.setupVault('pw');
    await vault.saveEncryptedValue(_future, {'from': 'a newer version'}, session);
    final before = store.getItem(_future);

    await vault.saveAccounts([_account], session);
    await vault.saveBackupServices([_service], session);
    await vault.saveNotes([_note], session);
    await vault.saveKeys([_key], session);
    await vault.savePasskeys([_passkey], session);
    await vault.savePasskeyInboxKey(randomBytes(138), session);
    await vault.setRecoveryKey(
      session,
      RecoveryKey(kitId: 'kit', key: randomBytes(32), threshold: 1, shares: 1, createdAt: '2026-11-16T00:00:00.000Z'),
    );
    // The sync settings and state, as sync_store.dart keeps them, and the Vaultwarden session
    await vault.saveEncryptedValue('backmycodes_sync', {'enabled': true}, session);
    await vault.saveEncryptedValue('backmycodes_sync_state', {'personal': {}}, session);
    await vault.saveEncryptedValue(keyVaultwardenSession, {'server': 'https://vw.example'}, session);
    // Kemlock Server's session, account and cache
    for (final key in _kemlockKeys) {
      await vault.saveEncryptedValue(key, {'from': 'kemlock'}, session);
    }
    await vault.loadAccounts(session);
    await vault.loadBackupServices(session);
    await vault.loadNotes(session);
    await vault.loadKeys(session);
    await vault.loadPasskeys(session);
    await vault.loadPasskeyInboxKey(session);
    await vault.loadRecoveryKey(session);

    expect(store.getItem(_future), before);
    expect(await vault.loadEncryptedValue(_future, session), {'from': 'a newer version'});
    for (final key in _kemlockKeys) {
      expect(await vault.loadEncryptedValue(key, session), {'from': 'kemlock'});
    }
  });

  test('removing a vault deletes its kemlock values with it, and leaves the other vault’s', () async {
    final session = await vault.setupVault('pw');
    // A value is saved under the active vault's key, whichever session seals it, so each vault saves its own
    // while it is the active one
    for (final key in _kemlockKeys) {
      await vault.saveEncryptedValue(key, {'vault': 'first'}, session);
    }
    final other = await vault.createVault('Work', 'work pw', listed: true);
    vaults.active = other;
    final otherSession = await vault.unlockVault('work pw');
    for (final key in _kemlockKeys) {
      await vault.saveEncryptedValue(key, {'vault': 'work'}, otherSession);
    }

    vaults.removeVaultData(other);

    for (final key in _kemlockKeys) {
      expect(store.getItem(vaults.vaultKey(key, other)), isNull);
      expect(store.getItem(key), isNotNull);
    }
  });

  test('changing the password keeps it, and it still opens', () async {
    final session = await vault.setupVault('pw');
    await vault.saveEncryptedValue(_future, {'from': 'a newer version'}, session);
    final before = store.getItem(_future);

    await vault.changePassword(session, 'new pw');
    final reopened = await vault.unlockVault('new pw');

    expect(store.getItem(_future), before);
    expect(await vault.loadEncryptedValue(_future, reopened), {'from': 'a newer version'});
  });

  test('removing the first vault deletes it with the vault, and leaves the other vault’s', () async {
    final session = await vault.setupVault('pw');
    await vault.saveEncryptedValue(_future, {'vault': 'first'}, session);
    final other = await vault.createVault('Work', 'work pw', listed: true);
    vaults.active = other;
    final otherSession = await vault.unlockVault('work pw');
    await vault.saveEncryptedValue(_future, {'vault': 'work'}, otherSession);

    vaults.removeVaultData(mainVault);

    expect(store.getItem(_future), isNull);
    expect(store.getItem(vaults.vaultKey(_future, other)), isNotNull);
  });

  test('removing another vault deletes its copy, and leaves the first vault’s', () async {
    final session = await vault.setupVault('pw');
    await vault.saveEncryptedValue(_future, {'vault': 'first'}, session);
    final other = await vault.createVault('Work', 'work pw', listed: true);
    vaults.active = other;
    final otherSession = await vault.unlockVault('work pw');
    await vault.saveEncryptedValue(_future, {'vault': 'work'}, otherSession);
    final first = store.getItem(_future);

    vaults.removeVaultData(other);

    expect(store.getItem(vaults.vaultKey(_future, other)), isNull);
    expect(store.getItem(_future), first);
  });
}
