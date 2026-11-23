import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/core/build_kind.dart';
import 'package:kemlock/features/accounts/accounts_page.dart';
import 'package:kemlock/features/accounts/add_account_sheet.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../fakes/fake_scanner.dart';
import '../helpers/app_harness.dart';
import '../helpers/screenshots.dart';

/// The phone screenshots of the F-Droid listing (openspec: add-fdroid-release, task 5.2): the
/// free build's Codes, Vault, a scan and Settings with its support row, in English and French.
/// Written only by a run on the free build; copy them to each locale's folder of
/// fastlane/metadata/android, under images/phoneScreenshots:
///
///     tool/build/use_free.sh && flutter pub get --enforce-lockfile
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/listing_test.dart
void main() {
  final added = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch;
  OtpAccount account(String id, String issuer, String label) =>
      OtpAccount(id: id, issuer: issuer, label: label, secret: 'JBSWY3DPEHPK3PXP${id.toUpperCase()}', addedAt: added);
  final accounts = [
    account('github', 'GitHub', 'octocat'),
    account('google', 'Google', 'alice@example.org'),
    account('proton', 'Proton', 'alice@example.org'),
    account('dropbox', 'Dropbox', 'alice@example.org'),
    account('mastodon', 'Mastodon', '@alice@example.social'),
  ];

  for (final locale in [AppLocale.en, AppLocale.fr]) {
    /// The free build's app on a phone, unlocked on [location], in [locale] and the light scheme.
    Future<TestApp> open(WidgetTester tester, String location, {FakeScanner? scanner}) async {
      usePhoneScreen(tester);
      final app = TestApp();
      await tester.runAsync(() async {
        final session = await app.createVault('pw');
        await app.vaultStore.saveAccounts(accounts, session);
      });
      app.store
        ..setItem(keyTheme, ThemeChoice.light.name)
        ..setItem(keyLocale, locale.name);
      await app.pump(tester, overrides: [if (scanner != null) scanner.asOverride]);
      await app.unlock(tester, 'pw');
      app.container.read(routerProvider).go(location);
      await tester.pumpAndSettle();
      return app;
    }

    if (buildKind != BuildKind.free) continue;

    testScreenshot('listing: codes, ${locale.name}', (tester) async {
      await open(tester, '/');
      await takeScreenshot(tester, 'listing_${locale.name}_1_codes');
    });

    testScreenshot('listing: vault, ${locale.name}', (tester) async {
      await open(tester, '/vault');
      await takeScreenshot(tester, 'listing_${locale.name}_2_vault');
    });

    testScreenshot('listing: a scan, ${locale.name}', (tester) async {
      await open(tester, '/', scanner: FakeScanner(animated: true));
      unawaited(showAddAccountSheet(tester.element(find.byType(AccountsPage))));
      // The viewfinder never settles while it looks; the sheet is up after a second.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleForScreenshot(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await captureScreenshot('listing_${locale.name}_3_scan');
    });

    testScreenshot('listing: settings, ${locale.name}', (tester) async {
      await open(tester, '/settings');
      await takeScreenshot(tester, 'listing_${locale.name}_4_settings');
    });
  }
}
