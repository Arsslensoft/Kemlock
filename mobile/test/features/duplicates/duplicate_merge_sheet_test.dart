import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/duplicates/duplicate_merge_sheet.dart';
import 'package:kemlock/features/duplicates/duplicates_provider.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/login.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

Login _login(String id, {String name = 'Proton', String password = 'one', String? spaceId}) =>
    Login(id: id, name: name, username: 'sam', password: password, websites: const ['proton.me'], spaceId: spaceId, addedAt: 0);

/// The app with two logins of one site and username in the vault, the first called [firstName], the
/// second a minute newer and called [secondName], and the merge sheet of their group open.
Future<TestApp> _openSheet(
  WidgetTester tester, {
  String firstName = 'proton.me',
  String secondName = 'Proton Mail',
  String firstPassword = 'one',
  String secondPassword = 'one',
  String? spaceOfFirst,
}) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = DateTime.utc(2026, 11, 21, 12);
  var now = clock;
  final app = TestApp(now: () => now);
  await tester.runAsync(() => app.createVault('pw'));
  await app.pump(tester, overrides: [suffixListHashProvider.overrideWith((ref) async => 'none')]);
  await app.unlock(tester, 'pw');
  app.controller.biometricOffered();
  await app.controller.addLogin(_login('a', name: firstName, password: firstPassword, spaceId: spaceOfFirst));
  now = clock.add(const Duration(minutes: 1));
  await app.controller.addLogin(_login('b', name: secondName, password: secondPassword));
  await app.container.read(duplicatesProvider.notifier).check();
  // The toast of the last login saved would sit over the Merge button: let it go
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
  final group = app.container.read(duplicatesProvider).groups.single;
  unawaited(showDuplicateMergeSheet(tester.element(find.byType(Scaffold).first), group));
  await tester.pumpAndSettle();
  return app;
}

Finder _kept() => find.text('KEPT');

// The plan's task 5.2: the merge sheet
void main() {
  testWidgets('preselects the newest value of a field that differs, and says what stays', (tester) async {
    await _openSheet(tester);

    expect(find.text(t('duplicates.merge.title')), findsOneWidget);
    expect(find.text(t('duplicates.field.name').toUpperCase()), findsOneWidget);
    // Only the name differs; the newest copy stays and has its value picked
    expect(find.text(t('duplicates.field.username').toUpperCase()), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('pick-name-b')), matching: _kept()), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('pick-name-a')), matching: _kept()), findsNothing);
    expect(find.text(t('duplicates.merge.summary', {'name': 'Proton Mail', 'count': 1})), findsOneWidget);
  });

  testWidgets('another pick changes the summary', (tester) async {
    await _openSheet(tester);

    await tester.tap(find.byKey(const ValueKey('pick-name-a')));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byKey(const ValueKey('pick-name-a')), matching: _kept()), findsOneWidget);
    expect(find.text(t('duplicates.merge.summary', {'name': 'proton.me', 'count': 1})), findsOneWidget);
    expect(find.text(t('duplicates.merge.summary', {'name': 'Proton Mail', 'count': 1})), findsNothing);
  });

  testWidgets('shows a password as dots, and says where the one not kept goes', (tester) async {
    await _openSheet(tester, firstPassword: 'old', secondPassword: 'new');

    expect(find.text('••••••••'), findsNWidgets(2));
    expect(find.text('old'), findsNothing);
    expect(find.text(t('duplicates.merge.history')), findsOneWidget);
  });

  testWidgets('lists the websites kept, with a rule where there is one', (tester) async {
    await _openSheet(tester);

    expect(find.text(t('duplicates.merge.websites').toUpperCase()), findsOneWidget);
    expect(find.text('proton.me'), findsWidgets);
  });

  testWidgets('"in two places" preselects the space\'s copy', (tester) async {
    await _openSheet(tester, spaceOfFirst: 'team');

    // The space's copy is the older one, and it is the one kept
    expect(find.descendant(of: find.byKey(const ValueKey('keep-a')), matching: _kept()), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('keep-b')), matching: _kept()), findsNothing);
    expect(find.text(t('duplicates.merge.spaceCopy')), findsOneWidget);
  });

  testWidgets('another item can be kept instead', (tester) async {
    await _openSheet(tester);

    await tester.tap(find.byKey(const ValueKey('keep-a')));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byKey(const ValueKey('keep-a')), matching: _kept()), findsOneWidget);
  });

  testWidgets('Merge saves the merge and closes the sheet', (tester) async {
    final app = await _openSheet(tester);

    await tester.tap(find.text(t('duplicates.merge.confirm')));
    await tester.pumpAndSettle();

    expect(app.state.logins.single.id, 'b');
    expect(find.text(t('duplicates.merge.title')), findsNothing);
  });

  testWidgets('Not duplicates is remembered and closes the sheet, and Cancel only closes it', (tester) async {
    final app = await _openSheet(tester);

    await tester.tap(find.text(t('duplicates.merge.cancel')));
    await tester.pumpAndSettle();
    expect(find.text(t('duplicates.merge.title')), findsNothing);
    expect(app.state.logins, hasLength(2));
    expect(app.container.read(duplicatesProvider).groups, hasLength(1));

    final group = app.container.read(duplicatesProvider).groups.single;
    unawaited(showDuplicateMergeSheet(tester.element(find.byType(Scaffold).first), group));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('duplicates.notDuplicates')));
    await tester.pumpAndSettle();

    expect(find.text(t('duplicates.merge.title')), findsNothing);
    expect(app.state.logins, hasLength(2));
    expect(app.container.read(duplicatesProvider).groups, isEmpty);
  });

  testWidgets('is in French when the app is', (tester) async {
    final app = await _openSheet(tester);
    app.container.read(localeProvider.notifier).setLocale(AppLocale.fr);
    await tester.pumpAndSettle();

    final fr = testCatalog.of(AppLocale.fr);
    expect(find.text(fr.t('duplicates.merge.title')), findsOneWidget);
    expect(find.text(fr.t('duplicates.merge.confirm')), findsOneWidget);
  });
}
