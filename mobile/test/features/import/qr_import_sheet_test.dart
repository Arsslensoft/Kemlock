import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/import/qr_import_sheet.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/qr_transfer.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_scanner.dart';
import '../../helpers/test_app.dart';
import '../export/transfer_harness.dart';

const existing = OtpAccount(id: 'old', issuer: 'GitLab', label: 'me', secret: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', addedAt: 0);

final service = BackupService(
  id: 'svc',
  serviceName: 'GitLab',
  codes: const [BackupCode(code: 'aaaa-bbbb')],
  addedAt: 0,
);

const github = OtpAccount(id: 'gh', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

/// Enough accounts that their plain transfer takes two codes.
final many = [
  for (var i = 0; i < 20; i++)
    OtpAccount(
      id: 'a$i',
      issuer: 'Service number $i',
      label: 'someone$i@example.com',
      secret: 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
      addedAt: 0,
    ),
];

/// The QR import sheet over a vault holding [existing] and [service], with a fake camera and picture reader.
class _Sheet {
  _Sheet(this.tester);

  final WidgetTester tester;
  final files = FakeFiles();
  final scanner = FakeScanner();
  final reader = FakeQrImageReader();
  final vault = RecordingVault(accounts: const [existing], services: [service]);

  Future<void> open() =>
      openSheet(tester, showQrImportSheet, vault: vault, files: files, overrides: [scanner.asOverride, reader.asOverride]);

  Future<void> startCamera() => tapOn(tester, find.text(t('qrImport.startCamera')));

  Future<void> scan(String code) async {
    await scanner.emitScan(tester, code);
    await tester.pumpAndSettle();
  }

  ({List<OtpAccount> accounts, List<BackupService> backupServices}) get lastImport => vault.imports.single;
}

Future<_Sheet> _open(WidgetTester tester) async {
  final sheet = _Sheet(tester);
  await sheet.open();
  return sheet;
}

/// An encrypted transfer's codes; PBKDF2 runs in another isolate.
Future<List<String>> _encrypted(WidgetTester tester, List<OtpAccount> accounts, String password) async =>
    (await tester.runAsync(() => exportVaultQr(accounts, const [], password)))!;

void main() {
  testWidgets('waits for the camera until it is asked for', (tester) async {
    final sheet = await _open(tester);

    expect(find.text(t('qrImport.body')), findsOneWidget);
    expect(find.text(t('qrImport.hint')), findsOneWidget);
    expect(sheet.scanner.sources, isEmpty);

    await sheet.startCamera();
    expect(sheet.scanner.isScanning, isTrue);
  });

  testWidgets('collects a plain transfer’s codes in any order and lists what they hold', (tester) async {
    final sheet = await _open(tester);
    final newService = BackupService(
      id: 'svc2',
      serviceName: 'Proton',
      codes: const [BackupCode(code: 'cccc')],
      addedAt: 0,
    );
    final codes = exportVaultQrPlaintext(many, [newService]);
    expect(codes, hasLength(2));
    await sheet.startCamera();

    await sheet.scan(codes[1]);
    expect(find.text(t('qrImport.progress', {'scanned': 1, 'total': 2})), findsOneWidget);
    expect(find.text('QR 1'), findsOneWidget);
    expect(find.text('QR 2'), findsOneWidget);
    expect(find.text(t('qrImport.hint')), findsNothing);

    await sheet.scan(codes[0]);
    expect(sheet.scanner.isScanning, isFalse);
    expect(find.text(t('export.chip.accounts', {'count': 20})), findsOneWidget);
    expect(find.text(t('export.chip.backupServices', {'count': 1})), findsOneWidget);
    expect(find.text(t('import.preview.new', {'count': 20})), findsOneWidget);
    expect(find.text('Service number 0'), findsOneWidget);

    await tapOn(tester, find.text(t('import.confirm', {'count': 20})));
    expect(sheet.lastImport.accounts.map((a) => a.issuer), [existing.issuer, ...many.map((a) => a.issuer)]);
    expect(sheet.lastImport.accounts.last.addedAt, testNow.millisecondsSinceEpoch);
    expect(sheet.lastImport.backupServices.map((s) => s.serviceName), ['GitLab', 'Proton']);
    expect(find.text(t('qrImport.title')), findsNothing);
  });

  testWidgets('ignores codes that aren’t part of a transfer', (tester) async {
    final sheet = await _open(tester);
    await sheet.startCamera();

    await sheet.scan('otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub');
    await sheet.scan('BMCP:01/02:not base64!');

    expect(find.text(t('qrImport.hint')), findsOneWidget);
    expect(sheet.scanner.isScanning, isTrue);
  });

  testWidgets('asks for the export password of an encrypted transfer', (tester) async {
    final sheet = await _open(tester);
    final codes = await _encrypted(tester, [existing, github], 'transfer password');
    await sheet.startCamera();
    await sheet.scan(codes.single);

    expect(find.text(t('qrImport.allScanned', {'total': 1})), findsOneWidget);
    expect(sheet.scanner.isScanning, isFalse);
    await tester.enterText(fieldLabelled('import.field.password'), 'not it');
    await tester.pump();
    await tapOn(tester, find.text(t('qrImport.decrypt')));
    await pumpUntilFound(tester, find.text('Wrong password or corrupted QR data.'));

    await tester.enterText(fieldLabelled('import.field.password'), 'transfer password');
    await tester.pump();
    await tapOn(tester, find.text(t('qrImport.decrypt')));
    await pumpUntilFound(tester, find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text(t('import.preview.existsTag')), findsOneWidget);
    expect(find.text(t('import.preview.duplicate', {'count': 1})), findsOneWidget);
    await tapOn(tester, find.text(t('import.confirm', {'count': 1})));
    expect(sheet.lastImport.accounts.map((a) => a.issuer), ['GitLab', 'GitHub']);
    expect(sheet.lastImport.backupServices, [service]);
  });

  testWidgets('replaces the vault’s accounts and backup services when asked', (tester) async {
    final sheet = await _open(tester);
    await sheet.startCamera();
    await sheet.scan(exportVaultQrPlaintext(const [github], const []).single);

    await tapOn(tester, find.text(t('import.mode.replace')));
    await tapOn(tester, find.text(t('import.confirm', {'count': 1})));

    expect(sheet.lastImport.accounts.map((a) => a.issuer), ['GitHub']);
    expect(sheet.lastImport.backupServices, isEmpty);
  });

  testWidgets('has nothing to merge when the vault has every account already', (tester) async {
    final sheet = await _open(tester);
    await sheet.startCamera();
    await sheet.scan(exportVaultQrPlaintext(const [existing], const []).single);

    expect(find.text(t('import.preview.existsTag')), findsOneWidget);
    await tapOn(tester, find.text(t('import.confirm', {'count': 0})));
    expect(sheet.vault.imports, isEmpty);
  });

  testWidgets('reads a transfer’s code from a picture', (tester) async {
    final sheet = await _open(tester);
    sheet.files.nextPick = FakeFiles.image('screenshot.png');
    sheet.reader.result = exportVaultQrPlaintext(many, const [])[0];

    await tapOn(tester, find.text(t('qrScanner.chooseImage')));

    expect(sheet.reader.paths, ['/picked/screenshot.png']);
    // The picture holds the transfer: the picker's copy is deleted once it is read
    expect(sheet.files.forgotten, ['/picked/screenshot.png']);
    expect(find.text(t('qrImport.progress', {'scanned': 1, 'total': 2})), findsOneWidget);
  });

  testWidgets('says when a picture holds no transfer code', (tester) async {
    final sheet = await _open(tester);
    sheet.files.nextPick = FakeFiles.image('cat.png');

    await tapOn(tester, find.text(t('qrScanner.chooseImage')));
    expect(find.text(t('qrScanner.error.notFound')), findsOneWidget);

    sheet.files.nextPick = FakeFiles.image('account.png');
    sheet.reader.result = 'otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP';
    await tapOn(tester, find.text(t('qrScanner.chooseImage')));
    expect(find.text(t('qrScanner.error.notFound')), findsOneWidget);
    expect(find.text(t('qrImport.hint')), findsOneWidget);
    expect(sheet.files.forgotten, ['/picked/cat.png', '/picked/account.png']);
  });

  testWidgets('turns the camera off when closed', (tester) async {
    final sheet = await _open(tester);
    await sheet.startCamera();

    await tapOn(tester, find.text(t('export.cancel')));

    expect(find.text(t('qrImport.title')), findsNothing);
    expect(sheet.scanner.sources.single.disposed, isTrue);
    expect(sheet.vault.imports, isEmpty);
  });
}
