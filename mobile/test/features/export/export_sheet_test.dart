import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_owner_check.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import 'transfer_harness.dart';

const account = OtpAccount(
  id: 'acc',
  type: OtpType.totp,
  issuer: 'GitHub',
  label: 'octocat',
  secret: 'JBSWY3DPEHPK3PXP',
  algorithm: 'SHA1',
  digits: 6,
  period: 30,
  addedAt: 0,
);

Future<ProviderContainer> _open(WidgetTester tester, {FakeFiles? files, RecordingVault? vault}) => openSheet(
  tester,
  showExportSheet,
  files: files,
  vault: vault ?? RecordingVault(accounts: const [account]),
);

Future<ProviderContainer> _exportEncrypted(WidgetTester tester, String password, {FakeFiles? files}) async {
  final container = await _open(tester, files: files);
  await tester.enterText(fieldLabelled('export.field.password'), password);
  await tester.enterText(fieldLabelled('export.field.confirm'), password);
  await tester.pump();
  await tapOn(tester, find.text(t('export.button')));
  return container;
}

Future<void> _verify(WidgetTester tester, String password) async {
  await tester.enterText(fieldLabelled('export.verify.field'), password);
  await tester.pump();
  await tapOn(tester, find.text(t('export.verify.button')));
}

int? _lastBackupAt(ProviderContainer container) => container.read(prefsProvider).lastBackupAt;

