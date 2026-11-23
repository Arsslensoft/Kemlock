import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/import/import_sheet.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../export/transfer_harness.dart';

const existing = OtpAccount(
  id: 'old',
  type: OtpType.totp,
  issuer: 'GitLab',
  label: 'me',
  secret: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
  algorithm: 'SHA1',
  digits: 6,
  period: 30,
  addedAt: 0,
);

final service = BackupService(
  id: 'svc',
  serviceName: 'GitLab',
  codes: const [BackupCode(code: 'aaaa-bbbb')],
  addedAt: 0,
);

final aegisVault = jsonEncode({
  'version': 1,
  'header': {'slots': null, 'params': null},
  'db': {
    'version': 2,
    'entries': [
      {
        'type': 'totp',
        'uuid': '1',
        'name': 'octocat',
        'issuer': 'GitHub',
        'note': '',
        'favorite': false,
        'info': {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'SHA1', 'digits': 6, 'period': 30},
      },
      {
        'type': 'yandex',
        'uuid': '2',
        'name': 'me',
        'issuer': 'Yandex',
        'info': {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'SHA256', 'digits': 8, 'period': 30},
      },
    ],
  },
});

// Another secret: a code the vault holds is matched on its secret alone, whatever its issuer
final imported = existing.copyWith(id: 'new', issuer: 'GitHub', secret: 'JBSWY3DPEHPK3PXP');

/// The import sheet over a vault holding [existing] and [service], and a
/// way to choose a file in it.
class _Sheet {
  _Sheet(this.tester);

  final WidgetTester tester;
  final files = FakeFiles();
  final vault = RecordingVault(accounts: const [existing], services: [service]);

  Future<void> open() => openSheet(tester, showImportSheet, vault: vault, files: files);

  Future<void> choose(String content, [String name = 'export.json']) async {
    files.nextPick = FakeFiles.text(name, content);
    await tapOn(tester, find.text(t('import.browse')));
  }

  Future<void> type(String fieldId, String text, [Map<String, Object?> args = const {}]) async {
    await tester.enterText(fieldLabelled(fieldId, args), text);
    await tester.pump();
  }

  ({List<OtpAccount> accounts, List<BackupService> backupServices}) get lastImport => vault.imports.single;
}

Future<_Sheet> _open(WidgetTester tester) async {
  final sheet = _Sheet(tester);
  await sheet.open();
  return sheet;
}

Matcher _account({required String issuer, String? label}) => isA<OtpAccount>()
    .having((a) => a.issuer, 'issuer', issuer)
    .having((a) => a.label, 'label', label ?? anything)
    .having((a) => a.id, 'id', isNotEmpty)
    .having((a) => a.addedAt, 'addedAt', testNow.millisecondsSinceEpoch);

