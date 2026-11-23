/// What the flows drive, as `e2e/helpers.ts` and `src/test/render.tsx`
/// gave the specs: starting the app, making the vault, adding an account,
/// and finding things by their copy and by what screen readers hear.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/accounts/add_account_sheet.dart';
import 'package:kemlock/features/vault/owner_check.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';

import '../fakes/fake_scanner.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';

/// The master password the specs used.
const masterPassword = 'Correct-Horse-9';

// RFC 6238 appendix B: the SHA-1 seed "12345678901234567890" gives 89005924 at
// T=1234567890, so the 6-digit code is 005924 (and keeps its leading zeros).
const rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
final rfcTime = DateTime.fromMillisecondsSinceEpoch(1234567890 * 1000, isUtc: true);
const rfcCode = '005 924';

/// A phone 393 points wide with a notch and a home bar, tall enough that
/// every row of Settings is on screen: a browser scrolled to what Playwright
/// clicked, a test taps only what is laid out.
void useTallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 3800) * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

/// Starts [app] on a tall phone, with a fake camera behind the QR
/// viewfinder the Add account sheet opens on, and [overrides].
Future<TestApp> startApp(WidgetTester tester, TestApp app, {List<Override> overrides = const []}) async {
  useTallPhone(tester);
  await app.pump(tester, overrides: [FakeScanner().asOverride, ...overrides]);
  return app;
}

/// Pumps in steps of a tenth of a second until [finder] finds something,
/// for the waits the screens build in (the setup's steps, the vault's
/// opening), then settles. Fails after [timeout] of fake time.
Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 10)}) async {
  const step = Duration(milliseconds: 100);
  for (var waited = Duration.zero; finder.evaluate().isEmpty; waited += step) {
    if (waited > timeout) fail('Waited $timeout for $finder');
    await tester.pump(step);
  }
  await tester.pumpAndSettle();
}

/// Taps [finder], once it is in view, and settles.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The text field labelled [label].
Finder field(String label) => find.widgetWithText(TextField, label);

/// Makes the vault on the setup screen of a phone without one, as
/// `createVault` in `e2e/helpers.ts` did: the password, its confirmation,
/// Create vault, and the wait until the empty Codes tab is up.
Future<void> createVault(WidgetTester tester, {String password = masterPassword}) async {
  expect(find.text(t('setup.title')), findsOneWidget);
  await tester.enterText(field(t('setup.field.password')), password);
  await tester.enterText(field(t('setup.field.confirm')), password);
  await tester.pump();
  await tapOn(tester, find.text(t('setup.button')));
  await pumpUntil(tester, find.text(t('app.empty.otp.title')));
}

/// Adds an account by typing its secret, from the empty Codes tab, as
/// `addFirstAccount` in `e2e/helpers.ts` did. The tab bar's + button has
/// the same name but no text, so this taps the empty state's own button.
Future<void> addFirstAccount(WidgetTester tester, String issuer, String secret) async {
  await tapOn(tester, find.text(t('app.empty.otp.action')));
  final sheet = find.byType(AddAccountSheet);
  await tapOn(tester, find.descendant(of: sheet, matching: find.text(t('addAccount.tab.manual'))));
  await tester.enterText(find.descendant(of: sheet, matching: field(t('addAccount.field.issuer'))), issuer);
  await tester.enterText(find.descendant(of: sheet, matching: field(t('addAccount.field.secret'))), secret);
  await tester.pump();
  await tapOn(tester, find.descendant(of: sheet, matching: find.text(t('addAccount.add'))));
  expect(find.text(t('app.snack.accountAdded', {'name': issuer})), findsOneWidget);
}

/// The button that opens an account's detail sheet, one per listed
/// account: `accountRow` in `e2e/helpers.ts`.
Finder accountRow(String name) => find.byTooltip(t('accountCard.details', {'name': name}));

/// The open detail sheet of an account.
Finder get accountSheet => find.byType(AccountSheet);

/// A code on screen, by its digits grouped as screen readers hear them ("005 924").
Finder code(Pattern grouped) => find.byWidgetPredicate(
  (widget) =>
      widget is CodeDigits &&
      (grouped is RegExp ? grouped.hasMatch(CodeDigits.grouped(widget.code)) : CodeDigits.grouped(widget.code) == grouped),
);

/// A section of the Codes tab, by its title, which shows in capitals.
Finder section(String id) => find.text(t(id).toUpperCase());

/// The lock screen's password field.
Finder get passwordField => field(t('unlock.field.password'));

/// Answers the dialog that asks who it is before a secret leaves the open
/// vault (`features/vault/owner_check.dart`) with [password], and waits
/// until it has checked it and closed.
Future<void> confirmOwner(WidgetTester tester, {String password = masterPassword}) async {
  final dialog = find.byType(OwnerPasswordDialog);
  await pumpUntil(tester, dialog);
  await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), password);
  await tester.pump();
  await tester.tap(find.descendant(of: dialog, matching: find.text(t('confirmOwner.continue'))));
  const step = Duration(milliseconds: 100);
  for (var waited = Duration.zero; dialog.evaluate().isNotEmpty; waited += step) {
    if (waited > const Duration(seconds: 10)) fail('The password dialog never closed');
    await tester.pump(step);
  }
  await tester.pumpAndSettle();
}

/// Types [password] on the lock screen and presses the keyboard's Go key,
/// as the specs pressed Enter. The caller waits for what it expects.
Future<void> submitPassword(WidgetTester tester, String password) async {
  await tester.enterText(passwordField, password);
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await tester.pump();
}

/// A tab of the tab bar, the navigation named "Main", by its name.
Finder tab(String id) => find.descendant(of: find.bySemanticsLabel(t('nav.label')), matching: find.bySemanticsLabel(t(id)));

/// The semantics of a tab marked as the one selected, as `aria-current="page"` marked the web app's.
final Matcher selected = isSemantics(isSelected: true);

/// Where the app's router is, as the address bar showed it.
String location(TestApp app) => app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

/// Sends the app's router to [path], as the specs went to a URL, and settles.
Future<void> goTo(WidgetTester tester, TestApp app, String path) async {
  app.container.read(routerProvider).go(path);
  await tester.pumpAndSettle();
}

/// Everything in the phone's key-value store, keys and values, as the
/// spec read localStorage and sessionStorage.
String storedText(TestApp app) => [for (final key in app.store.storedKeys()) '$key=${app.store.getItem(key)}'].join('\n');