void main() {
  testWidgets('encrypts by default', (tester) async {
    final semantics = tester.ensureSemantics();
    await _open(tester);

    expect(tester.getSemantics(find.bySemanticsLabel(t('export.mode.encrypted'))), isSemantics(isChecked: true));
    expect(fieldLabelled('export.field.password'), findsOneWidget);
    expect(find.text('ML-KEM-1024'), findsOneWidget);
    expect(find.text(t('export.chip.accounts', {'count': 1})), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('saves the file and records the backup', (tester) async {
    final files = FakeFiles();
    final container = await _exportEncrypted(tester, 'long enough password', files: files);

    expect(find.text(t('export.success')), findsOneWidget);
    expect(files.saved.single.name, exportFileName(testNow));
    expect(files.saved.single.name, matches(RegExp(r'^kemlock-export-.*\.json$')));
    expect(files.lastSavedText, contains('ML-KEM-1024'));
    expect(_lastBackupAt(container), testNow.millisecondsSinceEpoch);
  });

  testWidgets('says where the file went', (tester) async {
    await _exportEncrypted(tester, 'long enough password', files: FakeFiles()..nextSave = const Saved('Documents/backup.json'));

    expect(find.text('Documents/backup.json'), findsOneWidget);
  });

  testWidgets('keeps the form when the save dialog is closed without saving', (tester) async {
    final files = FakeFiles()..nextSave = const SaveCancelled();
    final container = await _exportEncrypted(tester, 'long enough password', files: files);

    expect(files.saved, isEmpty);
    expect(find.text(t('export.success')), findsNothing);
    expect(find.text(t('export.button')), findsOneWidget);
    expect(_lastBackupAt(container), isNull);
  });

  testWidgets('proves the backup opens with the password typed again', (tester) async {
    await _exportEncrypted(tester, 'long enough password');

    await _verify(tester, 'not the password');
    expect(find.text(t('export.verify.wrongPassword')), findsOneWidget);

    await _verify(tester, 'long enough password');
    expect(find.text(t('export.verify.ok', {'accounts': 1, 'services': 0})), findsOneWidget);
    expect(fieldLabelled('export.verify.field'), findsNothing);
  });

  testWidgets('says when the confirmation doesn’t match, and won’t export', (tester) async {
    final files = FakeFiles();
    await _open(tester, files: files);
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough passwort');
    await tester.pump();

    expect(find.text(t('export.field.mismatch')), findsOneWidget);
    await tapOn(tester, find.text(t('export.button')));
    expect(files.saved, isEmpty);
  });

  testWidgets('asks for an export password of at least 8 characters', (tester) async {
    final files = FakeFiles();
    await _exportEncrypted(tester, 'short', files: files);

    expect(find.text(t('export.error.tooShort')), findsOneWidget);
    expect(files.saved, isEmpty);
  });

  testWidgets('saves a plain export, with a warning and no backup recorded', (tester) async {
    final files = FakeFiles();
    final container = await _open(tester, files: files);
    await tester.tap(find.text(t('export.mode.plaintext')));
    await tester.pumpAndSettle();

    expect(find.text(t('export.plaintext.warning')), findsOneWidget);
    expect(fieldLabelled('export.field.password'), findsNothing);
    expect(find.text('ML-KEM-1024'), findsNothing);
    await tapOn(tester, find.text(t('export.plaintext.button')));

    expect(find.text(t('export.success')), findsOneWidget);
    expect(importVaultPlaintext(files.lastSavedText).accounts.single.issuer, 'GitHub');
    expect(_lastBackupAt(container), isNull);
    expect(find.text(t('export.verify.title')), findsNothing);
  });

  testWidgets('lets the file open with the vault’s Recovery Kit too', (tester) async {
    final store = KeyValueStore.memory();
    final vaultStore = VaultStore(store, VaultRegistry(store), deriveKey: fastKdf);
    final session = await vaultStore.setupVault('vault password');
    final kit = RecoveryKey(kitId: 'kit-1', key: Uint8List(32)..[0] = 7, threshold: 2, shares: 3, createdAt: '2026-10-16T09:00:00.000Z');
    await vaultStore.setRecoveryKey(session, kit);
    final files = FakeFiles();
    await openSheet(
      tester,
      showExportSheet,
      files: files,
      vault: RecordingVault(accounts: const [account], session: session),
      overrides: [vaultStoreProvider.overrideWithValue(vaultStore)],
    );

    expect(find.text(t('export.kit')), findsOneWidget);
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
    await tester.pump();
    await tapOn(tester, find.text(t('export.button')));

    expect(exportRecoveryKit(files.lastSavedText)?.kitId, 'kit-1');
    final opened = await importVaultWithRecoveryKey(files.lastSavedText, kit.key);
    expect(opened.accounts.single.issuer, 'GitHub');
  });

  testWidgets('closes on Cancel', (tester) async {
    await _open(tester);
    await tapOn(tester, find.text(t('export.cancel')));

    expect(find.text(t('export.title')), findsNothing);
  });

  group('asks who it is first', () {
    testWidgets('before an encrypted export, which a refusal stops', (tester) async {
      final files = FakeFiles();
      final check = FakeOwnerCheck(passes: false);
      await openSheet(
        tester,
        showExportSheet,
        files: files,
        ownerCheck: check,
        vault: RecordingVault(accounts: const [account]),
      );
      await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
      await tester.pump();

      await tapOn(tester, find.text(t('export.button')));
      expect(check.reasons, [t('export.confirm')]);
      expect(files.saved, isEmpty);
      expect(find.text(t('export.button')), findsOneWidget);

      check.passes = true;
      await tapOn(tester, find.text(t('export.button')));
      expect(check.reasons, hasLength(2));
      expect(files.saved, hasLength(1));
    });

    testWidgets('before a plain export', (tester) async {
      final files = FakeFiles();
      final check = FakeOwnerCheck(passes: false);
      await openSheet(
        tester,
        showExportSheet,
        files: files,
        ownerCheck: check,
        vault: RecordingVault(accounts: const [account]),
      );
      await tapOn(tester, find.text(t('export.mode.plaintext')));

      await tapOn(tester, find.text(t('export.plaintext.button')));

      expect(check.reasons, [t('export.confirm')]);
      expect(files.saved, isEmpty);
    });

    testWidgets('only once the export password will do', (tester) async {
      final check = FakeOwnerCheck();
      await openSheet(
        tester,
        showExportSheet,
        ownerCheck: check,
        vault: RecordingVault(accounts: const [account]),
      );
      await tester.enterText(fieldLabelled('export.field.password'), 'short');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'short');
      await tester.pump();

      await tapOn(tester, find.text(t('export.button')));

      expect(find.text(t('export.error.tooShort')), findsOneWidget);
      expect(check.reasons, isEmpty);
    });
  });

  testWidgets('says how many accounts are on the key, not in this file, and the backup still checks out', (tester) async {
    final files = FakeFiles();
    await _open(
      tester,
      files: files,
      vault: RecordingVault(accounts: const [account], keyAccounts: _onKey),
    );

    expect(find.text(t('export.onKey', {'count': 2})), findsOneWidget);
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
    await tester.pump();
    await tapOn(tester, find.text(t('export.button')));
    await _verify(tester, 'long enough password');

    expect(find.text(t('export.verify.ok', {'accounts': 1, 'services': 0})), findsOneWidget);
    final payload = (await tester.runAsync(() => importVault(files.lastSavedText, 'long enough password', deriveKey: fastKdf)))!;
    expect(payload.keyAccounts, _onKey);
  });

  testWidgets('says nothing of a key for a vault with no account on one', (tester) async {
    await _open(tester);

    expect(find.text(t('export.onKey', {'count': 0})), findsNothing);
    expect(find.textContaining(t('export.onKey', {'count': 2}).substring(12)), findsNothing);
  });

  testWidgets('counts the backup services it takes along', (tester) async {
    await _open(
      tester,
      vault: RecordingVault(accounts: const [account], services: [_service]),
    );

    expect(find.text(t('export.chip.backupServices', {'count': 1})), findsOneWidget);
  });
}

final _service = BackupService(
  id: 'svc',
  serviceName: 'GitLab',
  codes: const [BackupCode(code: 'aaaa-bbbb')],
  addedAt: 0,
);

// openspec: add-security-key-codes, task 8.3
const _onKey = [
  KeyAccount(id: 'ka1', device: '0102030405060708', keyName: 'YubiKey', name: 'Bank:ada', issuer: 'Bank', label: 'ada', addedAt: 1),
  KeyAccount(
    id: 'ka2',
    device: '0102030405060708',
    keyName: 'YubiKey',
    name: 'Registrar:ada',
    issuer: 'Registrar',
    label: 'ada',
    addedAt: 1,
  ),
];
