// What a vault with biometric unlock on sends elsewhere: an encrypted
// export, a sync file and a Vaultwarden entry. The biometric entries, the
// old one and the one the hardware key opens, belong to the phone, so none
// of them may hold either, their names or the seal keys, in the file or
// once decrypted.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/ml_kem.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_formats.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import '../features/sync/fake_webdav.dart';
import '../helpers/old_biometric_entry.dart';
import 'fast_kdf.dart';

const _account = OtpAccount(id: 'a1', issuer: 'GitHub', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
const _codes = BackupService(
  id: 's1',
  serviceName: 'GitHub',
  codes: [BackupCode(code: 'abcd-1234')],
  addedAt: 1,
);

void main() {
  late KeyValueStore store;
  late FakeUnlockKeys keys;
  late VaultStore vault;
  late Lists lists;

  /// Every value of the biometric entry, and the words that would name it.
  late List<String> forbidden;

  setUp(() async {
    store = KeyValueStore.memory();
    final vaults = VaultRegistry(store);
    keys = FakeUnlockKeys(android: true);
    vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: keys);
    final session = await vault.setupVault('pw');
    await vault.saveAccounts([_account], session);
    await vault.saveBackupServices([_codes], session);
    await vault.enableBiometricUnlock(session, 'Turn it on');
    await writeOldBiometricEntry(store, vaults, session);
    final old = jsonDecode(store.getItem('backmycodes_native_bio')!) as Map<String, Object?>;
    final hardware = jsonDecode(store.getItem('backmycodes_hardware_bio')!) as Map<String, Object?>;
    forbidden = [
      'native_bio',
      'hardware_bio',
      'sealKey',
      'nativeSk',
      for (final value in old.values) value! as String,
      for (final value in hardware.values.whereType<String>()) value,
      b64(keys.keys[mainVault]!),
    ];
    lists = Lists(accounts: await vault.loadAccounts(session), backupServices: await vault.loadBackupServices(session));
  });

  void expectNoBiometricEntry(String text, String what) {
    for (final word in forbidden) {
      expect(text, isNot(contains(word)), reason: '$what holds $word');
    }
  }

  test('an encrypted export holds no biometric entry', () async {
    final text = await exportVault(lists.accounts, lists.backupServices, 'export pw', deriveKey: fastKdf);

    // Opened by hand, as another app would, rather than through the import
    final file = jsonDecode(text) as Map<String, Object?>;
    final config = file['config']! as Map<String, Object?>;
    final kek = await fastKdf('export pw', unb64(config['salt']! as String));
    final secretKey = await aesGcmDecrypt(kek, unb64(config['skNonce']! as String), unb64(config['skEnc']! as String));
    final data = file['vault']! as Map<String, Object?>;
    final shared = MlKem1024.decapsulate(unb64(data['kemCT']! as String), secretKey);
    final plain = utf8.decode(await aesGcmDecrypt(shared, unb64(data['nonce']! as String), unb64(data['ct']! as String)));

    expect(plain, contains('JBSWY3DPEHPK3PXP'));
    expectNoBiometricEntry(text, 'the export file');
    expectNoBiometricEntry(plain, 'the decrypted export');
  });

  test('a sync file holds no biometric entry', () async {
    final server = FakeWebDav();
    const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
    final key = randomBytes(32);

    await syncScope(
      WebDav(server.client),
      SyncTarget(dav: dav, file: syncFile, key: b64(key)),
      scopeLists(lists, null),
      const [],
      now: 1000,
    );

    final text = server.files['/files/me/Kemlock/$syncFile']!.text;
    final file = jsonDecode(text) as Map<String, Object?>;
    final plain = utf8.decode(await aesGcmDecrypt(key, unb64(file['nonce']! as String), unb64(file['ct']! as String)));
    expect(plain, contains('JBSWY3DPEHPK3PXP'));
    expectNoBiometricEntry(text, 'the sync file');
    expectNoBiometricEntry(plain, 'the decrypted sync file');
    // Nor anything else the phone sent the server
    expectNoBiometricEntry(server.requests.map((request) => '${request.url} ${request.body}').join('\n'), 'the requests');
  });

  test('a Vaultwarden entry, plain or sealed, holds no biometric entry', () async {
    final userKey = BwKey.random();
    final writer = VwWriter(userKey: userKey, userId: '00000000-0000-4000-8000-000000000001');
    final sealKey = randomBytes(32);

    for (final entry in <Object>[...lists.accounts, ...lists.backupServices]) {
      for (final form in VaultwardenMode.values) {
        final item = await writer.create(entry, form: form, home: 'home1', folderId: 'folder1', sealKey: sealKey);
        final text = jsonEncode(item);
        // Every encrypted string in the item, decrypted with the account's key
        final opened = <String>[];
        Future<void> open(Object? value) async {
          if (value is Map) {
            for (final child in value.values) {
              await open(child);
            }
          } else if (value is List) {
            for (final child in value) {
              await open(child);
            }
          } else if (value is String && value.startsWith('2.')) {
            final plain = await bwDecryptString(value, userKey);
            opened.add(plain);
            if (plain.startsWith('kemlock-sealed:')) opened.add(jsonEncode(await _sealedJson(plain, sealKey)));
          }
        }

        await open(item);
        expect(opened, isNotEmpty);
        expectNoBiometricEntry(text, 'the $form item');
        expectNoBiometricEntry(opened.join('\n'), 'the decrypted $form item');
      }
    }
  });
}

/// What a sealed Vaultwarden value holds, as JSON.
Future<Object?> _sealedJson(String text, Uint8List key) async => switch (await openSealedEntry(text, key)) {
  final OtpAccount account => account.toJson(),
  final BackupService service => service.toJson(),
  final other => other.toString(),
};
