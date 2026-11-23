import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/now.dart';
import 'package:kemlock/features/accounts/add_account_sheet.dart';
import 'package:kemlock/features/accounts/service_icons.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';

import '../fakes/fake_files.dart';
import '../fakes/fake_scanner.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the add-account sheet on each tab and with what it found, in
/// dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/add_account_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('add account: scanning, $name', (tester) async {
      await _open(tester, brightness, scanner: FakeScanner(animated: true));
      await settleForScreenshot(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await captureScreenshot('add_account_scan_$name');
    });

    testScreenshot('add account: scanned, $name', (tester) async {
      final scanner = FakeScanner(animated: true);
      await _open(tester, brightness, scanner: scanner);
      await scanner.emitScan(tester, 'otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub');
      await takeScreenshot(tester, 'add_account_scanned_$name');
    });

    testScreenshot('add account: transfer, $name', (tester) async {
      final scanner = FakeScanner(animated: true);
      await _open(tester, brightness, scanner: scanner);
      await scanner.emitScan(
        tester,
        _migrationUri([
          (name: 'octocat', issuer: 'GitHub'),
          (name: 'alice@example.com', issuer: 'Google'),
          (name: 'alice', issuer: 'Proton'),
        ], skipped: 1),
      );
      await takeScreenshot(tester, 'add_account_transfer_$name');
    });

    testScreenshot('add account: photo, $name', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('cat.png');
      await _open(tester, brightness, files: files);
      await tester.tap(find.text(t('addAccount.tab.photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('qrScanner.chooseImage')));
      await takeScreenshot(tester, 'add_account_photo_$name');
    });

    testScreenshot('add account: manual, $name', (tester) async {
      await _open(tester, brightness);
      await tester.tap(find.text(t('addAccount.tab.manual')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t('addAccount.field.issuer')), 'GitHub');
      await tester.enterText(find.widgetWithText(TextField, t('addAccount.field.label')), 'octocat');
      await tester.enterText(find.widgetWithText(TextField, t('addAccount.field.secret')), 'jbsw y3dp ehpk 3pxp');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.text(t('addAccount.advanced')));
      await takeScreenshot(tester, 'add_account_manual_$name');
    });

    testScreenshot('add account: manual error, $name', (tester) async {
      await _open(tester, brightness);
      await tester.tap(find.text(t('addAccount.tab.manual')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('addAccount.add')));
      await takeScreenshot(tester, 'add_account_manual_error_$name');
    });

    testScreenshot('add account: steam, $name', (tester) async {
      await _open(tester, brightness);
      await tester.tap(find.text(t('addAccount.tab.manual')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t('addAccount.field.issuer')), 'Steam');
      await tester.enterText(find.widgetWithText(TextField, t('addAccount.field.secret')), 'JBSWY3DPEHPK3PXP');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.text(t('addAccount.advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(SegmentedControl<OtpType>), matching: find.text('Steam')));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -400));
      await takeScreenshot(tester, 'add_account_steam_$name');
    });
  }
}

/// The clock's second, standing still, so no timer outlives the test.
class _StillSecond extends NowSeconds {
  @override
  int build() => testNow.millisecondsSinceEpoch ~/ 1000;
}

Future<void> _open(WidgetTester tester, Brightness brightness, {FakeScanner? scanner, FakeFiles? files}) async {
  usePhoneScreen(tester);
  final icons = await tester.runAsync(ServiceIcons.load);
  await pumpScreen(
    tester,
    brightness: brightness,
    reducedMotion: false,
    overrides: [
      nowSecondsProvider.overrideWith(_StillSecond.new),
      serviceIconsProvider.overrideWith((ref) async => icons!),
      (scanner ?? FakeScanner()).asOverride,
      (files ?? FakeFiles()).asOverride,
      FakeQrImageReader().asOverride,
    ],
    const _Page(),
  );
  unawaited(showAddAccountSheet(tester.element(find.byType(_Page))));
  // The viewfinder never settles while it looks; the sheet is up after a second.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// The Codes page behind the sheet.
class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => ScreenshotBoard(
    title: 'Codes',
    children: [
      for (final issuer in ['GitHub', 'Google', 'Proton'])
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: GroupCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(issuer, style: AppType.h6),
            ),
          ),
        ),
    ],
  );
}

/// A Google Authenticator "Transfer accounts" link, with [skipped] HOTP entries of an unsupported length.
String _migrationUri(List<({String name, String issuer})> accounts, {int skipped = 0}) {
  List<int> lengthDelimited(int no, List<int> data) => [(no << 3) | 2, data.length, ...data];
  List<int> varint(int no, int value) => [no << 3, value];
  List<int> otp(String name, String issuer, {int digits = 1}) => lengthDelimited(1, [
    ...lengthDelimited(1, utf8.encode('12345678901234567890')),
    ...lengthDelimited(2, utf8.encode(name)),
    ...lengthDelimited(3, utf8.encode(issuer)),
    ...varint(4, 1),
    ...varint(5, digits),
    ...varint(6, 2),
  ]);
  final payload = [
    for (final (:name, :issuer) in accounts) ...otp(name, issuer),
    for (var i = 0; i < skipped; i++) ...otp('old', 'Yandex', digits: 3),
    ...varint(2, 1),
  ];
  return 'otpauth-migration://offline?data=${Uri.encodeComponent(base64.encode(payload))}';
}
