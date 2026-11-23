import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/platform/autofill.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../../fakes/fake_autofill.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart' show realDirectory;

/// The app on Settings with the AutoFill sheet open, the phone answering
/// [status] for codes and [passkeys] for passkeys.
Future<TestApp> _openSheet(
  WidgetTester tester, {
  AutofillStatus status = const AutofillStatus(supported: true, enabled: true, biometrics: true),
  PasskeyStatus passkeys = const PasskeyStatus(supported: true, enabled: false),
  bool hidden = false,
}) async {
  tester.view.physicalSize = const Size(800, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp(autofill: FakeAutofill(current: status)..passkeys = passkeys);
  await tester.runAsync(() async {
    await app.createVault('pw');
    if (hidden) app.vaults.setListed(mainVault, false);
  });
  await app.pump(tester, overrides: [realDirectory]);
  await app.unlock(tester, 'pw');
  app.container.read(routerProvider).go('/settings');
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(GroupRow, t('settings.autofill')));
  await tester.pumpAndSettle();
  return app;
}

Finder get _switch => find.descendant(of: find.widgetWithText(GroupRow, t('autofill.passkeys')), matching: find.byType(Switch));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('says what turning passkeys on keeps outside the vault, and is off at first', (tester) async {
    await _openSheet(tester);
    final label = t('enableBiometric.platform.android.label');

    expect(find.text(t('autofill.passkeys.section').toUpperCase()), findsOneWidget);
    expect(tester.widget<Switch>(_switch).value, isFalse);
    expect(find.text(t('autofill.passkeys.kept', {'label': label})), findsOneWidget);
    // The tests run as Android, which checks an app's passkey requests with its site
    expect(find.text(t('autofill.passkeys.assetLinks')), findsOneWidget);
  });

  testWidgets('turning it on makes the inbox key, saves the setting, and leads to the phone’s settings', (tester) async {
    final app = await _openSheet(tester);

    await tester.tap(_switch);
    await _settle(tester);

    expect(Prefs.parse(app.store.getItem(prefsKey)).passkeys, isTrue);
    expect(app.store.getItem('backmycodes_passkey_inbox'), isNotNull);
    expect(app.autofill.calls, contains('passkeySettings'));
    expect(app.autofill.inboxKeys, isNotEmpty);
    expect(find.text(t('autofill.passkeys.system.android')), findsOneWidget);

    await tester.tap(find.text(t('autofill.passkeys.open')));
    await _settle(tester);
    expect(app.autofill.calls.where((call) => call == 'passkeySettings'), hasLength(2));
  });

  testWidgets('says so once the phone takes passkeys from Kemlock', (tester) async {
    final app = await _openSheet(tester, passkeys: const PasskeyStatus(supported: true, enabled: true));

    await tester.tap(_switch);
    await _settle(tester);

    expect(find.text(t('autofill.passkeys.on')), findsOneWidget);
    expect(app.autofill.calls, isNot(contains('passkeySettings')));
  });

  testWidgets('warns when the phone has no biometrics', (tester) async {
    await _openSheet(tester, status: const AutofillStatus(supported: true, enabled: true, biometrics: false));

    await tester.tap(_switch);
    await _settle(tester);

    expect(find.text(t('autofill.noBiometrics', {'label': t('enableBiometric.platform.android.label')})), findsWidgets);
  });

  testWidgets('says the phone is too old, without a switch', (tester) async {
    await _openSheet(tester, passkeys: PasskeyStatus.unsupported);

    expect(find.text(t('autofill.passkeys.unsupported.android')), findsOneWidget);
    expect(_switch, findsNothing);
  });

  testWidgets('a hidden vault offers no passkeys either', (tester) async {
    await _openSheet(tester, hidden: true);

    expect(find.text(t('autofill.hidden')), findsOneWidget);
    expect(_switch, findsNothing);
  });

  testWidgets('turning it off takes the passkeys and the inbox key off the phone', (tester) async {
    final app = await _openSheet(tester, passkeys: const PasskeyStatus(supported: true, enabled: true));
    await tester.tap(_switch);
    await _settle(tester);
    expect(app.autofill.inboxKeys, isNotEmpty);

    await tester.tap(_switch);
    await _settle(tester);

    expect(Prefs.parse(app.store.getItem(prefsKey)).passkeys, isFalse);
    expect(app.autofill.inboxKeys, isEmpty);
  });
}
