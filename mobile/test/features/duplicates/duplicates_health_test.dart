import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/duplicates/duplicates_provider.dart';
import 'package:kemlock/features/settings/app_version.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';

Login _login(String id, String password) =>
    Login(id: id, name: 'Larkspur $id', username: 'sam', password: password, websites: const ['larkspur.example'], addedAt: 1);

/// The app on Settings with a vault holding one login. The asset bundle can't load the Public Suffix List's
/// hash in fake time, so it is given.
Future<TestApp> _openSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp();
  await tester.runAsync(() => app.createVault('pw'));
  await app.pump(
    tester,
    overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0'), suffixListHashProvider.overrideWith((ref) async => 'none')],
  );
  await app.unlock(tester, 'pw');
  app.controller.biometricOffered();
  await app.controller.addLogin(_login('l1', 'one'));
  app.container.read(routerProvider).go('/settings');
  await tester.pumpAndSettle();
  return app;
}

// The plan's task 4.2: the vault health card counts the groups of duplicates
void main() {
  testWidgets('shows no Duplicates row while the vault holds nothing twice', (tester) async {
    await _openSettings(tester);

    expect(find.text(t('settings.health.duplicates')), findsNothing);
  });

  testWidgets('counts one group after an import adds a login of the same account', (tester) async {
    final app = await _openSettings(tester);

    await app.controller.imported(app.state.accounts, app.state.backupServices, logins: [_login('l2', 'two')]);
    await tester.pumpAndSettle();

    expect(find.text(t('settings.health.duplicates')), findsOneWidget);
    expect(find.text(t('settings.health.duplicatesSome', {'count': 1})), findsOneWidget);
  });

  testWidgets('opens the Duplicates screen from its row', (tester) async {
    final app = await _openSettings(tester);
    await app.controller.imported(app.state.accounts, app.state.backupServices, logins: [_login('l2', 'two')]);
    await tester.pumpAndSettle();

    // The row's title is the only "Duplicates" on screen until the sheet opens
    expect(find.text(t('duplicates.title')), findsOneWidget);
    await tester.tap(find.text(t('settings.health.review')));
    await tester.pumpAndSettle();

    // Then the sheet's heading says it too, over the row that is still on the page below
    expect(find.descendant(of: find.byType(DialogHeading), matching: find.text(t('duplicates.title'))), findsOneWidget);
    expect(find.text(t('duplicates.reason.sameAccount')), findsOneWidget);
  });

  testWidgets('counts a second group, and drops the row when Check again finds none', (tester) async {
    final app = await _openSettings(tester);
    await app.controller.imported(
      app.state.accounts,
      app.state.backupServices,
      logins: [
        _login('l2', 'two'),
        Login(id: 'o1', name: 'Other', username: 'kim', password: 'x', websites: const ['beta.example'], addedAt: 1),
        Login(id: 'o2', name: 'Other 2', username: 'kim', password: 'y', websites: const ['beta.example'], addedAt: 1),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text(t('settings.health.duplicatesSome', {'count': 2})), findsOneWidget);

    await app.controller.deleteLogin(app.state.logins.firstWhere((login) => login.id == 'l2'));
    await app.controller.deleteLogin(app.state.logins.firstWhere((login) => login.id == 'o2'));
    await app.container.read(duplicatesProvider.notifier).check();
    await tester.pumpAndSettle();

    expect(find.text(t('settings.health.duplicates')), findsNothing);
  });
}
