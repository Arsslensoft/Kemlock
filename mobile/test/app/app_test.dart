import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/accounts/accounts_page.dart';
import 'package:kemlock/features/backup/backup_page.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/lock/setup_screen.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/settings/settings_page.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../flows/flow_kit.dart' show createVault, useTallPhone;
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';

void main() {
  group('the vault gate', () {
    testWidgets('starts at setup on a phone without a vault', (tester) async {
      await TestApp().pump(tester);

      expect(find.byType(SetupScreen), findsOneWidget);
      expect(find.byType(AppTabBar), findsNothing);
    });

    testWidgets('deletes the biometric unlock keys an earlier install left in an iPhone’s Keychain', (tester) async {
      // UserDefaults went with the uninstall; the Keychain kept the key
      final app = TestApp();
      app.unlockKeys.keys[mainVault] = Uint8List(32);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await app.pump(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      expect(find.byType(SetupScreen), findsOneWidget);
      expect(app.unlockKeys.calls, ['deleteAll']);
      expect(app.unlockKeys.keys, isEmpty);
    });

    testWidgets('leaves the keys alone at a start with a vault, or on Android, whose keys go with the app', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await app.pump(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(find.byType(LockScreen), findsOneWidget);

      final android = TestApp();
      await android.pump(tester);
      expect(find.byType(SetupScreen), findsOneWidget);

      expect([...app.unlockKeys.calls, ...android.unlockKeys.calls], isEmpty);
    });

    testWidgets('starts at the lock screen when a vault is on the phone', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));

      await app.pump(tester);

      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('opens on the Codes tab and locks back to the lock screen', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);

      await app.unlock(tester, 'pw');
      expect(find.byType(AccountsPage), findsOneWidget);
      expect(find.byType(AppTabBar), findsOneWidget);

      app.controller.lock();
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('covers the page it locked on, and the sheet over it, from the lock screen’s first frame', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');
      unawaited(
        showAppBottomSheet<void>(tester.element(find.byType(AccountsPage)), label: 'Secret', builder: (_) => const Text('A shown secret')),
      );
      await tester.pumpAndSettle();
      expect(find.text('A shown secret'), findsOneWidget);

      app.controller.lock();
      await tester.pump();

      expect(find.byType(LockScreen), findsOneWidget);
      // Neither is painted under the lock screen while it comes in
      expect(find.byType(AccountsPage), findsNothing);
      expect(find.text('A shown secret'), findsNothing);
    });

    testWidgets('comes back to the page the vault was locked on', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');
      await tester.tap(find.text(t('nav.backup')));
      await tester.pumpAndSettle();

      app.controller.lock();
      await tester.pumpAndSettle();
      await app.unlock(tester, 'pw');

      expect(find.byType(BackupPage), findsOneWidget);
    });

    testWidgets('goes to setup after the last vault is deleted', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');

      app.controller.deleteVault();
      await tester.pumpAndSettle();

      expect(find.byType(SetupScreen), findsOneWidget);
    });

    testWidgets('opens a vault made after a reset on the Codes tab, not where the old one was', (tester) async {
      useTallPhone(tester);
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');
      await tester.tap(find.text(t('nav.backup')));
      await tester.pumpAndSettle();
      app.controller.deleteVault();
      await tester.pumpAndSettle();

      await createVault(tester);

      expect(find.byType(AccountsPage), findsOneWidget);
    });
  });

  group('the tabs', () {
    testWidgets('switch between Codes, Backup and Settings', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');

      await tester.tap(find.text(t('nav.settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      final tab = find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t('nav.settings')));
      expect(tester.getSemantics(tab), isSemantics(isSelected: true));

      await tester.tap(find.text(t('nav.codes')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountsPage), findsOneWidget);
    });

    testWidgets('name the Add button after what it adds on each tab', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');

      // In the tab bar: an empty tab offers the same in its own button
      Finder inTabBar(String label) => find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(label));
      expect(inTabBar(t('nav.addAccount')), findsOneWidget);
      await tester.tap(find.text(t('nav.backup')));
      await tester.pumpAndSettle();
      expect(inTabBar(t('nav.addBackup')), findsOneWidget);
    });

    testWidgets('send the old /codes path to Backup', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');

      app.container.read(routerProvider).go('/codes');
      await tester.pumpAndSettle();

      expect(find.byType(BackupPage), findsOneWidget);
    });

    test('belong to the location', () {
      expect(AppTab.of('/accounts'), AppTab.codes);
      expect(AppTab.of('/backup'), AppTab.backup);
      expect(AppTab.of('/about'), AppTab.settings);
      expect(AppTab.of('/terms'), AppTab.settings);
    });
  });

  group('the look', () {
    testWidgets('follows the phone until one is chosen', (tester) async {
      final app = TestApp();
      await app.pump(tester);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);

      app.container.read(themeChoiceProvider.notifier).choose(ThemeChoice.light);
      await tester.pumpAndSettle();

      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
      expect(app.store.getItem(keyTheme), 'light');
    });

    testWidgets('survives a reset of every vault, as the language does', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      app.container.read(themeChoiceProvider.notifier).choose(ThemeChoice.dark);

      app.vaultStore.wipeVault();

      expect(app.store.getItem(keyTheme), 'dark');
    });
  });

  testWidgets('shows the toasts the vault controller asks for', (tester) async {
    final app = TestApp();
    await app.pump(tester);

    app.container.read(toastsProvider.notifier).show('Saved', severity: ToastSeverity.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Saved'), findsOneWidget);
  });

  group('auto-lock', () {
    testWidgets('locks after the minutes chosen without a touch', (tester) async {
      var now = testNow;
      final app = TestApp()..now = () => now;
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');
      expect(app.container.read(prefsProvider).autoLockMinutes, 5);

      now = now.add(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      expect(app.state.phase, VaultPhase.unlocked);

      now = now.add(const Duration(minutes: 1, seconds: 1));
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      await tester.pumpAndSettle();

      expect(app.state.phase, VaultPhase.locked);
      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('counts a touch as activity', (tester) async {
      var now = testNow;
      final app = TestApp()..now = () => now;
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');

      now = now.add(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      await tester.tapAt(const Offset(200, 300));
      now = now.add(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));

      expect(app.state.phase, VaultPhase.unlocked);
    });

    testWidgets('locks when the app is hidden, if Settings says so', (tester) async {
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester);
      await app.unlock(tester, 'pw');
      app.container.read(prefsProvider.notifier).update((p) => p.copyWith(lockOnHide: true));
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pumpAndSettle();

      expect(app.state.phase, VaultPhase.locked);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  });

  testWidgets('offers biometric unlock once, after an unlock', (tester) async {
    final app = TestApp(biometrics: FakeBiometrics());
    await tester.runAsync(() => app.createVault('pw'));
    await app.pump(tester);

    await app.unlock(tester, 'pw');

    expect(app.state.offerBiometric, isFalse);
    expect(app.vaults.active, mainVault);
  });
}
