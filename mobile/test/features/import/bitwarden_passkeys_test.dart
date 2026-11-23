import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/import/import_sheet.dart';
import 'package:kemlock/features/import/importers.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../export/transfer_harness.dart';

/// An unencrypted Bitwarden JSON export, in the shape Bitwarden's apps
/// write: two logins holding three passkeys (a 16-byte credential id as a
/// GUID, a longer one as `b64.`, and an Ed25519 one Kemlock can't use), with
/// P-256 keys made by OpenSSL 3.6 as Bitwarden keeps them, PKCS#8 in
/// base64url.
final _export = File('test/fixtures/import/bitwarden-passkeys.json').readAsStringSync();

void main() {
  group('reading Bitwarden passkeys', () {
    test('takes the ES256 passkeys of each login, with their ids and keys as Kemlock keeps them', () async {
      final result = await parseForeignExport(_export);

      expect(result.source, ImportSource.bitwarden);
      expect(result.accounts.single.issuer, 'GitHub');
      final [github, bank] = result.passkeys;
      expect(github.credentialId, b64url(unhexOf('4f8d5c0e9b2a4c7e8d1f2a3b4c5d6e7f')));
      expect(
        (github.rpId, github.rpName, github.userName, github.userDisplayName),
        ('github.com', 'GitHub', 'octocat@example.com', 'Octo Cat'),
      );
      expect(github.userHandle, 'dXNlci1vY3RvY2F0LTEyMw');
      expect(github.addedAt, DateTime.utc(2026, 3, 4, 8).millisecondsSinceEpoch);
      // PKCS#8, now in standard base64, starting with the P-256 algorithm identifier
      expect(github.privateKey, startsWith('MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEH'));
      expect(
        unb64(github.privateKey),
        unb64url(
          'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgNc6FSUrJQrKQ_0EiE9JmsC4GFeHUF2jB_UB5ZStgsvChRANCAAQDgR8zNBagqmr48ZCUjodw7n5wlXUXSLlRGosIF8jPJYr2zKgS3UPz2tllpYfH1fo6rBijPiPSGqdv9DKyWP6k',
        ),
      );
      expect(bank.credentialId, 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA');
      expect((bank.rpId, bank.rpName, bank.userName), ('bank.example', null, 'ada'));
      // The Ed25519 passkey is one Kemlock can't use
      expect(result.skipped, 1);
    });

    test('a file of passkeys alone is not empty', () async {
      final passkeysOnly = _export.replaceFirst(RegExp(r'"totp": "otpauth[^"]*"'), '"totp": null');

      final result = await parseForeignExport(passkeysOnly);

      expect(result.accounts, isEmpty);
      expect(result.passkeys, hasLength(2));
    });
  });

  testWidgets('imports the passkeys, counted in the preview, and skips them the second time', (tester) async {
    final files = FakeFiles();
    final vault = RecordingVault();
    await openSheet(tester, showImportSheet, vault: vault, files: files);

    files.nextPick = FakeFiles.text('bitwarden_export.json', _export);
    await tapOn(tester, find.text(t('import.browse')));
    await tapOn(tester, find.text(t('import.read')));
    expect(find.text(t('import.info.passkeys', {'newCount': 2, 'dupCount': 0})), findsOneWidget);
    await tapOn(tester, find.text(t('import.button.merge', {'count': 1})));

    final first = vault.passkeyImports.single;
    expect(first.map((passkey) => passkey.rpId), ['github.com', 'bank.example']);
    expect(first.map((passkey) => passkey.id).toSet(), hasLength(2));
    expect(first.every((passkey) => passkey.id.isNotEmpty), isTrue);

    // The same file again: the account is a duplicate, and so are both passkeys
    await tapOn(tester, find.text('Open'));
    files.nextPick = FakeFiles.text('bitwarden_export.json', _export);
    await tapOn(tester, find.text(t('import.browse')));
    await tapOn(tester, find.text(t('import.read')));
    expect(find.text(t('import.info.passkeys', {'newCount': 0, 'dupCount': 2})), findsOneWidget);
    await tapOn(tester, find.text(t('import.button.merge', {'count': 1})));

    // The recording vault keeps only passkeys, so the account comes again; neither passkey does
    expect(vault.passkeyImports.last, isEmpty);
    expect(vault.state.passkeys, hasLength(2));
  });

  testWidgets('a file of passkeys alone imports them', (tester) async {
    final files = FakeFiles();
    final vault = RecordingVault();
    await openSheet(tester, showImportSheet, vault: vault, files: files);

    files.nextPick = FakeFiles.text('bitwarden_export.json', _export.replaceFirst(RegExp(r'"totp": "otpauth[^"]*"'), '"totp": null'));
    await tapOn(tester, find.text(t('import.browse')));
    await tapOn(tester, find.text(t('import.read')));
    await tapOn(tester, find.text(t('import.button.passkeys', {'count': 2})));

    expect(vault.passkeyImports.single, hasLength(2));
  });
}

List<int> unhexOf(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
