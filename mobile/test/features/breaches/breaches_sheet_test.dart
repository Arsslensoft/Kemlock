import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/breaches/breach_widgets.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart' show FakeLinks, realDirectory;
import 'breach_kit.dart';

/// The card of the breach Have I Been Pwned calls [name], in the open sheet.
Finder _card(String name) => find.byKey(ValueKey('breach-$name'));

Finder _in(Finder card, String text) => find.descendant(of: card, matching: find.text(text));

/// Opens the Breaches sheet from the Vault health card's Review button.
Future<void> _review(WidgetTester tester) async {
  await tester.tap(find.text(t('settings.health.review')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists each new breach with its facts, the entries it concerns and what to do', (tester) async {
    await openVaultWith(
      tester,
      accounts: [
        breachAccount('a1', 'Canva', label: 'me@work.example'),
        breachAccount('a2', 'canva.com', label: ''),
        breachAccount('a3', 'GitHub'),
      ],
      services: [breachCodes('s1', 'Canva')],
    );
    await _review(tester);

    expect(find.widgetWithText(DialogHeading, t('breaches.title')), findsOneWidget);
    final canva = _card('Canva');
    expect(canva, findsOneWidget);
    expect(_in(canva, 'Canva'), findsOneWidget);
    expect(_in(canva, 'May 24, 2019 · 137,272,116 accounts · canva.com'), findsOneWidget);
    expect(_in(canva, t('breaches.passwords')), findsOneWidget);
    expect(_in(canva, 'Canva · me@work.example'), findsOneWidget);
    expect(_in(canva, 'canva.com'), findsOneWidget);
    expect(_in(canva, t('breaches.entry.codes', {'name': 'Canva'})), findsOneWidget);
    expect(_in(canva, t('breaches.advice')), findsOneWidget);
    expect(find.descendant(of: canva, matching: find.widgetWithText(TextButton, t('breaches.dealtWith'))), findsOneWidget);
    // A service with no breach is not in the sheet
    expect(find.textContaining('GitHub'), findsNothing);
  });

  testWidgets('does not say passwords were taken for a breach that took none', (tester) async {
    await openVaultWith(tester, accounts: [breachAccount('a1', 'Trello')]);
    await _review(tester);

    expect(_in(_card('Trello'), 'Jan 16, 2024 · 15,111,945 accounts · trello.com'), findsOneWidget);
    expect(find.text(t('breaches.passwords')), findsNothing);
    expect(_in(_card('Trello'), t('breaches.advice')), findsOneWidget);
  });

  testWidgets('shows the latest listed breach first, and both breaches of one service', (tester) async {
    await openVaultWith(tester, accounts: [breachAccount('a1', 'Twitter'), breachAccount('a2', 'Trello')]);
    await _review(tester);

    final tops = [
      for (final name in ['Trello', 'Twitter200M', 'Twitter']) tester.getTopLeft(_card(name)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('"Dealt with" takes the breach off the sheet for every entry of the service, and says so when none is left', (tester) async {
    final app = await openVaultWith(
      tester,
      accounts: [breachAccount('a1', 'Trello'), breachAccount('a2', 'Trello')],
      services: [breachCodes('s1', 'Trello')],
    );
    await _review(tester);
    expect(find.text(t('breaches.empty')), findsNothing);

    await tester.tap(find.descendant(of: _card('Trello'), matching: find.text(t('breaches.dealtWith'))));
    await tester.pumpAndSettle();

    expect(_card('Trello'), findsNothing);
    expect(find.text(t('breaches.empty')), findsOneWidget);
    expect(
      [for (final account in app.state.accounts) account.breachesDismissed],
      [
        ['Trello'],
        ['Trello'],
      ],
    );
    expect(app.state.backupServices.single.breachesDismissed, ['Trello']);
    expect(find.text(t('breaches.snack.dealtWith')), findsOneWidget);
  });

  testWidgets('credits Have I Been Pwned, with a link to its site', (tester) async {
    final links = FakeLinks();
    await openVaultWith(tester, accounts: [breachAccount('a1', 'Trello')], overrides: [links.asOverride]);
    await _review(tester);

    expect(find.text(t('breaches.credit')), findsOneWidget);
    await tester.tap(find.byType(BreachCredit));
    await tester.pump();

    expect(links.opened, [Uri.parse('https://haveibeenpwned.com')]);
  });

  testWidgets('links to the service\'s 2FA page from the 2FA directory', (tester) async {
    final links = FakeLinks();
    await openVaultWith(tester, accounts: [breachAccount('a1', 'Trello')], overrides: [links.asOverride, realDirectory]);
    await _review(tester);

    await tester.tap(find.text(t('breaches.twoFactorPage')));
    await tester.pump();

    expect(links.opened.single.host, 'support.atlassian.com');
  });

  testWidgets('finds the breach of an account in a shared space', (tester) async {
    await openVaultWith(tester, accounts: [breachAccount('a1', 'Trello').copyWith(spaceId: 'space-1')]);

    expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);
  });
}
