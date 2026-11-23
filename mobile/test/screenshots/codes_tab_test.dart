import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/accounts/accounts_page.dart';
import 'package:kemlock/features/accounts/service_icons.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../fakes/fake_oath_key.dart';
import '../fakes/fake_security_keys.dart';
import '../features/accounts/codes_fakes.dart';
import '../features/sync/sync_screen_kit.dart' show fakeSync;
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the Codes tab: the list and its states, and the account sheet's
/// panels, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/codes_tab_test.dart
void main() {
  // 16 October 2026, 09:00:55 UTC: five seconds left in the window, so the urgent colours show
  final at = testNow.millisecondsSinceEpoch + 55000;
  final day = testNow.millisecondsSinceEpoch - 86400000;

  final github = rfcAccount.copyWith(
    addedAt: testNow.millisecondsSinceEpoch - 86400000 * 40,
    note: 'Recovery email: work.\nSecond key in the safe.',
    tags: ['Work', 'Dev'],
  );
  const githubCodes = BackupService(
    id: 's',
    serviceName: 'GitHub',
    codes: [
      BackupCode(code: 'a'),
      BackupCode(code: 'b', used: true),
      BackupCode(code: 'c'),
      BackupCode(code: 'd'),
    ],
    addedAt: 0,
  );

  OtpAccount account(
    String id,
    String issuer,
    String label, {
    OtpType? type,
    int period = 30,
    int digits = 6,
    List<String>? tags,
    bool? pinned,
  }) => OtpAccount(
    id: id,
    type: type,
    issuer: issuer,
    label: label,
    secret: 'JBSWY3DPEHPK3PXP${id.toUpperCase().replaceAll(RegExp('[^A-Z2-7]'), 'A')}',
    period: period,
    digits: digits,
    counter: type == OtpType.hotp ? 3 : null,
    tags: tags,
    pinned: pinned,
    addedAt: day,
  );

  final accounts = [
    github.copyWith(pinned: true),
    account('google', 'Google', 'me@gmail.com', tags: ['Personal'], pinned: true),
    account('dropbox', 'Dropbox', 'me@example.com', tags: ['Work']),
    account('steam', 'Steam', 'gamer', type: OtpType.steam, tags: ['Games']),
    account('aws', 'Amazon Web Services', 'root', period: 60, tags: ['Work']),
    account('ms', 'Microsoft', 'me@outlook.com', digits: 8),
    account('yubi', 'Yubico', '', type: OtpType.hotp),
  ];

  final familySpace = SyncSnapshot(
    settings: SyncSettings(
      spaces: [
        Space(
          id: 'fam',
          name: 'Family',
          target: SyncTarget(
            dav: const DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'pw'),
            file: spaceFile('fam'),
            key: 'a2V5',
          ),
          joinedAt: 1,
        ),
      ],
    ),
  );

  setUp(FakeClipboard.new);

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<void> openPage(WidgetTester tester, List<OtpAccount> list, {double height = 852}) async {
      usePhoneScreen(tester, size: Size(393, height));
      await pumpAt(
        tester,
        brightness: brightness,
        atMs: at,
        const Scaffold(body: AccountsPage()),
        overrides: [
          await _icons(tester),
          fakeVault(FakeVaultController(openVault(accounts: list), apply: true)),
        ],
      );
      await tester.pumpAndSettle();
    }

    testScreenshot('codes tab: list, $name', (tester) async {
      await openPage(tester, accounts, height: 1400);
      await takeScreenshot(tester, 'codes_tab_list_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: copied, $name', (tester) async {
      await openPage(tester, accounts);
      await tester.tap(find.text('Dropbox'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await captureScreenshot('codes_tab_copied_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: sort menu, $name', (tester) async {
      await openPage(tester, accounts);
      await tester.tap(find.byTooltip(t('accounts.sort')));
      await takeScreenshot(tester, 'codes_tab_sort_menu_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: search, $name', (tester) async {
      await openPage(tester, accounts);
      await tester.enterText(find.byType(TextField), 'me@');
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'codes_tab_search_$name');
      await tester.enterText(find.byType(TextField), 'nothing like it');
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'codes_tab_no_matches_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: reordering, $name', (tester) async {
      await openPage(tester, accounts);
      await tester.tap(find.byTooltip(t('accounts.sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('accounts.reorder')));
      await takeScreenshot(tester, 'codes_tab_reorder_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: empty, $name', (tester) async {
      await openPage(tester, const []);
      await takeScreenshot(tester, 'codes_tab_empty_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: removing, $name', (tester) async {
      await openPage(tester, accounts);
      await tester.tap(find.byTooltip(t('accountCard.details', {'name': 'Dropbox'})));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(t('accountCard.tooltip.remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('accountCard.tooltip.remove')));
      await takeScreenshot(tester, 'codes_tab_remove_$name');
      await leaveScreen(tester);
    });

    Future<void> openSheet(WidgetTester tester, OtpAccount account, {List<Override> overrides = const []}) async {
      usePhoneScreen(tester);
      await pumpAt(
        tester,
        brightness: brightness,
        atMs: at,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showAccountSheet(
                  context,
                  account: account,
                  allTags: const ['Work', 'Dev', 'Personal', 'Bank'],
                  onDelete: (_) {},
                  onUpdate: (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        overrides: [
          await _icons(tester),
          fakeVault(FakeVaultController(openVault(backupServices: [githubCodes]))),
          ...overrides,
        ],
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> scrollSheet(WidgetTester tester, double by) async {
      await tester.drag(find.descendant(of: find.byType(AccountSheet), matching: find.byType(Scrollable)).first, Offset(0, -by));
      await tester.pumpAndSettle();
    }

    testScreenshot('codes tab: account sheet, $name', (tester) async {
      await openSheet(tester, github);
      await takeScreenshot(tester, 'codes_tab_sheet_$name');
      await scrollSheet(tester, 400);
      await takeScreenshot(tester, 'codes_tab_sheet_details_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: account sheet secret, $name', (tester) async {
      await openSheet(tester, github);
      await tester.tap(find.text(t('accountCard.tooltip.viewQr')));
      await tester.pumpAndSettle();
      await scrollSheet(tester, 400);
      await takeScreenshot(tester, 'codes_tab_sheet_qr_hidden_$name');
      await tester.tap(find.text(t('accountSheet.reveal')));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'codes_tab_sheet_qr_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: account sheet edit, $name', (tester) async {
      await openSheet(tester, github.copyWith(pinned: true, spaceId: 'fam'), overrides: [fakeSync(familySpace)]);
      await tester.tap(find.text(t('accountSheet.edit')));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await scrollSheet(tester, 420);
      await takeScreenshot(tester, 'codes_tab_sheet_edit_$name');
      await leaveScreen(tester);
    });

    testScreenshot('codes tab: hotp sheet, $name', (tester) async {
      await openSheet(tester, rfcAccount.copyWith(type: OtpType.hotp, counter: 4, issuer: 'Yubico', label: ''));
      await takeScreenshot(tester, 'codes_tab_sheet_hotp_$name');
      await leaveScreen(tester);
    });

    // The mockup Codes.dc.html (openspec: add-security-key-codes, task 4.7): two vault
    // accounts, four on a key of which one needs a touch, read 20 seconds ago.
    testScreenshot('codes tab: on a security key, $name', (tester) async {
      usePhoneScreen(tester, size: const Size(393, 1100));
      final phone = FakeSecurityKeys();
      final key = FakeKey(
        productName: 'YubiKey',
        applets: [
          FakeOathKey(
            accounts: [
              FakeOathAccount('Bank:ada@example.org', ascii.encode('bank secret 01234567')),
              FakeOathAccount('Cloudflare:ada@example.org', ascii.encode('cloudflare secret 01')),
              FakeOathAccount('Registrar:ada@example.org', ascii.encode('registrar secret 012'), touch: true),
              FakeOathAccount('Mail server:root', ascii.encode('mail server secret 0')),
            ],
          ),
        ],
      );
      final container = await pumpAt(
        tester,
        brightness: brightness,
        atMs: at,
        const Scaffold(body: AccountsPage()),
        overrides: [
          await _icons(tester),
          phone.asOverride,
          fakeVault(
            FakeVaultController(
              openVault(
                accounts: [account('github', 'GitHub', 'adalovelace'), account('proton', 'Proton', 'ada@example.org')],
                // Remembered from a read over USB, which named the key; over NFC it gives no name.
                keyAccounts: [
                  for (final (issuer, label) in [
                    ('Bank', 'ada@example.org'),
                    ('Cloudflare', 'ada@example.org'),
                    ('Registrar', 'ada@example.org'),
                    ('Mail server', 'root'),
                  ])
                    KeyAccount(
                      id: issuer,
                      device: '0102030405060708',
                      keyName: 'YubiKey',
                      name: '$issuer:$label',
                      issuer: issuer,
                      label: label,
                      addedAt: day,
                    ),
                ],
              ),
              apply: true,
            ),
          ),
        ],
      );
      phone.arrive(key.device(kinds: {SecurityKeyLinkKind.nfc}));
      final read = await container.read(keyCodesProvider.notifier).read();
      expect(read.outcome, KeyCodesOutcome.done);
      // With the two seconds and more that settling the screen takes, read 20 seconds ago.
      await tester.pump(const Duration(seconds: 17));
      await takeScreenshot(tester, 'codes_tab_on_key_$name');
      await leaveScreen(tester);
    });
  }
}

/// The service logos, read for real outside the fake clock, so every tile shows its logo.
Future<Override> _icons(WidgetTester tester) async {
  final icons = await tester.runAsync(ServiceIcons.load);
  return serviceIconsProvider.overrideWith((ref) async => icons!);
}
