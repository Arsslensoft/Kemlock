import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/breaches/breach_providers.dart';
import 'package:kemlock/features/breaches/breach_scan.dart';
import 'package:kemlock/features/breaches/breach_widgets.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart' show FakeLinks;
import 'breach_kit.dart';

/// The breaches of [account] on a page, as its sheet shows them.
Future<void> _pump(WidgetTester tester, OtpAccount account, {FakeLinks? links}) => pumpOnPage(
  tester,
  AccountBreaches(account: account),
  overrides: [
    breachFindingsProvider.overrideWithValue(scanBreaches([account], const [], fixtureBreaches)),
    (links ?? FakeLinks()).asOverride,
  ],
);

void main() {
  testWidgets('the credit names Have I Been Pwned and opens its site', (tester) async {
    final links = FakeLinks();
    await pumpOnPage(tester, const BreachCredit(), overrides: [links.asOverride]);

    expect(find.text('Breach data from Have I Been Pwned'), findsOneWidget);
    await tester.tap(find.byType(BreachCredit));
    await tester.pump();

    expect(links.opened, [Uri.parse('https://haveibeenpwned.com')]);
  });

  testWidgets('a new breach shows as a notice with its date, size, domain and what to do', (tester) async {
    await _pump(tester, breachAccount('a', 'Canva'));

    final notice = find.byType(AppAlert);
    expect(notice, findsOneWidget);
    expect(find.descendant(of: notice, matching: find.text(t('breaches.alert.title', {'name': 'Canva'}))), findsOneWidget);
    expect(find.text('May 24, 2019 · 137,272,116 accounts · canva.com'), findsOneWidget);
    expect(find.text(t('breaches.passwords')), findsOneWidget);
    expect(find.text(t('breaches.advice')), findsOneWidget);
    expect(find.widgetWithText(TextButton, t('breaches.dealtWith')), findsOneWidget);
    expect(find.text(t('breaches.earlier')), findsNothing);
    expect(find.byType(BreachCredit), findsOneWidget);
  });

  testWidgets('a new breach that took no passwords does not say it did', (tester) async {
    await _pump(tester, breachAccount('a', 'Trello'));

    expect(find.text(t('breaches.alert.title', {'name': 'Trello'})), findsOneWidget);
    expect(find.text(t('breaches.passwords')), findsNothing);
    expect(find.text(t('breaches.advice')), findsOneWidget);
  });

  testWidgets('an earlier breach is a plain line by name and year, with no warning and no button', (tester) async {
    await _pump(tester, breachAccount('a', 'Adobe'));

    expect(find.byType(AppAlert), findsNothing);
    expect(find.text(t('breaches.earlier')), findsOneWidget);
    expect(find.text('Adobe, 2013'), findsOneWidget);
    expect(find.text(t('breaches.dealtWith')), findsNothing);
    expect(find.byType(BreachCredit), findsOneWidget);
  });

  testWidgets('a breach marked dealt with is among the earlier ones, and another of the service still warns', (tester) async {
    await _pump(tester, breachAccount('a', 'Twitter', dismissed: ['Twitter200M']));

    // Have I Been Pwned titles the second breach "Twitter (200M)"
    expect(find.byType(AppAlert), findsOneWidget);
    expect(find.text(t('breaches.alert.title', {'name': 'Twitter'})), findsOneWidget);
    expect(find.text('Twitter (200M), 2021'), findsOneWidget);
    expect(find.text(t('breaches.earlier')), findsOneWidget);
  });

  testWidgets('a service with no breach shows nothing, not even the credit', (tester) async {
    await _pump(tester, breachAccount('a', 'GitHub'));

    expect(find.byType(AppAlert), findsNothing);
    expect(find.byType(BreachCredit), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('the breach copy reads in French too', (tester) async {
    final account = breachAccount('a', 'Canva');
    await pumpScreen(
      tester,
      Scaffold(body: AccountBreaches(account: account)),
      locale: AppLocale.fr,
      overrides: [
        breachFindingsProvider.overrideWithValue(scanBreaches([account], const [], fixtureBreaches)),
      ],
    );

    expect(find.text('Canva a subi une fuite de données'), findsOneWidget);
    // French groups thousands with a narrow no-break space
    expect(find.textContaining(RegExp(r'137.272.116 comptes · canva\.com$')), findsOneWidget);
  });
}
