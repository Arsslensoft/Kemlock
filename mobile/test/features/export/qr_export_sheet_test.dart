import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/qr_export_sheet.dart';
import 'package:kemlock/features/export/qr_printout.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_owner_check.dart';
import '../../fakes/fake_printer.dart';
import '../../helpers/test_app.dart';
import '../recovery/pdf_text.dart';
import 'transfer_harness.dart';

const _account = OtpAccount(id: 'acc', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

/// Enough accounts that their plain transfer takes two codes.
final _many = [
  for (var i = 0; i < 20; i++)
    OtpAccount(
      id: 'a$i',
      issuer: 'Service number $i',
      label: 'someone$i@example.com',
      secret: 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
      addedAt: 0,
    ),
];

Future<ProviderContainer> _open(
  WidgetTester tester, {
  List<OtpAccount> accounts = const [_account],
  FakePrinter? printer,
  FakeFiles? files,
}) => openSheet(
  tester,
  showQrExportSheet,
  vault: RecordingVault(accounts: accounts),
  files: files,
  overrides: [(printer ?? FakePrinter()).asOverride],
);

Future<void> _makePlain(WidgetTester tester) async {
  await tester.tap(find.text(t('export.mode.plaintext')));
  await tester.pumpAndSettle();
  await tapOn(tester, find.text(t('qrExport.generate')));
}

/// The start of the code on screen, as the sheet prints it under the code.
String _shownChunk() => (find.textContaining(RegExp(r'^BMC[1P]:')).evaluate().single.widget as Text).data!;

void main() {
  testWidgets('encrypts by default, with what it holds and how', (tester) async {
    final semantics = tester.ensureSemantics();
    await _open(tester);

    expect(find.text(t('qrExport.body', {'accountCount': 1, 'serviceCount': 0})), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(t('export.mode.encrypted'))), isSemantics(isChecked: true));
    expect(find.text('PBKDF2-SHA256'), findsOneWidget);
    expect(fieldLabelled('export.field.password'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('encrypts the codes with the export password and records the backup', (tester) async {
    final container = await _open(tester);
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
    await tester.pump();
    await tapOn(tester, find.text(t('qrExport.generate')));
    // PBKDF2 runs in another isolate.
    await pumpUntilFound(tester, find.text(t('qrExport.ready', {'total': 1})));
    await tester.pumpAndSettle();

    expect(_shownChunk(), startsWith('BMC1:01/01:'));
    expect(find.text(t('qrExport.chunkLabel', {'index': 1, 'total': 1})), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(t('qrExport.next')), findsNothing);
    expect(container.read(prefsProvider).lastBackupAt, testNow.millisecondsSinceEpoch);
  });

  testWidgets('asks for matching passwords of at least 8 characters', (tester) async {
    await _open(tester);
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough');
    await tester.pump();
    expect(find.text(t('export.field.mismatch')), findsOneWidget);

    await tester.enterText(fieldLabelled('export.field.password'), 'short');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'short');
    await tester.pump();
    await tapOn(tester, find.text(t('qrExport.generate')));
    expect(find.text(t('export.error.tooShort')), findsOneWidget);
    expect(find.text(t('qrExport.ready', {'total': 1})), findsNothing);
  });

  testWidgets('shows a plain export’s codes one after another, without recording a backup', (tester) async {
    final container = await _open(tester, accounts: _many);
    await _makePlain(tester);

    expect(find.text(t('qrExport.ready', {'total': 2})), findsOneWidget);
    expect(find.text(t('qrExport.chunkLabel', {'index': 1, 'total': 2})), findsOneWidget);
    expect(_shownChunk(), startsWith('BMCP:01/02:'));
    expect(find.text('QR 2'), findsOneWidget);

    await tapOn(tester, find.text(t('qrExport.next')));
    expect(find.text(t('qrExport.chunkLabel', {'index': 2, 'total': 2})), findsOneWidget);
    expect(_shownChunk(), startsWith('BMCP:02/02:'));
    final next = find.ancestor(of: find.text(t('qrExport.next')), matching: find.byWidgetPredicate((w) => w is TextButton));
    expect(tester.widget<TextButton>(next).onPressed, isNull);

    await tapOn(tester, find.text(t('qrExport.prev')));
    expect(_shownChunk(), startsWith('BMCP:01/02:'));

    await tapOn(tester, find.text('QR 2'));
    expect(_shownChunk(), startsWith('BMCP:02/02:'));
    expect(find.text(t('qrExport.hint', {'total': 2})), findsOneWidget);
    expect(container.read(prefsProvider).lastBackupAt, isNull);
  });

  testWidgets('prints every code, with auto-lock held while the print dialog is open', (tester) async {
    final holds = AutoLockHolds();
    final printer = FakePrinter(holds: holds);
    await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: _many),
      overrides: [printer.asOverride, autoLockHoldsProvider.overrideWithValue(holds)],
    );
    await _makePlain(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text(t('qrExport.print')));
      // The fonts load from the asset bundle on the real event loop.
      for (var i = 0; i < 100 && printer.jobs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    final job = printer.jobs.single;
    expect(job.name, 'Kemlock — Plaintext Vault QR Export');
    expect(job.held, isTrue);
    final text = PdfText(job.pdf).text;
    expect(text, contains('QR 1 / 2'));
    expect(text, contains('QR 2 / 2'));
    expect(text, contains('20 accounts'));
    expect(text, isNot(contains('export password')));
  });

  testWidgets('shares the codes as a PDF on a phone that can’t print', (tester) async {
    final files = FakeFiles();
    await _open(tester, accounts: _many, printer: FakePrinter(printing: false), files: files);
    await _makePlain(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text(t('qrExport.print')));
      for (var i = 0; i < 100 && files.saved.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    expect(files.saved.single.name, 'kemlock-qr-export.pdf');
    expect(files.saved.single.mimeType, 'application/pdf');
  });

  test('says on paper what an encrypted export needs', () {
    final printout = QrPrintout(chunks: const ['BMC1:01/01:abc'], encrypted: true, accounts: 1, services: 2, exportedAt: testNow);

    expect(qrPrintTitle(printout), 'Kemlock — Encrypted Vault QR Export');
    expect(qrPrintMeta(printout), endsWith('· 1 account + 2 backup services · 1 QR code · Encrypted with AES-256-GCM + PBKDF2'));
    expect(
      qrPrintHowTo(printout),
      'Scan all 1 QR code in the Kemlock app (Import → Scan QR Vault). You will need your export password to decrypt.',
    );
  });

  testWidgets('closes on Cancel', (tester) async {
    await _open(tester);
    await tapOn(tester, find.text(t('export.cancel')));

    expect(find.text(t('qrExport.title')), findsNothing);
  });

  testWidgets('asks who it is before making the codes, and a refusal makes none', (tester) async {
    final check = FakeOwnerCheck(passes: false);
    final container = await openSheet(
      tester,
      showQrExportSheet,
      vault: RecordingVault(accounts: const [_account]),
      ownerCheck: check,
      overrides: [FakePrinter().asOverride],
    );

    await _makePlain(tester);
    expect(check.reasons, [t('export.confirm')]);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text(t('qrExport.generate')), findsOneWidget);

    await tester.tap(find.text(t('export.mode.encrypted')));
    await tester.pumpAndSettle();
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
    await tester.pump();
    await tapOn(tester, find.text(t('qrExport.generate')));
    expect(check.reasons, hasLength(2));
    expect(find.byType(QrImageView), findsNothing);
    expect(container.read(prefsProvider).lastBackupAt, isNull);

    check.passes = true;
    await tapOn(tester, find.text(t('qrExport.generate')));
    await pumpUntilFound(tester, find.text(t('qrExport.ready', {'total': 1})));
    expect(check.reasons, hasLength(3));
  });
}