void main() {
  group('other apps', () {
    testWidgets('reads an Aegis vault and says what it skipped', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(aegisVault, 'aegis-export.json');
      expect(find.text(t('import.detected', {'app': 'Aegis'})), findsOneWidget);
      expect(find.text('aegis-export.json'), findsOneWidget);
      await tapOn(tester, find.text(t('import.read')));

      expect(find.text(t('import.skipped', {'count': 1})), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      await tapOn(tester, find.text(t('import.button.merge', {'count': 1})));

      expect(sheet.lastImport.accounts, [existing, _account(issuer: 'GitHub', label: 'octocat')]);
      expect(sheet.lastImport.backupServices, [service]);
      expect(find.text(t('import.title')), findsNothing);
    });

    testWidgets('keeps backup codes when another app’s backup replaces the accounts', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(aegisVault);
      await tapOn(tester, find.text(t('import.read')));
      await tapOn(tester, find.text(t('import.mode.replace')));
      expect(find.text(t('import.info.replace', {'existingCount': 1, 'importCount': 1})), findsOneWidget);
      await tapOn(tester, find.text(t('import.button.replace')));

      expect(sheet.lastImport.accounts, [_account(issuer: 'GitHub')]);
      expect(sheet.lastImport.backupServices, [service]);
    });

    testWidgets('reads a text file of otpauth links', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose('otpauth://totp/Dropbox:me?secret=JBSWY3DPEHPK3PXP&issuer=Dropbox\n', 'codes.txt');
      expect(find.text(t('import.detected', {'app': t('import.source.uris')})), findsOneWidget);
      await tapOn(tester, find.text(t('import.read')));

      expect(find.text('Dropbox'), findsOneWidget);
    });

    testWidgets('says which files it can read when it doesn’t recognise one', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose('{"hello": "world"}');

      expect(find.text(t('import.error.unsupported')), findsOneWidget);
      expect(find.text(t('import.read')), findsNothing);
    });

    testWidgets('explains that encrypted Bitwarden exports can’t be read', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(jsonEncode({'encrypted': true, 'passwordProtected': true, 'data': 'x'}));
      await sheet.type('import.field.appPassword', 'pw', {'app': 'Bitwarden'});
      await tapOn(tester, find.text(t('import.decrypt')));

      expect(find.text(t('import.error.bitwardenEncrypted')), findsOneWidget);
    });
  });

  group('Kemlock exports', () {
    testWidgets('reads a plaintext export, backup codes included', (tester) async {
      final sheet = await _open(tester);
      // Other codes: a list with the held list's codes is the same list, whatever its name
      final newService = service.copyWith(
        id: 'svc2',
        serviceName: 'GitHub',
        codes: const [BackupCode(code: 'cccc-dddd')],
      );

      await sheet.choose(exportVaultPlaintext([imported], [newService]));
      expect(find.text(t('import.plaintext.detected')), findsOneWidget);
      await tapOn(tester, find.text(t('import.read')));
      expect(find.text('Also importing 1 backup service.'), findsOneWidget);
      await tapOn(tester, find.text(t('import.button.merge', {'count': 1})));

      expect(sheet.lastImport.accounts, [existing, imported]);
      expect(sheet.lastImport.backupServices, [service, newService]);
    });

    // openspec: add-passwords, task 7.5
    testWidgets('brings in an export’s logins, linked to the vault’s copy of an account it skips', (tester) async {
      final sheet = await _open(tester);
      final duplicate = existing.copyWith(id: 'theirs');
      const login = Login(id: 'l1', name: 'GitHub', username: 'octocat', password: 'hunter2', accountId: 'theirs', addedAt: 0);

      await sheet.choose(exportVaultPlaintext([duplicate], [], logins: const [login]));
      await tapOn(tester, find.text(t('import.read')));
      // The account is a duplicate, but the login alone is reason enough to import
      await tapOn(tester, find.text(t('import.button.items')));

      final added = sheet.vault.loginImports.single.single;
      expect((added.id, added.password, added.accountId), ('l1', 'hunter2', existing.id));
      expect(sheet.lastImport.accounts, [existing]);
    });

    testWidgets('opens an encrypted export', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(await exportVault([imported], [], 'export password', deriveKey: fastKdf));
      expect(find.text(t('import.detected.encrypted', {'app': 'Kemlock'})), findsOneWidget);
      await sheet.type('import.field.password', 'export password');
      await tapOn(tester, find.text(t('import.decrypt')));

      expect(find.text('GitHub'), findsOneWidget);
    });

    testWidgets('says when the export password is wrong', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(await exportVault([imported], [], 'export password', deriveKey: fastKdf));
      await sheet.type('import.field.password', 'not it');
      await tapOn(tester, find.text(t('import.decrypt')));

      expect(find.text(t('import.error.badPassword')), findsOneWidget);
      expect(find.text(t('import.step3')), findsNothing);
    });

    testWidgets('marks the accounts the vault has already and adds none of them', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(exportVaultPlaintext([existing], []));
      await tapOn(tester, find.text(t('import.read')));

      expect(find.text(t('import.chip.duplicate')), findsOneWidget);
      expect(find.text(t('import.info.merge', {'newCount': 0, 'dupCount': 1})), findsOneWidget);
      await tapOn(tester, find.text(t('import.button.merge', {'count': 0})));
      expect(sheet.vault.imports, isEmpty);

      await tapOn(tester, find.text(t('import.mode.replace')));
      expect(find.text(t('import.chip.duplicate')), findsNothing);
      await tapOn(tester, find.text(t('import.button.replace')));
      expect(sheet.lastImport.accounts, [existing]);
      expect(sheet.lastImport.backupServices, isEmpty);
    });

    testWidgets('marks a code the vault holds under another issuer name, and a list of the same codes, as held', (tester) async {
      final sheet = await _open(tester);
      final renamed = existing.copyWith(id: 'theirs', issuer: 'gitlab.com');
      final sameCodes = service.copyWith(id: 'svc2', serviceName: 'GitLab (old)');

      await sheet.choose(exportVaultPlaintext([renamed], [sameCodes]));
      await tapOn(tester, find.text(t('import.read')));

      expect(find.text(t('import.chip.duplicate')), findsOneWidget);
      expect(find.text(t('import.info.merge', {'newCount': 0, 'dupCount': 1})), findsOneWidget);
      await tapOn(tester, find.text(t('import.button.merge', {'count': 0})));
      expect(sheet.vault.imports, isEmpty);
    });

    testWidgets('opens an export with its vault’s Recovery Kit', (tester) async {
      final sheet = await _open(tester);
      final kit = makeKit(2, 3);
      final recoveryKey = RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 2, shares: 3, createdAt: '2026-10-16T09:00:00.000Z');

      await sheet.choose(await exportVault([imported], [], 'forgotten', recoveryKey: recoveryKey, deriveKey: fastKdf));
      await tapOn(tester, find.text(t('import.kit.use')));
      for (final piece in kit.pieces.take(2)) {
        await sheet.type('recovery.collect.field', piece);
        await tapOn(tester, find.text(t('recovery.collect.add')));
      }

      expect(find.text('GitHub'), findsOneWidget);
      await tapOn(tester, find.text(t('import.button.merge', {'count': 1})));
      expect(sheet.lastImport.accounts, [existing, imported]);
    });

    testWidgets('says when another vault’s kit doesn’t open the export', (tester) async {
      final sheet = await _open(tester);
      final kit = makeKit(1, 1);
      final other = makeKit(1, 1);
      final recoveryKey = RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 1, shares: 1, createdAt: '2026-10-16T09:00:00.000Z');

      await sheet.choose(await exportVault([imported], [], 'forgotten', recoveryKey: recoveryKey, deriveKey: fastKdf));
      await tapOn(tester, find.text(t('import.kit.use')));
      await sheet.type('recovery.collect.field', other.pieces.single);
      await tapOn(tester, find.text(t('recovery.collect.add')));

      expect(find.text(t('import.kit.wrong')), findsOneWidget);
      expect(find.text(t('import.step3')), findsNothing);
    });

    testWidgets('offers no kit for an export made without one', (tester) async {
      final sheet = await _open(tester);

      await sheet.choose(await exportVault([imported], [], 'export password', deriveKey: fastKdf));

      expect(find.text(t('import.kit.use')), findsNothing);
    });
  });

  testWidgets('starts over when the chosen file is removed', (tester) async {
    final semantics = tester.ensureSemantics();
    final sheet = await _open(tester);
    expect(find.text(t('import.step2.hint')), findsOneWidget);

    await sheet.choose(aegisVault, 'aegis-export.json');
    expect(find.text(t('import.step2.hint')), findsNothing);
    await tapOn(tester, find.bySemanticsLabel('Delete'));

    expect(find.text('aegis-export.json'), findsNothing);
    expect(find.text(t('import.read')), findsNothing);
    expect(find.text(t('import.step2.hint')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('closes on Cancel without importing', (tester) async {
    final sheet = await _open(tester);
    await tapOn(tester, find.text(t('import.cancel')));

    expect(find.text(t('import.title')), findsNothing);
    expect(sheet.vault.imports, isEmpty);
  });
}
