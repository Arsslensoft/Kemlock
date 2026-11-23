import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/build_kind.dart';
import 'package:kemlock/core/project_links.dart';
import 'package:kemlock/features/settings/about_page.dart';
import 'package:kemlock/features/settings/app_version.dart';
import 'package:kemlock/features/settings/settings_page.dart';
import 'package:kemlock/features/settings/terms_page.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/router.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart' show FakeLinks;

/// The whole app, unlocked, on a screen tall enough for all of [location].
Future<TestApp> _open(WidgetTester tester, String location, {List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp();
  await tester.runAsync(() => app.createVault('pw'));
  await app.pump(tester, overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0'), ...overrides]);
  await app.unlock(tester, 'pw');
  app.container.read(routerProvider).go(location);
  await tester.pumpAndSettle();
  return app;
}

void main() {
  group('About', () {
    testWidgets('shows the app, its version, its features and its promise', (tester) async {
      await _open(tester, '/about');

      expect(find.text(t('app.settings.section.about')), findsOneWidget);
      expect(find.text(t('app.title')), findsOneWidget);
      expect(find.text(t('app.about.tagline')), findsOneWidget);
      expect(find.text(t('settings.version', {'version': '1.1.0'})), findsOneWidget);
      expect(find.text(t('app.about.developer', {'name': developerName})), findsOneWidget);
      expect(find.text(t('app.about.description')), findsOneWidget);
      expect(find.text(t('app.about.features.title').toUpperCase()), findsOneWidget);
      expect(find.text(t('about.section.promise').toUpperCase()), findsOneWidget);
      for (final id in [
        'app.about.feature.offline',
        'app.about.feature.encrypted',
        'app.about.feature.biometric',
        'app.about.feature.qr',
        'app.about.privacy.title',
        'app.about.storage.title',
        'app.about.postquantum.title',
      ]) {
        expect(find.text(t(id)), findsOneWidget, reason: id);
      }
    });

    // openspec: add-passwords, task 3.5
    testWidgets('credits the word list and the Public Suffix List', (tester) async {
      await _open(tester, '/about');
      await tester.scrollUntilVisible(find.text(t('about.credits')), 200, scrollable: find.byType(Scrollable).first);

      expect(find.text(t('about.section.credits').toUpperCase()), findsOneWidget);
      expect(find.textContaining('CC BY 3.0 US'), findsOneWidget);
      expect(find.textContaining('MPL 2.0'), findsOneWidget);
    });

    // openspec: add-fdroid-release, "The app says which build it is"
    testWidgets('says which build it is, and hands the browser the page on checking it', (tester) async {
      final links = FakeLinks();
      await _open(tester, '/about', overrides: [links.asOverride]);

      final free = buildKind == BuildKind.free;
      expect(find.text(t(free ? 'about.build.free' : 'about.build.store')), findsOneWidget);
      expect(find.text(t(free ? 'about.build.store' : 'about.build.free')), findsNothing);
      expect(links.opened, isEmpty);

      await tester.ensureVisible(find.text(t('about.build.check')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('about.build.check')));
      await tester.pumpAndSettle();

      expect(links.opened, [reproducibleBuildsPage]);
      expect(reproducibleBuildsPage.path, endsWith('/docs/reproducible-builds.md'));
    });

    testWidgets('goes back to Settings', (tester) async {
      await _open(tester, '/about');

      await tester.tap(find.bySemanticsLabel(t('nav.back')));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('goes back to Settings with the phone back gesture', (tester) async {
      await _open(tester, '/about');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('leads to the terms', (tester) async {
      await _open(tester, '/about');

      await tester.tap(find.text(t('app.terms.title')));
      await tester.pumpAndSettle();

      expect(find.byType(TermsPage), findsOneWidget);
    });
  });

  group('Terms', () {
    testWidgets('shows every section of the terms and the privacy policy', (tester) async {
      await _open(tester, '/terms');

      expect(find.text(t('app.terms.title')), findsOneWidget);
      expect(find.text(t('app.terms.lastUpdated', {'date': 'November 23, 2026'})), findsOneWidget);
      expect(find.text(t('app.terms.intro')), findsOneWidget);
      expect(find.text(t('app.terms.section.terms').toUpperCase()), findsOneWidget);
      expect(find.text(t('app.terms.section.privacy').toUpperCase()), findsOneWidget);
      expect(find.text(t('app.privacy.intro')), findsOneWidget);
      for (var i = 1; i <= 7; i++) {
        expect(find.text(t('app.terms.s$i.title')), findsOneWidget);
        expect(find.text(t('app.terms.s$i.body')), findsOneWidget);
      }
      for (var i = 1; i <= 5; i++) {
        expect(find.text(t('app.privacy.s$i.title')), findsOneWidget);
        expect(find.text(t('app.privacy.s$i.body')), findsOneWidget);
      }
      expect(find.text(t('app.terms.contact', {'name': developerName})), findsOneWidget);
    });

    testWidgets('dates the terms in the app language', (tester) async {
      final app = await _open(tester, '/terms');

      app.container.read(localeProvider.notifier).setLocale(AppLocale.fr);
      await tester.pumpAndSettle();

      expect(find.text(testCatalog.of(AppLocale.fr).t('app.terms.lastUpdated', {'date': '23 novembre 2026'})), findsOneWidget);
    });

    // openspec: add-fdroid-release, "The app says which build it is"
    testWidgets('says which build it is, and hands the browser the page on checking it', (tester) async {
      final links = FakeLinks();
      await _open(tester, '/about', overrides: [links.asOverride]);

      final free = buildKind == BuildKind.free;
      expect(find.text(t(free ? 'about.build.free' : 'about.build.store')), findsOneWidget);
      expect(find.text(t(free ? 'about.build.store' : 'about.build.free')), findsNothing);
      expect(links.opened, isEmpty);

      await tester.ensureVisible(find.text(t('about.build.check')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('about.build.check')));
      await tester.pumpAndSettle();

      expect(links.opened, [reproducibleBuildsPage]);
      expect(reproducibleBuildsPage.path, endsWith('/docs/reproducible-builds.md'));
    });

    testWidgets('goes back to Settings', (tester) async {
      await _open(tester, '/terms');

      await tester.tap(find.bySemanticsLabel(t('nav.back')));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('goes back to Settings with the phone back gesture', (tester) async {
      await _open(tester, '/terms');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });
  });

  // openspec: add-fdroid-release, "The free build has no store"; every build is free now
  testWidgets('About, Privacy and Terms name no store, no store service, no subscription and no Premium', (tester) async {
    String shown() => tester.widgetList<RichText>(find.byType(RichText)).map((text) => text.text.toPlainText()).join('\n');

    await _open(tester, '/about');
    final about = shown();
    final app = await _open(tester, '/terms');
    final terms = shown();
    expect(app.container.read(routerProvider).state.uri.path, '/terms');

    for (final (page, text) in [('About', about), ('Terms and Privacy', terms)]) {
      for (final word in ['App Store', 'Google Play', 'StoreKit', 'subscription', 'Premium']) {
        expect(text.toLowerCase(), isNot(contains(word.toLowerCase())), reason: '$page says "$word"');
      }
    }
    expect(terms, contains(t('app.privacy.s3.title')));
  });
}
