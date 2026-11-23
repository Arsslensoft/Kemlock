import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/attachment_format.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/export_archive.dart';
import 'package:kemlock/vault/vault_export.dart';

/// Opens the exports in test/fixtures/vault-items, which are never
/// regenerated (see the README there): if one of these fails, files people
/// already exported have stopped opening.
const _dir = 'test/fixtures/vault-items';

void _expectItems(VaultExportPayload payload) {
  expect(payload.accounts.single.issuer, 'GitHub');
  expect(payload.backupServices.single.codes.single.code, 'aaaa-1111');
  final key = payload.keys.single;
  expect((key.name, key.kind, key.algorithm, key.origin), ('laptop', KeyKind.ssh, 'ed25519', KeyOrigin.generated));
  expect(key.publicKey, 'MCowBQYDK2VwAyEAGFpCGs9p6samlflgByMlkn08De66RkiCJwGX5JhQLTQ=');
  final note = payload.notes.single;
  expect((note.title, note.text, note.isPinned), ('Passport', 'In the drawer, left side', true));
  expect(note.tags, ['travel']);
  expect(
    [for (final file in note.files) (file.id, file.name, file.size)],
    [('AAECAwQFBgcICQoLDA0ODw', 'passport-scan.pdf', 31), ('EBESExQVFhcYGRobHB0eHw', 'photo.jpg', kma1ChunkLength + 10)],
  );
  final passkey = payload.passkeys.single;
  expect((passkey.rpId, passkey.userName, passkey.credentialId), ('github.com', 'octocat@example.com', 'T41cDpsqTH6NHyo7TF1ufw'));
  expect(passkey.privateKey, startsWith('MIGHAgEAMBMGByqGSM49AgEG'));
}

void main() {
  test('opens the encrypted export with its password', () async {
    final payload = await importVault(File('$_dir/export-encrypted.json').readAsStringSync(), 'fixture password');

    _expectItems(payload);
  });

  test('opens the plain export', () {
    _expectItems(importVaultPlaintext(File('$_dir/export-plain.json').readAsStringSync()));
  });

  // openspec: add-security-key-codes, task 8.2
  group('the export with accounts on a security key', () {
    void expectOnKey(VaultExportPayload payload) {
      expect(payload.accounts.single.issuer, 'GitHub');
      expect(
        [for (final account in payload.keyAccounts) (account.name, account.issuer, account.label, account.period, account.type.name)],
        [
          ('Bank:ada@example.org', 'Bank', 'ada@example.org', 30, 'totp'),
          ('60/Mail server:root', 'Mail server', 'root', 60, 'totp'),
          ('Example:counter', 'Example', 'counter', 30, 'hotp'),
        ],
      );
      final [bank, mail, _] = payload.keyAccounts;
      expect((bank.device, bank.keyName, bank.note), ('0102030405060708', 'YubiKey 5C NFC', 'Backup codes in the safe'));
      expect(bank.tags, ['money']);
      expect((mail.algorithm, mail.touch), ('SHA256', true));
    }

    test('opens encrypted with its password', () async {
      expectOnKey(await importVault(File('$_dir/export-with-key-accounts.json').readAsStringSync(), 'fixture password'));
    });

    test('opens plain, with no secret of theirs in it', () {
      final text = File('$_dir/export-with-key-accounts-plain.json').readAsStringSync();
      expectOnKey(importVaultPlaintext(text));
      final entries = (jsonDecode(text) as Map<String, Object?>)['keyAccounts']! as List<Object?>;
      for (final entry in entries) {
        expect((entry! as Map<String, Object?>).keys, isNot(anyOf(contains('secret'), contains('code'), contains('digits'))));
      }
    });
  });

  test('opens the archive, and each of its files with its key', () async {
    final archive = readExportArchive(File('$_dir/export-archive.zip').readAsBytesSync());

    expect(archive.exportJson, File('$_dir/export-encrypted.json').readAsStringSync());
    final payload = await importVault(archive.exportJson, 'fixture password');
    _expectItems(payload);
    final [scan, photo] = payload.notes.single.files;
    expect(utf8.decode(kma1DecryptSync(archive.files[scan.id]!(), unb64(scan.key))), '%PDF-1.7 fixture passport scan\n');
    expect(
      kma1DecryptSync(archive.files[photo.id]!(), unb64(photo.key)),
      Uint8List.fromList([for (var i = 0; i < kma1ChunkLength + 10; i++) (i * 7 + 3) & 0xff]),
    );
  });
}
