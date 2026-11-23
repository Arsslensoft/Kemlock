import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/export/qr_export_sheet.dart';
import 'package:kemlock/features/import/import_sheet.dart';
import 'package:kemlock/features/import/qr_import_sheet.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/qr_transfer.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_files.dart';
import '../fakes/fake_scanner.dart';
import '../features/export/transfer_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';
import '../vault/fast_kdf.dart';

/// Renders the export and import sheets in their main states, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/transfer_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('transfer: export, encrypted, $name', (tester) async {
      await _open(tester, brightness, showExportSheet);
      await tester.enterText(fieldLabelled('export.field.password'), 'correct horse');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'correct hors');
      await takeScreenshot(tester, 'transfer_export_encrypted_$name');
    });

    testScreenshot('transfer: export, plaintext, $name', (tester) async {
      await _open(tester, brightness, showExportSheet);
      await tester.tap(find.text(t('export.mode.plaintext')));
      await takeScreenshot(tester, 'transfer_export_plaintext_$name');
    });

    testScreenshot('transfer: export, verified, $name', (tester) async {
      await _open(tester, brightness, showExportSheet);
      await tester.enterText(fieldLabelled('export.field.password'), 'correct horse');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'correct horse');
      await tester.pump();
      await tapOn(tester, find.text(t('export.button')));
      await tester.enterText(fieldLabelled('export.verify.field'), 'correct horse');
      await tester.pump();
      await tapOn(tester, find.text(t('export.verify.button')));
      await takeScreenshot(tester, 'transfer_export_verified_$name');
    });

    testScreenshot('transfer: qr export, password, $name', (tester) async {
      await _open(tester, brightness, showQrExportSheet);
      await tester.enterText(fieldLabelled('export.field.password'), 'correct horse');
      await takeScreenshot(tester, 'transfer_qr_export_password_$name');
    });

    testScreenshot('transfer: qr export, codes, $name', (tester) async {
      await _open(tester, brightness, showQrExportSheet, vault: RecordingVault(accounts: _many));
      await tester.tap(find.text(t('export.mode.plaintext')));
      await tester.pumpAndSettle();
      await tapOn(tester, find.text(t('qrExport.generate')));
      await tapOn(tester, find.text(t('qrExport.next')));
      await takeScreenshot(tester, 'transfer_qr_export_codes_$name');
    });

    testScreenshot('transfer: import, empty, $name', (tester) async {
      await _open(tester, brightness, showImportSheet);
      await takeScreenshot(tester, 'transfer_import_empty_$name');
    });

    testScreenshot('transfer: import, encrypted, $name', (tester) async {
      final files = FakeFiles();
      await _open(tester, brightness, showImportSheet, files: files);
      final kit = makeKit(2, 3);
      final key = RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 2, shares: 3, createdAt: '2026-10-16T09:00:00.000Z');
      files.nextPick = FakeFiles.text(
        'kemlock-export-2026-10-16T09-00-00.json',
        await exportVault(_accounts, const [], 'pw', recoveryKey: key, deriveKey: fastKdf),
      );
      await tapOn(tester, find.text(t('import.browse')));
      await tester.enterText(fieldLabelled('import.field.password'), 'correct horse');
      await takeScreenshot(tester, 'transfer_import_encrypted_$name');
    });

    testScreenshot('transfer: import, review, $name', (tester) async {
      final files = FakeFiles();
      await _open(tester, brightness, showImportSheet, files: files);
      final fresh = [
        for (final (i, issuer) in ['Dropbox', 'Discord', 'Slack'].indexed) _accounts[i].copyWith(id: 'n$i', issuer: issuer),
      ];
      files.nextPick = FakeFiles.text(
        'codes.json',
        exportVaultPlaintext([_accounts.first, ...fresh], [_services.first.copyWith(id: 's9', serviceName: 'Dropbox')]),
      );
      await tapOn(tester, find.text(t('import.browse')));
      await tapOn(tester, find.text(t('import.read')));
      await takeScreenshot(tester, 'transfer_import_review_$name');
    });

    testScreenshot('transfer: qr import, scanning, $name', (tester) async {
      final scanner = FakeScanner();
      await _open(tester, brightness, showQrImportSheet, overrides: [scanner.asOverride]);
      await tapOn(tester, find.text(t('qrImport.startCamera')));
      await scanner.emitScan(tester, exportVaultQrPlaintext(_many, const [])[1]);
      await takeScreenshot(tester, 'transfer_qr_import_scanning_$name');
    });

    testScreenshot('transfer: qr import, password, $name', (tester) async {
      final scanner = FakeScanner();
      await _open(tester, brightness, showQrImportSheet, overrides: [scanner.asOverride]);
      final codes = (await tester.runAsync(() => exportVaultQr(_accounts, const [], 'correct horse')))!;
      await tapOn(tester, find.text(t('qrImport.startCamera')));
      await scanner.emitScan(tester, codes.single);
      await tester.pumpAndSettle();
      await tester.enterText(fieldLabelled('import.field.password'), 'correct horse');
      await takeScreenshot(tester, 'transfer_qr_import_password_$name');
    });

    testScreenshot('transfer: qr import, review, $name', (tester) async {
      final scanner = FakeScanner();
      await _open(tester, brightness, showQrImportSheet, overrides: [scanner.asOverride]);
      final fresh = [
        for (final (i, issuer) in ['Dropbox', 'Discord'].indexed) _accounts[i].copyWith(id: 'q$i', issuer: issuer),
      ];
      await tapOn(tester, find.text(t('qrImport.startCamera')));
      await scanner.emitScan(tester, exportVaultQrPlaintext([_accounts.first, ...fresh], _services).single);
      await takeScreenshot(tester, 'transfer_qr_import_review_$name');
    });
  }
}

