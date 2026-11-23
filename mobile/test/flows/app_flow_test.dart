import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

const _secret = 'JBSWY3DPEHPK3PXP';

/// The search box, named "Search accounts" as the web field was by its aria-label.
Finder get _search => find.descendant(of: find.bySemanticsLabel(RegExp('^${t('accounts.searchLabel')}')), matching: find.byType(TextField));

/// The look the app is in, as the `light` and `dark` classes on the page showed it.
ThemeMode _themeMode(WidgetTester tester) => tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

/// The brightness the screens are drawn in.
Brightness _brightness(WidgetTester tester) => Theme.of(tester.element(tab('nav.settings'))).brightness;

/// The flows of `src/App.test.tsx`: the whole app from its first launch,
/// with its router and its crypto (scrypt made cheap), on storage in
/// memory. The web app reloaded within its session window and stayed
/// open; the phone app, started again, asks for the password.
void main() {
  testWidgets('walks through the vault lifecycle', (tester) async {
    final app = await startApp(tester, TestApp());

    // First launch: create the vault
    await createVault(tester);

    // Empty vault: add an account by hand
    await addFirstAccount(tester, 'GitHub', _secret);
    expect(find.text('GitHub'), findsOneWidget);
    expect(code(RegExp(r'^\d{3} \d{3}$')), findsOneWidget);

    // The secret is only ever stored encrypted
    final stored = storedText(app);
    expect(stored, isNot(contains(_secret)));
    expect(stored, isNot(contains('GitHub')));

    // Pin it from the detail sheet; it moves to the Pinned section
    await tapOn(tester, accountRow('GitHub'));
    await tapOn(tester, find.descendant(of: accountSheet, matching: find.text(t('accountSheet.pin'))));
    expect(section('accounts.section.pinned'), findsOneWidget);
    await tapOn(tester, find.descendant(of: accountSheet, matching: find.byTooltip(t('accountSheet.close'))));
    expect(accountSheet, findsNothing);

    // Search narrows the list, and clearing it brings the list back
    await tester.enterText(_search, 'nothing-like-this');
    await tester.pumpAndSettle();
    expect(find.text(t('accounts.noMatches.title', {'query': 'nothing-like-this'})), findsOneWidget);
    expect(accountRow('GitHub'), findsNothing);
    await tapOn(tester, find.byTooltip(t('accounts.clearSearch')));
    expect(accountRow('GitHub'), findsOneWidget);

    // Lock, then unlock with the master password
    await tapOn(tester, find.byTooltip(t('app.tooltip.lockVault')));
    expect(passwordField, findsOneWidget);
    expect(find.text('GitHub'), findsNothing);

    await submitPassword(tester, 'wrong password');
    await pumpUntil(tester, find.text(t('unlock.error.incorrectPassword')));

    await submitPassword(tester, masterPassword);
    await pumpUntil(tester, find.text('GitHub'));

    // Start the app again: it asks for the password, and the pin survived
    await app.restart(tester);
    expect(passwordField, findsOneWidget);
    await submitPassword(tester, masterPassword);
    await pumpUntil(tester, find.text('GitHub'));
    expect(section('accounts.section.pinned'), findsOneWidget);
  });

  testWidgets('brings a removed account back with Undo', (tester) async {
    final app = await startApp(tester, TestApp());
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', _secret);

    // Remove it from the detail sheet
    await tapOn(tester, accountRow('GitHub'));
    await tapOn(tester, find.descendant(of: accountSheet, matching: find.text(t('accountCard.tooltip.remove'))));
    await tapOn(tester, find.descendant(of: find.byType(ConfirmDialog), matching: find.text(t('app.deleteAccount.confirm'))));
    expect(find.text(t('app.snack.accountRemoved', {'name': 'GitHub'})), findsOneWidget);
    expect(find.text(t('app.empty.otp.title')), findsOneWidget);

    // Undo puts it back, and the vault it restored survives a restart
    await tapOn(tester, find.text(t('app.undo')));
    expect(accountRow('GitHub'), findsOneWidget);

    await app.restart(tester);
    await submitPassword(tester, masterPassword);
    await pumpUntil(tester, accountRow('GitHub'));
  });

  testWidgets('switches between tabs and changes the look', (tester) async {
    await startApp(tester, TestApp());
    await createVault(tester);

    await tapOn(tester, tab('nav.backup'));
    expect(find.text(t('app.empty.backup.title')), findsOneWidget);
    expect(tester.getSemantics(tab('nav.backup')), selected);

    await tapOn(tester, tab('nav.settings'));
    expect(find.text(t('settings.health.label').toUpperCase()), findsOneWidget);

    final light = find.bySemanticsLabel(t('settings.theme.light'));
    final dark = find.bySemanticsLabel(t('settings.theme.dark'));
    // Settings is a lazy list: the look's rows are built once scrolled to
    await tester.scrollUntilVisible(light, 300, scrollable: find.byType(Scrollable).first);
    await tapOn(tester, light);
    expect(tester.getSemantics(light), isSemantics(isChecked: true));
    expect(_themeMode(tester), ThemeMode.light);
    expect(_brightness(tester), Brightness.light);

    await tapOn(tester, dark);
    expect(tester.getSemantics(dark), isSemantics(isChecked: true));
    expect(_themeMode(tester), ThemeMode.dark);
    expect(_brightness(tester), Brightness.dark);
  });
}
