import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/breaches/breach_widgets.dart';
import 'package:kemlock/ui/ui.dart';

import '../features/breaches/breach_kit.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

/// Breach alerts from end to end, through the screens, on the list made from Have I Been
/// Pwned's own answer: a vault whose Trello account was added before Trello's breach was
/// listed.
void main() {
  testWidgets('a new breach shows in Settings, is reviewed, dealt with, and comes back with Undo', (tester) async {
    final app = await openVaultWith(tester, accounts: [breachAccount('a1', 'Trello'), breachAccount('a2', 'GitHub')]);

    // Settings: the vault health card counts the service
    expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);

    // Review opens the sheet, which names the breach and the account
    await tapOn(tester, find.text(t('settings.health.review')));
    expect(find.widgetWithText(DialogHeading, t('breaches.title')), findsOneWidget);
    expect(find.text('Jan 16, 2024 · 15,111,945 accounts · trello.com'), findsOneWidget);
    expect(find.text('Trello · a1@example.com'), findsOneWidget);
    expect(find.byType(BreachCredit), findsOneWidget);

    // Dealt with: the sheet has nothing left, and behind it the line is back in order
    await tapOn(tester, find.text(t('breaches.dealtWith')));
    expect(find.text(t('breaches.empty')), findsOneWidget);
    expect(find.text(t('settings.health.breachesNone')), findsOneWidget);
    expect(app.state.accounts.first.breachesDismissed, ['Trello']);

    // Undo, from the toast: the breach is new again
    await tapOn(tester, find.text(t('app.undo')));
    expect(find.text(t('breaches.empty')), findsNothing);
    expect(find.text(t('settings.health.breachesSome', {'count': 1})), findsOneWidget);
    expect(app.state.accounts.first.breachesDismissed, isNull);
  });

  testWidgets('an account\'s sheet warns of the breach, and lists it as an earlier one once dealt with', (tester) async {
    final app = await openVaultWith(
      tester,
      route: '/',
      accounts: [breachAccount('a1', 'Trello', label: 'me')],
    );

    await tapOn(tester, accountRow('Trello'));
    expect(find.descendant(of: accountSheet, matching: find.text(t('breaches.alert.title', {'name': 'Trello'}))), findsOneWidget);
    expect(find.descendant(of: accountSheet, matching: find.byType(BreachCredit)), findsOneWidget);

    await tapOn(tester, find.descendant(of: accountSheet, matching: find.text(t('breaches.dealtWith'))));

    expect(find.text(t('breaches.alert.title', {'name': 'Trello'})), findsNothing);
    expect(find.descendant(of: accountSheet, matching: find.text(t('breaches.earlier'))), findsOneWidget);
    expect(find.descendant(of: accountSheet, matching: find.text('Trello, 2024')), findsOneWidget);
    expect(app.state.accounts.single.breachesDismissed, ['Trello']);

    // The vault stays dealt with after the app starts again
    final again = await app.restart(tester);
    await again.unlock(tester, 'pw');
    expect(again.state.accounts.single.breachesDismissed, ['Trello']);
  });
}