const _accounts = [
  OtpAccount(id: 'a1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0),
  OtpAccount(id: 'a2', issuer: 'Google', label: 'me@gmail.com', secret: 'GEZDGNBVGY3TQOJQ', addedAt: 0),
  OtpAccount(id: 'a3', issuer: 'Proton', label: 'me@proton.me', secret: 'MFRGGZDFMZTWQ2LK', addedAt: 0),
];

/// Enough accounts that their plain transfer takes two codes.
final _many = [
  for (var i = 0; i < 20; i++)
    OtpAccount(
      id: 'm$i',
      issuer: 'Service number $i',
      label: 'someone$i@example.com',
      secret: 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
      addedAt: 0,
    ),
];

final _services = [
  BackupService(
    id: 's1',
    serviceName: 'GitHub',
    codes: const [BackupCode(code: 'a1b2-c3d4')],
    addedAt: 0,
  ),
];

/// Opens a transfer sheet over a page with something on it, on a phone screen.
Future<void> _open(
  WidgetTester tester,
  Brightness brightness,
  Future<void> Function(BuildContext context) open, {
  RecordingVault? vault,
  FakeFiles? files,
  List<Override> overrides = const [],
}) async {
  usePhoneScreen(tester);
  await pumpScreen(
    tester,
    brightness: brightness,
    const _Page(),
    overrides: [
      (vault ?? RecordingVault(accounts: _accounts, services: _services)).asOverride,
      (files ?? FakeFiles()).asOverride,
      fastExportKey,
      ...overrides,
    ],
  );
  unawaited(open(tester.element(find.byType(_Page))));
  await tester.pumpAndSettle();
}

/// A page with something on it, to see the scrim and the blur over.
class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => ScreenshotBoard(
    title: 'Settings',
    children: [
      for (final label in ['Export vault', 'Import vault', 'Show transfer QR codes', 'Scan transfer QR codes'])
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: GroupCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(label, style: AppType.h6),
            ),
          ),
        ),
    ],
  );
}
