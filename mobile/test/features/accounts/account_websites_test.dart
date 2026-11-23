import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_websites.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/website_rule.dart';

import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart';

void main() {
  const nextcloud = OtpAccount(id: 'n1', issuer: 'Nextcloud', label: 'alice', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
  const github = OtpAccount(id: 'g1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

  /// The section for [account], and what it last handed on as the changed account.
  Future<List<OtpAccount>> pump(WidgetTester tester, OtpAccount account) async {
    final updates = <OtpAccount>[];
    await pumpOnPage(
      tester,
      SingleChildScrollView(
        child: AccountWebsites(account: account, onUpdate: updates.add),
      ),
      center: false,
      overrides: [realDirectory],
    );
    await tester.pumpAndSettle();
    return updates;
  }

  testWidgets('adds a website from a pasted address, as its host', (tester) async {
    final updates = await pump(tester, nextcloud);
    expect(find.text(t('accountWebsites.noneFound', {'name': 'Nextcloud'})), findsOneWidget);

    await tester.tap(find.text(t('accountWebsites.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://Cloud.Example.org/login');
    await tester.pump();
    await tester.tap(find.text(t('websiteDialog.add')));
    await tester.pumpAndSettle();

    expect(updates.single.websites, ['cloud.example.org']);
  });

  testWidgets('refuses what isn’t a website, and says why', (tester) async {
    final updates = await pump(tester, nextcloud);
    await tester.tap(find.text(t('accountWebsites.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my bank');
    await tester.pump();
    await tester.tap(find.text(t('websiteDialog.add')));
    await tester.pumpAndSettle();

    expect(find.text(t('websiteDialog.invalid')), findsOneWidget);
    expect(updates, isEmpty);
  });

  testWidgets('removes a website the person added, and the key with the last one', (tester) async {
    final updates = await pump(tester, nextcloud.copyWith(websites: ['cloud.example.org']));
    expect(find.text('cloud.example.org'), findsOneWidget);

    await tester.tap(find.text(t('accountWebsites.remove')));
    await tester.pumpAndSettle();

    expect(updates.single.websites, isNull);
    expect(updates.single.toJson().containsKey('websites'), isFalse);
  });

  testWidgets('lists what the directory gives as found by Kemlock, with no Remove', (tester) async {
    await pump(tester, github);

    expect(find.text('github.com'), findsOneWidget);
    expect(find.text(t('accountWebsites.found')), findsOneWidget);
    expect(find.text(t('accountWebsites.remove')), findsNothing);
    expect(find.text(t('accountWebsites.body')), findsOneWidget);
  });

  // the add-cards-identities-and-websites plan, task 7.3
  Future<void> pickRule(WidgetTester tester, String id) async {
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t(id)).last);
    await tester.pumpAndSettle();
  }

  testWidgets('adds a website on a rule from the dialog, its host in websites', (tester) async {
    final updates = await pump(tester, nextcloud);

    await tester.tap(find.text(t('accountWebsites.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'example-co.okta.com');
    await tester.pump();
    await pickRule(tester, 'websiteRules.rule.host');
    await tester.tap(find.text(t('websiteDialog.add')));
    await tester.pumpAndSettle();

    final saved = updates.single;
    expect(saved.websites, ['example-co.okta.com']);
    expect([for (final rule in saved.rules) '${rule.uri}:${rule.match}'], ['example-co.okta.com:1']);
  });

  testWidgets('keeps the directory’s website first, with no Remove and no rule button, above the ones added', (tester) async {
    await pump(
      tester,
      github.copyWith(
        websites: ['github.example.org'],
        uris: [const WebsiteRule('github.example.org', match: WebsiteMatch.host)],
      ),
    );

    final found = tester.getTopLeft(find.text('github.com')).dy;
    final own = tester.getTopLeft(find.text('github.example.org')).dy;
    expect(found, lessThan(own));
    expect(find.text(t('accountWebsites.remove')), findsOneWidget);
    expect(find.byTooltip(t('websiteRules.edit.title')), findsOneWidget);
  });

  testWidgets('changes the rule of a website the person added, keeping its address', (tester) async {
    final updates = await pump(tester, nextcloud.copyWith(websites: ['cloud.example.org']));

    await tester.tap(find.byTooltip(t('websiteRules.edit.title')));
    await tester.pumpAndSettle();
    await pickRule(tester, 'websiteRules.rule.never');
    await tester.tap(find.text(t('websiteRules.edit.save')));
    await tester.pumpAndSettle();

    final saved = updates.single;
    expect([for (final rule in saved.rules) '${rule.uri}:${rule.match}'], ['cloud.example.org:5']);
    // On Never it fills nowhere, so websites no longer holds its host
    expect(saved.websites ?? const <String>[], isEmpty);
  });

  testWidgets('a website that is only a rule that fills nowhere is listed, and removing it clears both lists', (tester) async {
    final never = nextcloud.copyWith(uris: [const WebsiteRule('wiki.example.co', match: WebsiteMatch.never)]);
    final updates = await pump(tester, never);
    expect(find.text('wiki.example.co'), findsOneWidget);

    await tester.tap(find.text(t('accountWebsites.remove')));
    await tester.pumpAndSettle();

    expect(updates.single.uris, isNull);
    expect(updates.single.toJson().keys, isNot(contains('uris')));
    expect(updates.single.toJson().keys, isNot(contains('websites')));
  });
}
