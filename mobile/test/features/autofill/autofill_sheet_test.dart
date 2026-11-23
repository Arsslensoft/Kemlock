import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/autofill.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../../fakes/fake_autofill.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/test_app.dart';
import '../backup/backup_test_kit.dart';

const _off = AutofillStatus(supported: true, enabled: false, biometrics: true);
const _on = AutofillStatus(supported: true, enabled: true, biometrics: true);

/// The app on Settings, with the AutoFill sheet open, the phone's autofill answering [status].
Future<TestApp> _openSheet(WidgetTester tester, {AutofillStatus status = _off, bool turnsOn = true, bool hidden = false}) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp(
    autofill: FakeAutofill(current: status, turnsOn: turnsOn),
  );
  await tester.runAsync(() async {
    final session = await app.createVault('pw');
    await app.vaultStore.saveAccounts([
      const OtpAccount(id: 'a1', issuer: 'GitHub', label: 'alice', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1),
    ], session);
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

Finder _switchOf(String primary) => find.descendant(of: find.widgetWithText(GroupRow, primary), matching: find.byType(Switch));

bool _switchedOn(WidgetTester tester, String primary) => tester.widget<Switch>(_switchOf(primary)).value;

Prefs _prefs(TestApp app) => Prefs.parse(app.store.getItem(prefsKey));

void main() {
  testWidgets('starts off, and says what it does and what it copies', (tester) async {
    await _openSheet(tester);

    expect(find.text(t('autofill.title')), findsWidgets);
    expect(find.text(t('autofill.body', {'label': t('enableBiometric.platform.android.label')})), findsOneWidget);
    expect(find.text(t('autofill.privacy', {'label': t('enableBiometric.platform.android.label')})), findsOneWidget);
    expect(_switchedOn(tester, t('autofill.vault')), isFalse);
    expect(tester.widget<Switch>(_switchOf(t('autofill.names'))).onChanged, isNull, reason: 'nothing to name while it is off');
  });

  testWidgets('turning it on asks the phone to fill from Kemlock and writes the copy', (tester) async {
    final app = await _openSheet(tester);

    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();

    expect(_prefs(app).autofill, isTrue);
    expect(app.autofill.calls, contains('turnOn'));
    expect(find.text(t('autofill.systemOn')), findsOneWidget);
    expect(app.autofill.copies[mainVault], isNotNull);
  });

  testWidgets('doesn’t ask the phone again when it already fills from Kemlock', (tester) async {
    final app = await _openSheet(tester, status: _on);

    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();

    expect(app.autofill.calls, isNot(contains('turnOn')));
    expect(find.text(t('autofill.systemOn')), findsOneWidget);
  });

  testWidgets('offers to turn it on again when the phone was left off', (tester) async {
    final app = await _openSheet(tester, turnsOn: false);

    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();
    expect(find.text(t('autofill.system.android')), findsOneWidget);

    app.autofill.turnsOn = true;
    await tester.tap(find.text(t('autofill.turnOn.android')));
    await tester.pumpAndSettle();

    expect(app.autofill.calls.where((call) => call == 'turnOn'), hasLength(2));
    expect(find.text(t('autofill.systemOn')), findsOneWidget);
  });

  testWidgets('turning names off writes the copy without its index', (tester) async {
    final app = await _openSheet(tester, status: _on);
    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();
    expect(app.autofill.indexes[mainVault], isNotNull);

    await tester.tap(_switchOf(t('autofill.names')));
    await tester.pumpAndSettle();

    expect(_prefs(app).autofillNames, isFalse);
    expect(app.autofill.copies[mainVault], isNotNull);
    expect(app.autofill.indexes[mainVault], isNull);
  });

  testWidgets('turning it off removes the copy', (tester) async {
    final app = await _openSheet(tester, status: _on);
    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();

    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();

    expect(_prefs(app).autofill, isFalse);
    expect(app.autofill.calls.last, 'remove $mainVault');
    expect(app.autofill.copies, isEmpty);
  });

  testWidgets('warns when the phone has no biometrics for the copy’s key', (tester) async {
    await _openSheet(tester, status: const AutofillStatus(supported: true, enabled: true, biometrics: false));

    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();

    expect(find.text(t('autofill.noBiometrics', {'label': t('enableBiometric.platform.android.label')})), findsOneWidget);
  });

  testWidgets('points to Chrome’s setting while Chrome fills with its own passwords', (tester) async {
    final app = await _openSheet(
      tester,
      status: const AutofillStatus(supported: true, enabled: true, biometrics: true, chromeNeedsSetting: true),
    );
    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();

    expect(find.text(t('autofill.chrome')), findsOneWidget);
    await tester.tap(find.text(t('autofill.chrome.open')));
    await tester.pumpAndSettle();

    expect(app.autofill.calls.last, 'chrome');
  });

  testWidgets('says why a phone too old for it can’t fill codes', (tester) async {
    await _openSheet(tester, status: AutofillStatus.unsupported);

    expect(find.text(t('autofill.unsupported.android')), findsOneWidget);
    expect(_switchOf(t('autofill.vault')), findsNothing);
  });

  testWidgets('says why a hidden vault can’t fill codes', (tester) async {
    await _openSheet(tester, hidden: true);

    expect(find.text(t('autofill.hidden')), findsOneWidget);
    expect(_switchOf(t('autofill.vault')), findsNothing);
  });

  testWidgets('shows on Settings whether the vault fills codes', (tester) async {
    final app = await _openSheet(tester, status: _on);
    await tester.tap(_switchOf(t('autofill.vault')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text(t('autofill.vault')))).pop();
    await tester.pumpAndSettle();

    final row = find.widgetWithText(GroupRow, t('settings.autofill'));
    expect(find.descendant(of: row, matching: find.text(t('settings.value.on'))), findsOneWidget);
    expect(app.state.isUnlocked, isTrue);
  });

  // openspec: add-passwords, task 4.2
  group('passwords', () {
    const saves = AutofillStatus(supported: true, enabled: false, biometrics: true, savesPasswords: true);

    testWidgets('start off, with saving and suggesting waiting for them, and say what is kept', (tester) async {
      await _openSheet(tester, status: saves);

      expect(_switchedOn(tester, t('autofill.passwords')), isFalse);
      expect(tester.widget<Switch>(_switchOf(t('autofill.passwordSaving'))).onChanged, isNull);
      expect(tester.widget<Switch>(_switchOf(t('autofill.passwordSuggesting'))).onChanged, isNull);
      expect(find.text(t('autofill.passwords.kept', {'label': t('enableBiometric.platform.android.label')})), findsOneWidget);
      expect(find.text(t('autofill.passwords.fillOnly')), findsNothing);
    });

    testWidgets('turning them on makes the inbox key, asks the phone to fill from Kemlock, and lets it save', (tester) async {
      final app = await _openSheet(tester, status: saves);

      await tester.tap(_switchOf(t('autofill.passwords')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(_prefs(app).passwords, isTrue);
      expect(app.autofill.calls, contains('turnOn'));
      expect(app.autofill.inboxKeys[mainVault], isNotNull);
      expect(app.autofill.takes[mainVault], const VaultTakes(logins: true, suggest: true));
      expect(tester.widget<Switch>(_switchOf(t('autofill.passwordSaving'))).onChanged, isNotNull);
    });

    testWidgets('turning suggesting off tells the phone', (tester) async {
      final app = await _openSheet(tester, status: saves);
      await tester.tap(_switchOf(t('autofill.passwords')));
      await tester.pumpAndSettle();

      await tester.tap(_switchOf(t('autofill.passwordSuggesting')));
      await tester.pumpAndSettle();

      expect(_prefs(app).passwordSuggesting, isFalse);
      expect(app.autofill.takes[mainVault]?.suggest, isFalse);
    });

    testWidgets('a phone that can’t save passwords says it only fills them', (tester) async {
      await _openSheet(tester);

      expect(find.text(t('autofill.passwords.fillOnly')), findsOneWidget);
      await tester.tap(_switchOf(t('autofill.passwords')));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(_switchOf(t('autofill.passwordSaving'))).onChanged, isNull);
    });
  });
}
