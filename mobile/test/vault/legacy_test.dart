// Backward-compatibility guard for data encrypted by earlier releases.
//
// The fixture was made by app v0.1.0 (@noble/post-quantum 0.5.4,
// @noble/hashes 2.0.1) and must NEVER be regenerated: it proves that vaults,
// file exports and QR exports created by older builds still open in the
// Flutter app, through the same code the app runs, with the real scrypt
// parameters. If one of these tests fails, existing users would be locked
// out of their data.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/qr_transfer.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/legacy-v0.1.0.json').readAsStringSync()) as Map<String, Object?>;
  final passwords = fixture['passwords']! as Map<String, Object?>;
  final expected = fixture['expected']! as Map<String, Object?>;
  final expectedAccounts = [for (final a in expected['accounts']! as List<Object?>) OtpAccount.fromJson(a! as Map<String, Object?>)];
  final expectedServices = [
    for (final s in expected['backupServices']! as List<Object?>) BackupService.fromJson(s! as Map<String, Object?>),
  ];

  List<Map<String, Object?>> withoutIds(Iterable<Map<String, Object?>> items) => [
    for (final item in items)
      {...item}
        ..remove('id')
        ..remove('addedAt'),
  ];

  late VaultStore vault;

  setUp(() {
    final store = KeyValueStore.memory({...(fixture['vaultStorage']! as Map<String, Object?>).cast<String, String>()});
    vault = VaultStore(store, VaultRegistry(store));
  });

  test('unlocks a v0.1.0 vault and decrypts its contents', () async {
    final session = await vault.unlockVault(passwords['vault']! as String);

    expect(await vault.loadAccounts(session), expectedAccounts);
    expect(await vault.loadBackupServices(session), expectedServices);
  });

  test('a v0.1.0 vault moves over to authenticated values at its first password unlock, and opens again as it was', () async {
    final first = await vault.unlockAnyVault(passwords['vault']! as String, mainVault);

    expect(first.authenticated, isTrue);
    expect(await vault.loadAccounts(first), expectedAccounts);
    expect(await vault.loadBackupServices(first), expectedServices);
    final again = await vault.unlockAnyVault(passwords['vault']! as String, mainVault);
    expect(again.authenticated, isTrue);
    expect(again.secretKey, first.secretKey);
    expect(await vault.loadAccounts(again), expectedAccounts);
    expect(await vault.loadBackupServices(again), expectedServices);
  });

  test('still rejects the wrong password for a v0.1.0 vault', () async {
    await expectLater(vault.unlockVault('not-the-password'), throwsA(isA<AesGcmAuthError>()));
  });

  test('imports a v0.1.0 encrypted file export', () async {
    final payload = await importVault(fixture['fileExport']! as String, passwords['fileExport']! as String);

    expect(payload.accounts, expectedAccounts);
    expect(payload.backupServices, expectedServices);
  });

  test('imports a v0.1.0 encrypted QR export', () async {
    final chunks = (fixture['qrExport']! as List<Object?>).cast<String>();
    final payload = await importVaultQr(chunks, passwords['qrExport']! as String);

    // QR import gives fresh ids and times by design
    expect(withoutIds(payload.accounts.map((a) => a.toJson())), withoutIds(expectedAccounts.map((a) => a.toJson())));
    expect(withoutIds(payload.backupServices.map((s) => s.toJson())), withoutIds(expectedServices.map((s) => s.toJson())));
  });
}
