import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/features/logins/login_edit_sheet.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/website_rule.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

// the add-cards-identities-and-websites plan, tasks 7.1 and 7.2
void main() {
  Finder inEdit(Finder finder) => find.descendant(of: find.byType(LoginEditSheet), matching: finder);
  Finder addressField(int row) => inEdit(find.widgetWithText(TextField, t('logins.field.website'))).at(row);
  Finder save() => inEdit(find.widgetWithText(FilledButton, t('logins.save')));
  List<Login> logins(TestApp app) => app.container.read(vaultControllerProvider).logins;

  /// A new login's sheet, from Add to vault, with a name and a password so that only the websites decide Save.
  Future<TestApp> openNewLogin(WidgetTester tester) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.addToVault'))));
    await tapOn(tester, find.text(t('vault.add.login')));
    await tester.enterText(inEdit(field(t('logins.field.name'))), 'Example Co SSO');
    await tester.enterText(inEdit(field(t('logins.field.password'))), 'kT9#vq2L-wPz8!mR4x');
    await tester.pump();
    return app;
  }

  /// Picks the rule named by message [id] in the picker of website [row].
  Future<void> pickRule(WidgetTester tester, String id, {int row = 0}) async {
    final picker = inEdit(find.byType(DropdownButtonFormField<int>)).at(row);
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t(id)).last);
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, Finder finder, String text) async {
    await tester.ensureVisible(finder);
    await tester.enterText(finder, text);
    await tester.pump();
  }

  String only(String host) => t('websiteRules.where.only', {'host': host});

  group('the sheet says where each rule fills', () {
    testWidgets('a Default website fills on its domain, and a new login stores hosts alone', (tester) async {
      final app = await openNewLogin(tester);
      await type(tester, addressField(0), 'https://Larkspur.example/login');

      expect(
        inEdit(
          find.text(
            t('websiteRules.hint.same', {
              'where': t('websiteRules.where.under', {'host': 'larkspur.example'}),
            }),
          ),
        ),
        findsOneWidget,
      );
      await tapOn(tester, save());
      expect(logins(app).single.websites, ['larkspur.example']);
      expect(logins(app).single.uris, isNull);
    });

    testWidgets('Host fills there only, and the sheet ends with what phones fill', (tester) async {
      await openNewLogin(tester);
      await type(tester, addressField(0), 'example-co.okta.com');
      await pickRule(tester, 'websiteRules.rule.host');

      expect(inEdit(find.text(t('websiteRules.hint.same', {'where': only('example-co.okta.com')}))), findsOneWidget);
      expect(inEdit(find.text(t('websiteRules.phones.on', {'domains': only('example-co.okta.com')}))), findsOneWidget);
    });

    testWidgets('Exact says the browser fills that address only and phones fill on its host', (tester) async {
      await openNewLogin(tester);
      await type(tester, addressField(0), 'https://intranet.example.co/login');
      await pickRule(tester, 'websiteRules.rule.exact');

      final browser = t('websiteRules.where.address', {'address': 'https://intranet.example.co/login'});
      expect(inEdit(find.text(t('websiteRules.hint.both', {'browser': browser, 'phones': only('intranet.example.co')}))), findsOneWidget);
    });

    testWidgets('a second website with its own rule is stored beside the first, hosts in websites', (tester) async {
      final app = await openNewLogin(tester);
      await type(tester, addressField(0), 'example.co');
      await tapOn(tester, inEdit(find.text(t('logins.field.moreWebsite'))));
      await type(tester, addressField(1), 'example-co.okta.com');
      await pickRule(tester, 'websiteRules.rule.host', row: 1);
      await tapOn(tester, save());

      final login = logins(app).single;
      expect(login.websites, ['example.co', 'example-co.okta.com']);
      expect([for (final rule in login.rules) '${rule.uri}:${rule.match}'], ['example.co:null', 'example-co.okta.com:1']);
    });

    testWidgets('a website on Never is kept, fills nowhere, and leaves websites without its host', (tester) async {
      final app = await openNewLogin(tester);
      await type(tester, addressField(0), 'wiki.example.co');
      await pickRule(tester, 'websiteRules.rule.never');

      expect(inEdit(find.text(t('websiteRules.phones.none'))), findsOneWidget);
      await tapOn(tester, save());
      expect(logins(app).single.websites ?? const <String>[], isEmpty);
      expect(logins(app).single.rules.single.match, WebsiteMatch.never);
    });
  });

  group('Advanced rules carry a warning', () {
    testWidgets('the picker lists the five rules, then Advanced with Starts with and Regular expression', (tester) async {
      await openNewLogin(tester);
      final picker = inEdit(find.byType(DropdownButtonFormField<int>));
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();

      for (final id in ['default', 'baseDomain', 'host', 'exact', 'never', 'startsWith', 'regularExpression']) {
        expect(find.text(t('websiteRules.rule.$id')), findsWidgets, reason: id);
      }
      expect(find.text(t('websiteRules.rule.advanced').toUpperCase()), findsOneWidget);
    });

    testWidgets('Starts with shows the warning under the website, and Default does not', (tester) async {
      await openNewLogin(tester);
      await type(tester, addressField(0), 'https://intranet.example.co/login');
      expect(inEdit(find.text(t('websiteRules.warning'))), findsNothing);

      await pickRule(tester, 'websiteRules.rule.startsWith');
      expect(inEdit(find.text(t('websiteRules.warning'))), findsOneWidget);
    });
  });

  group('a regular expression has a test box', () {
    const pattern = r'^https://([a-z]+\.)?example\.co/';

    Future<TestApp> withPattern(WidgetTester tester, String text) async {
      final app = await openNewLogin(tester);
      await type(tester, addressField(0), text);
      await pickRule(tester, 'websiteRules.rule.regularExpression');
      return app;
    }

    testWidgets('says whether the pattern matches the address typed, and that phones never fill it', (tester) async {
      await withPattern(tester, pattern);
      final box = inEdit(field(t('websiteRules.test.label')));

      await type(tester, box, 'https://shop.example.co/cart');
      expect(inEdit(find.text(t('websiteRules.test.matches'))), findsOneWidget);

      await type(tester, box, 'https://example.co.evil.test/');
      expect(inEdit(find.text(t('websiteRules.test.noMatch'))), findsOneWidget);
      expect(inEdit(find.text(t('websiteRules.test.phones'))), findsOneWidget);
    });

    testWidgets('refuses a back-reference, says so, and Save is unavailable', (tester) async {
      await withPattern(tester, r'(a)\1');

      expect(inEdit(find.text(t('websiteRules.refusal.backReference'))), findsOneWidget);
      expect(tester.widget<FilledButton>(save()).onPressed, isNull);
    });

    testWidgets('answers at once that (a+)+\$ does not match 2,000 letters and a !', (tester) async {
      await withPattern(tester, r'(a+)+$');

      await type(tester, inEdit(field(t('websiteRules.test.label'))), '${'a' * 2000}!');
      expect(inEdit(find.text(t('websiteRules.test.noMatch'))), findsOneWidget);
    });

    testWidgets('a good pattern is stored as the rule, and no host reaches websites', (tester) async {
      final app = await withPattern(tester, pattern);
      await tapOn(tester, save());

      final login = logins(app).single;
      expect(login.rules.single.match, WebsiteMatch.regularExpression);
      expect(login.rules.single.uri, pattern);
      expect(login.websites ?? const <String>[], isEmpty);
    });
  });

  testWidgets('a refused pattern read from elsewhere shows Can’t be checked, and Save still works', (tester) async {
    final app = TestApp();
    await startApp(tester, app);
    await createVault(tester);
    const rules = [WebsiteRule(r'(a)\1', match: WebsiteMatch.regularExpression)];
    await app.container
        .read(vaultControllerProvider.notifier)
        .addLogin(const Login(id: 'l1', name: 'Imported', password: 'x', uris: rules, addedAt: 0));
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, tab('nav.vault'));
    await tapOn(tester, find.text(t('vault.filter.logins')));
    await tapOn(tester, find.text('Imported'));
    await tapOn(tester, find.text(t('logins.edit')));

    expect(inEdit(find.text(t('websiteRules.cantCheck'))), findsOneWidget);
    expect(inEdit(find.text(t('websiteRules.refusal.backReference'))), findsNothing);
    await type(tester, inEdit(field(t('logins.field.note'))), 'checked by hand');
    expect(tester.widget<FilledButton>(save()).onPressed, isNotNull);
    await tapOn(tester, save());

    expect(logins(app).single.rules.single.uri, r'(a)\1');
    expect(logins(app).single.note, 'checked by hand');
  });
}
