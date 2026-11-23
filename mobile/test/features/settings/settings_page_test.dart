import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/core/project_links.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/breaches/breach_list.dart';
import 'package:kemlock/features/breaches/breach_providers.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/lock/lock_screen.dart';
import 'package:kemlock/features/lock/unlock_attempts.dart';
import 'package:kemlock/features/lock/unlock_method_sheet.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/security_keys/security_key_sheet.dart';
import 'package:kemlock/features/settings/about_page.dart';
import 'package:kemlock/features/settings/app_version.dart';
import 'package:kemlock/features/settings/offline_alert.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/settings/settings_page.dart';
import 'package:kemlock/features/settings/terms_page.dart';
import 'package:kemlock/features/settings/vaults_sheet.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_owner_check.dart';
import '../../fakes/fake_reminders.dart';
import '../../fakes/fake_security_keys.dart';
import '../../helpers/app_harness.dart';
import '../../helpers/old_biometric_entry.dart';
import '../../helpers/test_app.dart';
import '../../vault/rotation_helpers.dart' show newKit;
import '../backup/backup_test_kit.dart' show FakeLinks;
import '../breaches/breach_list_test.dart' show hibpFixture;
import '../keys/expiry_kit.dart';
import '../pgp/pgp_kit.dart' show fixtureBytes, fixtureKeys;

/// The whole app on a screen tall enough for every row of Settings, open
/// on Settings. [before] gets the vault ready before the app starts. The
/// phone has biometrics the hardware key can use unless [biometrics] is
/// false; the offer to turn them on after unlocking is declined.
Future<TestApp> _openSettings(
  WidgetTester tester, {
  bool biometrics = true,
  Future<void> Function(TestApp app, VaultSession session)? before,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = TestApp(biometrics: FakeBiometrics(available: biometrics));
  await tester.runAsync(() async {
    final session = await app.createVault('pw');
    await before?.call(app, session);
  });
  await app.pump(tester, overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0'), ...overrides]);
  await app.controller.open(await app.vaultStore.unlockAnyVault('pw', app.vaults.startingVault()));
  app.controller.biometricOffered();
  await tester.pumpAndSettle();
  app.container.read(routerProvider).go('/settings');
  await tester.pumpAndSettle();
  return app;
}

/// The row of Settings named [primary].
Finder _row(String primary) => find.widgetWithText(GroupRow, primary);

Finder _switchOf(String primary) => find.descendant(of: _row(primary), matching: find.byType(Switch));

void _setPrefs(TestApp app, Map<String, Object?> prefs) => app.store.setItem(prefsKey, jsonEncode(prefs));

String _date(int ms) => DateFormat.yMMMd('en').format(DateTime.fromMillisecondsSinceEpoch(ms));

void main() {
  testWidgets('shows every group and row the phone app showed', (tester) async {
    await _openSettings(tester);

    expect(find.widgetWithText(PageTitle, t('app.settings.title')), findsOneWidget);
    for (final label in [
      'app.settings.section.security',
      'settings.section.sync',
      'app.settings.section.data',
      'settings.section.appearance',
      'app.settings.section.about',
    ]) {
      expect(find.text(t(label).toUpperCase()), findsOneWidget, reason: label);
    }
    for (final row in [
      'app.menu.changePassword',
      'recovery.kit.title',
      'settings.health.biometric',
      'settings.autoLock',
      'settings.lockOnHide',
      'settings.askBeforeSecret',
      'settings.clipboard',
      'vaults.title',
      'sync.title',
      'spaces.title',
      'app.menu.export',
      'app.menu.import',
      'app.menu.qrExport',
      'app.menu.qrImport',
      'settings.theme',
      'app.settings.language',
      'settings.about',
      'app.terms.title',
    ]) {
      expect(_row(t(row)), findsOneWidget, reason: row);
    }
    // The web build's passkeys aren't on phones
    expect(find.text(t('app.menu.managePasskeys')), findsNothing);
    expect(find.text(t('app.menu.lockVault')), findsOneWidget);
    expect(find.text(t('settings.version', {'version': '1.1.0'})), findsOneWidget);
    expect(find.text(t('settings.clipboard.detail', {'delay': '30 seconds'})), findsOneWidget);
    expect(find.descendant(of: _row(t('settings.clipboard')), matching: find.text(t('settings.clipboard.after30'))), findsOneWidget);
  });

  // openspec: replace-vault-key-pair, task 6.2
  testWidgets('offers to replace the vault key, saying when to, and opens its sheet', (tester) async {
    await _openSettings(tester);

    expect(find.descendant(of: _row(t('settings.replaceKey')), matching: find.text(t('settings.replaceKey.hint'))), findsOneWidget);
    await tester.ensureVisible(_row(t('settings.replaceKey')));
    await tester.tap(_row(t('settings.replaceKey')));
    await tester.pumpAndSettle();

    expect(find.text(t('replaceKey.body')), findsOneWidget);
  });

  // openspec: replace-vault-key-pair, task 5.4
  group('a vault known to be exposed', () {
    /// Settings as on Android, which flutter_test runs as by default.
    Future<TestApp> open(WidgetTester tester, {required bool asked}) => _openSettings(
      tester,
      before: (app, session) => app.vaultStore.saveEncryptedValue(keyKeyInfo, {'exposed': true, 'asked': asked}, session),
    );

    testWidgets('and asked shows the vault key line, not in order, whose Replace opens the sheet', (tester) async {
      await open(tester, asked: true);

      expect(find.text(t('replaceKey.exposed')), findsNothing);
      expect(find.text(t('settings.health.key')), findsOneWidget);
      expect(find.text(t('settings.health.keyExposed')), findsOneWidget);
      expect(find.text('3/7'), findsOneWidget);
      await tester.tap(find.text(t('settings.health.replaceKey')));
      await tester.pumpAndSettle();
      expect(find.text(t('replaceKey.exposed')), findsOneWidget);
    });

    testWidgets('and never asked is offered the replacement once it opens, and keeps the line after Not now', (tester) async {
      final app = await open(tester, asked: false);

      expect(find.text(t('replaceKey.exposed')), findsOneWidget);
      await tester.tap(find.text(t('replaceKey.notNow')));
      await tester.pumpAndSettle();

      expect(find.text(t('replaceKey.exposed')), findsNothing);
      expect(find.text(t('settings.health.keyExposed')), findsOneWidget);
      final session = app.container.read(vaultControllerProvider).session!;
      expect((await tester.runAsync(() => app.vaultStore.loadKeyInfo(session)))!.asked, isTrue);
    });
  });

  testWidgets('shows no vault key line for a vault not known to be exposed', (tester) async {
    await _openSettings(tester);

    expect(find.text(t('settings.health.key')), findsNothing);
    expect(find.text(t('replaceKey.exposed')), findsNothing);
  });

  testWidgets('rates a new vault as needing attention', (tester) async {
    await _openSettings(tester);

    expect(find.text('3/6'), findsOneWidget);
    expect(find.text(t('settings.health.attention')), findsOneWidget);
    expect(find.text(t('settings.health.kitNone')), findsOneWidget);
    expect(find.text(t('settings.health.quickOff')), findsOneWidget);
    expect(find.text(t('settings.health.backupNever')), findsOneWidget);
    expect(find.text(t('settings.autoLock.detail', {'minutes': 5})), findsOneWidget);
    expect(find.text(t('settings.health.setUp')), findsNWidgets(2));
    expect(find.text(t('settings.health.backUp')), findsOneWidget);
    expect(find.descendant(of: _row(t('recovery.kit.title')), matching: find.text(t('settings.value.off'))), findsOneWidget);
  });

  testWidgets('rates a vault with a kit, biometric unlock and a fresh backup as excellent', (tester) async {
    await _openSettings(
      tester,
      before: (app, session) async {
        await app.vaultStore.setRecoveryKey(
          session,
          RecoveryKey(kitId: 'kit', key: Uint8List(32), threshold: 2, shares: 3, createdAt: '2026-10-01T00:00:00.000Z'),
        );
        await app.vaultStore.enableBiometricUnlock(session, 'Turn it on');
        _setPrefs(app, {'lastBackupAt': testNow.millisecondsSinceEpoch});
      },
    );

    expect(find.text('6/6'), findsOneWidget);
    expect(find.text(t('settings.health.excellent')), findsOneWidget);
    expect(find.text(t('settings.health.kitPeople', {'needed': 2, 'total': 3})), findsOneWidget);
    expect(find.text(t('settings.health.biometricOn')), findsOneWidget);
    expect(find.text(t('settings.health.backupOn', {'date': _date(testNow.millisecondsSinceEpoch)})), findsOneWidget);
    expect(find.text(t('settings.health.setUp')), findsNothing);
    expect(find.descendant(of: _row(t('recovery.kit.title')), matching: find.text(t('settings.value.on'))), findsOneWidget);
    expect(tester.widget<Switch>(_switchOf(t('settings.health.biometric'))).value, isTrue);
  });

  testWidgets('names a kit kept by one person', (tester) async {
    await _openSettings(
      tester,
      before: (app, session) => app.vaultStore.setRecoveryKey(
        session,
        RecoveryKey(kitId: 'kit', key: Uint8List(32), threshold: 1, shares: 1, createdAt: '2026-10-01T00:00:00.000Z'),
      ),
    );

    expect(find.text(t('settings.health.kitMe')), findsOneWidget);
  });

  testWidgets('counts the entries added since the last backup', (tester) async {
    final lastBackup = testNow.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final app = await _openSettings(tester, before: (app, _) async => _setPrefs(app, {'lastBackupAt': lastBackup}));
    expect(find.text(t('settings.health.backupOn', {'date': _date(lastBackup)})), findsOneWidget);

    await app.controller.addAccount(const OtpAccount(id: '', issuer: 'GitHub', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0));
    await tester.pumpAndSettle();

    expect(find.text(t('settings.health.backupStale', {'date': _date(lastBackup), 'count': 1})), findsOneWidget);
    expect(find.text(t('settings.health.backUp')), findsOneWidget);
  });

  testWidgets('turns locking when hidden on and off', (tester) async {
    final app = await _openSettings(tester);

    await tester.tap(_switchOf(t('settings.lockOnHide')));
    await tester.pumpAndSettle();
    expect(app.container.read(prefsProvider).lockOnHide, isTrue);
    expect(find.text(t('settings.autoLock.detailHidden', {'minutes': 5})), findsOneWidget);
  });

  testWidgets('asks before showing a secret once turned on, and asks who it is before it stops', (tester) async {
    final check = FakeOwnerCheck(passes: false);
    final app = await _openSettings(tester, overrides: [check.asOverride]);
    bool asking() => app.container.read(prefsProvider).askBeforeSecret;
    final toggle = _switchOf(t('settings.askBeforeSecret'));
    expect(asking(), isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(asking(), isTrue);
    expect(check.reasons, isEmpty);

    // Whoever could turn it off without asking would get round it
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(check.reasons, [t('settings.askBeforeSecret.off')]);
    expect(asking(), isTrue);

    check.passes = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(asking(), isFalse);
  });

  group('erasing after wrong passwords', () {
    Finder value(String text) => find.descendant(of: _row(t('settings.unlockErase')), matching: find.text(text));

    Future<void> pick(WidgetTester tester, String current, String option) async {
      await tester.tap(value(current));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(PopupMenuItem<int>), matching: find.text(option)));
      await tester.pumpAndSettle();
    }

    testWidgets('is off, and says what it doesn’t stop', (tester) async {
      final app = await _openSettings(tester);

      expect(value(t('settings.value.off')), findsOneWidget);
      expect(find.text(t('settings.unlockErase.detail')), findsOneWidget);
      expect(app.store.getItem('backmycodes_unlock_erase'), isNull);
    });

    testWidgets('turns on only once confirmed, saying every vault on the phone goes and how this vault is backed up', (tester) async {
      final app = await _openSettings(tester);

      await pick(tester, t('settings.value.off'), t('settings.unlockErase.option', {'count': 10}));

      expect(find.text(t('settings.unlockErase.confirm.title', {'count': 10})), findsOneWidget);
      expect(find.text(t('settings.unlockErase.confirm.body', {'count': 10})), findsOneWidget);
      expect(
        t('settings.unlockErase.confirm.body', {'count': 10}),
        allOf(
          contains('Every vault on this phone will be erased after 10 wrong passwords in a row'),
          contains('Exports and sync are the way back'),
        ),
      );
      expect(find.textContaining(t('settings.health.backupNever'), findRichText: true), findsWidgets);
      expect(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(t('settings.unlockErase.detail'))), findsOneWidget);
      expect(app.store.getItem('backmycodes_unlock_erase'), isNull);

      await tester.tap(find.text(t('settings.unlockErase.confirm.ok')));
      await tester.pumpAndSettle();

      expect(app.store.getItem('backmycodes_unlock_erase'), '{"after":10}');
      expect(value(t('settings.unlockErase.value', {'count': 10})), findsOneWidget);

      // Off needs no confirmation
      await pick(tester, t('settings.unlockErase.value', {'count': 10}), t('settings.value.off'));
      expect(find.byType(ConfirmDialog), findsNothing);
      expect(app.store.getItem('backmycodes_unlock_erase'), isNull);
    });

    testWidgets('forgets the wrong passwords already counted when it turns on, so none of them erases', (tester) async {
      final app = await _openSettings(tester);
      // Typed while the erase was off, on this vault and on the phone's own slot
      app.store.setItem('backmycodes_unlock_failures', jsonEncode({'count': 12, 'last': 1}));
      app.store.setItem('backmycodes_unlock_failures_device', jsonEncode({'count': 40, 'last': 1}));

      await pick(tester, t('settings.value.off'), t('settings.unlockErase.option', {'count': 10}));
      await tester.tap(find.text(t('settings.unlockErase.confirm.ok')));
      await tester.pumpAndSettle();

      expect(app.store.getItem('backmycodes_unlock_erase'), '{"after":10}');
      expect(app.container.read(unlockAttemptsProvider).highestCount(), 0);
    });

    testWidgets('stays off when the confirmation is cancelled', (tester) async {
      final app = await _openSettings(tester);

      await pick(tester, t('settings.value.off'), t('settings.unlockErase.option', {'count': 15}));
      await tester.tap(find.text(t('settings.unlockErase.confirm.cancel')));
      await tester.pumpAndSettle();

      expect(app.store.getItem('backmycodes_unlock_erase'), isNull);
      expect(value(t('settings.value.off')), findsOneWidget);
    });

    testWidgets('shows the same setting in another vault, which is the phone’s', (tester) async {
      final app = await _openSettings(tester);
      await pick(tester, t('settings.value.off'), t('settings.unlockErase.option', {'count': 20}));
      await tester.tap(find.text(t('settings.unlockErase.confirm.ok')));
      await tester.pumpAndSettle();
      final work = (await tester.runAsync(() => app.vaultStore.createVault('Work', 'work-pw', listed: true)))!;

      app.controller.switchVault(work);
      await tester.pumpAndSettle();
      await app.controller.open((await tester.runAsync(() => app.vaultStore.unlockAnyVault('work-pw', work)))!);
      app.controller.biometricOffered();
      await tester.pumpAndSettle();
      app.container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();

      expect(app.state.vault.id, work);
      expect(value(t('settings.unlockErase.value', {'count': 20})), findsOneWidget);
    });

    testWidgets('names no number of vaults in a phone that also has a hidden one', (tester) async {
      await _openSettings(
        tester,
        before: (app, _) async {
          await app.vaultStore.createVault('Diary', 'diary-pw', listed: false);
          await app.vaultStore.createVault('Work', 'work-pw', listed: true);
        },
      );

      await pick(tester, t('settings.value.off'), t('settings.unlockErase.option', {'count': 10}));

      final texts = [
        for (final text in tester.widgetList<Text>(find.descendant(of: find.byType(ConfirmDialog), matching: find.byType(Text))))
          text.data ?? text.textSpan!.toPlainText(),
      ].join('\n');
      expect(texts, contains('Every vault on this phone'));
      expect(texts, isNot(matches(RegExp(r'\b\d+ vaults?\b'))));
      expect(texts, isNot(matches(RegExp(r'\b(two|three|both)\b', caseSensitive: false))));
    });
  });

  group('the clipboard delay', () {
    Finder value(String id) => find.descendant(of: _row(t('settings.clipboard')), matching: find.text(t(id)));

    Future<void> choose(WidgetTester tester, String current, String option) async {
      await tester.tap(value(current));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(PopupMenuItem<int>), matching: find.text(t(option))));
      await tester.pumpAndSettle();
    }

    testWidgets('offers each delay and never in a menu, the chosen one ticked', (tester) async {
      await _openSettings(tester);

      expect(_switchOf(t('settings.clipboard')), findsNothing);
      await tester.tap(value('settings.clipboard.after30'));
      await tester.pumpAndSettle();

      final options = ['after10', 'after30', 'after60', 'after120', 'never'];
      for (final option in options) {
        expect(find.descendant(of: find.byType(PopupMenuItem<int>), matching: find.text(t('settings.clipboard.$option'))), findsOneWidget);
      }
      expect(
        tester.getSemantics(find.ancestor(of: find.text(t('settings.clipboard.after30')).last, matching: find.byType(Semantics)).first),
        isSemantics(isInMutuallyExclusiveGroup: true, isChecked: true),
      );
    });

    testWidgets('picks each delay, and never', (tester) async {
      final app = await _openSettings(tester);
      Prefs prefs() => app.container.read(prefsProvider);

      var current = 'settings.clipboard.after30';
      for (final (option, seconds, words) in [
        ('settings.clipboard.after10', 10, '10 seconds'),
        ('settings.clipboard.after60', 60, '1 minute'),
        ('settings.clipboard.after120', 120, '2 minutes'),
        ('settings.clipboard.after30', 30, '30 seconds'),
      ]) {
        await choose(tester, current, option);
        current = option;
        expect(prefs().clipboardDelay, Duration(seconds: seconds), reason: option);
        expect(value(option), findsOneWidget, reason: option);
        expect(find.text(t('settings.clipboard.detail', {'delay': words})), findsOneWidget, reason: option);
      }

      await choose(tester, current, 'settings.clipboard.never');
      expect((prefs().clearClipboard, prefs().clipboardDelay), (false, null));
      expect(value('settings.clipboard.never'), findsOneWidget);
      expect(find.text(t('settings.clipboard.detailNever')), findsOneWidget);

      // From never, a delay turns clearing on again
      await choose(tester, 'settings.clipboard.never', 'settings.clipboard.after60');
      expect((prefs().clearClipboard, prefs().clipboardDelay), (true, const Duration(minutes: 1)));
    });

    testWidgets('says on an iPhone that copies stay on the phone', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await _openSettings(tester);

        expect(find.text(t('settings.clipboard.detailIos', {'delay': '30 seconds'})), findsOneWidget);
        await choose(tester, 'settings.clipboard.after30', 'settings.clipboard.never');
        expect(find.text(t('settings.clipboard.detailNeverIos')), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('picks the auto-lock time from a menu', (tester) async {
    final app = await _openSettings(tester);

    await tester.tap(find.text(t('settings.autoLock.value', {'minutes': 5})));
    await tester.pumpAndSettle();
    for (final minutes in [1, 5, 15, 60]) {
      expect(find.text(t('settings.autoLock.option', {'minutes': minutes})), findsOneWidget);
    }
    await tester.tap(find.text(t('settings.autoLock.option', {'minutes': 15})));
    await tester.pumpAndSettle();

    expect(app.container.read(prefsProvider).autoLockMinutes, 15);
    expect(find.text(t('settings.autoLock.value', {'minutes': 15})), findsOneWidget);
    expect(find.text(t('settings.autoLock.detail', {'minutes': 15})), findsOneWidget);
  });

  testWidgets('turns biometric unlock off with its switch, deleting the hardware key', (tester) async {
    final app = await _openSettings(tester, before: (app, session) => app.vaultStore.enableBiometricUnlock(session, 'Turn it on'));

    await tester.tap(_switchOf(t('settings.health.biometric')));
    await tester.pumpAndSettle();

    expect(app.vaultStore.hasBiometricUnlock(), isFalse);
    expect(app.unlockKeys.keys, isEmpty);
    expect(app.unlockKeys.calls.last, 'delete main');
    expect(tester.widget<Switch>(_switchOf(t('settings.health.biometric'))).value, isFalse);
    expect(find.text(t('settings.health.quickOff')), findsOneWidget);
  });

  testWidgets('turns biometric unlock on with its switch, through the sheet and one prompt', (tester) async {
    final app = await _openSettings(tester);

    await tester.tap(_switchOf(t('settings.health.biometric')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('enableBiometric.enable', {'label': t('enableBiometric.platform.android.label')})));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('enableBiometric.done')));
    await tester.pumpAndSettle();

    expect(app.unlockKeys.calls, ['seal main']);
    expect(app.vaultStore.hasBiometricUnlock(), isTrue);
    expect(tester.widget<Switch>(_switchOf(t('settings.health.biometric'))).value, isTrue);
  });

  testWidgets('offers no biometric unlock on a phone whose biometrics the key can’t use', (tester) async {
    await _openSettings(tester, biometrics: false);

    expect(_row(t('settings.health.biometric')), findsNothing);
    expect(find.text(t('settings.health.quickOff')), findsNothing);
    // The health card counts what this phone can have
    expect(find.text('3/5'), findsOneWidget);
  });

  testWidgets('still lets biometric unlock be turned off where the key can’t be used any more', (tester) async {
    final app = await _openSettings(tester, biometrics: false);
    // An entry an earlier version wrote, which the next lock screen would delete
    await tester.runAsync(() => writeOldBiometricEntry(app.store, app.vaults, app.state.session!));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(_switchOf(t('settings.health.biometric'))).value, isTrue);

    await tester.tap(_switchOf(t('settings.health.biometric')));
    await tester.pumpAndSettle();

    expect(app.vaultStore.hasBiometricUnlock(), isFalse);
    expect(_row(t('settings.health.biometric')), findsNothing);
  });

  testWidgets('follows biometric unlock being set up elsewhere', (tester) async {
    final app = await _openSettings(tester);

    await tester.runAsync(() => app.vaultStore.enableBiometricUnlock(app.state.session!, 'Turn it on'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(_switchOf(t('settings.health.biometric'))).value, isTrue);
    expect(find.text(t('settings.health.biometricOn')), findsOneWidget);
  });

  group('the breaches line of the vault health card', () {
    // Trello's breach was listed in January 2024 and Duolingo's in August 2023
    final breaches = breachListProvider.overrideWith((ref) async => BreachList.fromHibp(hibpFixture(), updated: '2026-11-15'));
    final added = DateTime.utc(2023, 1, 1).millisecondsSinceEpoch;
    OtpAccount account(String id, String issuer) =>
        OtpAccount(id: id, issuer: issuer, label: id, secret: 'JBSWY3DPEHPK3PXP', addedAt: added);

    testWidgets('is in order, with no button, when no service has a new breach', (tester) async {
      await _openSettings(
        tester,
        overrides: [breaches],
        before: (app, session) => app.vaultStore.saveAccounts([account('a', 'GitHub')], session),
      );

      expect(find.text(t('settings.health.breachesNone')), findsOneWidget);
      expect(find.text(t('settings.health.review')), findsNothing);
      expect(find.text('3/6'), findsOneWidget);
    });

    testWidgets('counts two services for three entries of one and an account of another', (tester) async {
      await _openSettings(
        tester,
        overrides: [breaches],
        before: (app, session) async {
          await app.vaultStore.saveAccounts([account('a1', 'Trello'), account('a2', 'trello.com'), account('a3', 'Duolingo')], session);
          await app.vaultStore.saveBackupServices([
            BackupService(id: 's1', serviceName: 'Trello', codes: const [], addedAt: added),
          ], session);
        },
      );

      expect(find.text(t('settings.health.breachesSome', {'count': 2})), findsOneWidget);
      expect(find.text(t('settings.health.breachesNone')), findsNothing);
      // One line fewer in order than with no breach
      expect(find.text('2/6'), findsOneWidget);
    });

    testWidgets('opens the Breaches sheet from Review', (tester) async {
      await _openSettings(
        tester,
        overrides: [breaches],
        before: (app, session) => app.vaultStore.saveAccounts([account('a1', 'Trello')], session),
      );

      await tester.tap(find.text(t('settings.health.review')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(DialogHeading, t('breaches.title')), findsOneWidget);
      expect(find.text(t('breaches.body')), findsOneWidget);
    });

    testWidgets('finds nothing new for a vault filled today', (tester) async {
      await _openSettings(
        tester,
        overrides: [breaches],
        before: (app, session) => app.vaultStore.saveAccounts([
          for (final issuer in ['Adobe', 'Trello', 'Twitter']) account(issuer, issuer).copyWith(addedAt: testNow.millisecondsSinceEpoch),
        ], session),
      );

      expect(find.text(t('settings.health.breachesNone')), findsOneWidget);
    });
  });

  testWidgets('turns the password leak check on and off for the open vault alone', (tester) async {
    late final String work;
    final app = await _openSettings(
      tester,
      before: (app, _) async {
        work = await app.vaultStore.createVault('Work', 'work-pw', listed: true);
        app.vaults.active = mainVault;
      },
    );
    expect(tester.widget<Switch>(_switchOf(t('settings.leakCheck'))).value, isFalse);
    expect(find.text(t('settings.leakCheck.detail')), findsOneWidget);

    await tester.tap(_switchOf(t('settings.leakCheck')));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(_switchOf(t('settings.leakCheck'))).value, isTrue);
    expect(jsonDecode(app.store.getItem(prefsKey)!), containsPair('leakCheck', true));
    // The other vault's settings are its own
    expect(app.store.getItem(app.vaults.vaultKey(prefsKey, work)) ?? '', isNot(contains('leakCheck')));

    await tester.tap(_switchOf(t('settings.leakCheck')));
    await tester.pumpAndSettle();
    expect(app.store.getItem(prefsKey), isNot(contains('leakCheck')));
  });

  testWidgets('leaves quick unlock out for a vault hidden from the lock screen', (tester) async {
    await _openSettings(tester, before: (app, _) async => app.vaults.setListed(mainVault, false));

    expect(_row(t('settings.health.biometric')), findsNothing);
    expect(find.text(t('settings.health.quickOff')), findsNothing);
    expect(find.text('3/5'), findsOneWidget);
  });

  // openspec: add-fdroid-release, design decisions 5 and 12
  testWidgets('offers support, and opens the support page', (tester) async {
    final links = FakeLinks();
    await _openSettings(tester, overrides: [links.asOverride]);

    final support = _row(t('settings.support.title'));
    expect(find.descendant(of: support, matching: find.text(t('settings.support.body'))), findsOneWidget);

    await tester.tap(support);
    await tester.pumpAndSettle();

    expect(links.opened, [supportPage]);
  });

  testWidgets('shows sync and spaces', (tester) async {
    await _openSettings(tester);

    expect(find.descendant(of: _row(t('sync.title')), matching: find.text(t('settings.value.off'))), findsOneWidget);
    expect(find.descendant(of: _row(t('spaces.title')), matching: find.text('0')), findsOneWidget);
  });

  testWidgets('changes the look and the language', (tester) async {
    final app = await _openSettings(tester);

    await tester.tap(find.text(t('settings.theme.dark')));
    await tester.pumpAndSettle();
    expect(app.container.read(themeChoiceProvider), ThemeChoice.dark);

    await tester.tap(find.text(AppLocale.fr.label));
    await tester.pumpAndSettle();
    expect(app.container.read(localeProvider), AppLocale.fr);
    expect(find.widgetWithText(PageTitle, testCatalog.of(AppLocale.fr).t('app.settings.title')), findsOneWidget);
  });

  testWidgets('names the open vault and opens the vaults sheet', (tester) async {
    await _openSettings(tester);

    expect(find.descendant(of: _row(t('vaults.title')), matching: find.text(t('vaults.defaultName'))), findsOneWidget);
    await tester.tap(_row(t('vaults.title')));
    await tester.pumpAndSettle();

    expect(find.byType(VaultsSheet), findsOneWidget);
  });

  testWidgets('puts the vaults sheet away when the vault locks', (tester) async {
    final app = await _openSettings(tester);
    await tester.tap(_row(t('vaults.title')));
    await tester.pumpAndSettle();

    app.controller.lock();
    await tester.pumpAndSettle();

    expect(find.byType(LockScreen), findsOneWidget);
    expect(find.byType(VaultsSheet), findsNothing);
  });

  testWidgets('goes to About and to the terms', (tester) async {
    await _openSettings(tester);

    await tester.tap(_row(t('settings.about')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(t('nav.back')));
    await tester.pumpAndSettle();
    await tester.tap(_row(t('app.terms.title')));
    await tester.pumpAndSettle();
    expect(find.byType(TermsPage), findsOneWidget);
  });

  testWidgets('locks the vault', (tester) async {
    await _openSettings(tester);

    // Below the support row, which every build shows now
    await tester.ensureVisible(find.text(t('app.menu.lockVault')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('app.menu.lockVault')));
    await tester.pumpAndSettle();

    expect(find.byType(LockScreen), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);
  });

  group('warning before a key expires', () {
    // A week before the `future` fixture key expires
    final weekBefore = futureExpiry.subtract(const Duration(days: 7));
    final toggle = _switchOf(t('settings.keyReminders'));

    /// Settings a week before the key in the vault expires.
    Future<TestApp> open(WidgetTester tester, {bool granted = true, bool hidden = false}) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = TestApp(
        now: () => weekBefore,
        reminders: FakeReminders(granted: granted),
      );
      final key = await tester.runAsync(() async {
        final session = await app.createVault('pw');
        final key = await expiryFixtureKey('future');
        await app.vaultStore.saveKeys([key], session);
        return key;
      });
      if (hidden) app.vaults.setListed(mainVault, false);
      await app.pump(tester, overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0')]);
      await app.controller.open(await app.vaultStore.unlockAnyVault('pw', mainVault));
      await tester.pumpAndSettle();
      app.container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();
      expect(app.state.keys.single.id, key!.id);
      return app;
    }

    testWidgets('is a switch in a Keys group, off until turned on, saying when it warns', (tester) async {
      final app = await open(tester);

      expect(find.text(t('settings.section.keys').toUpperCase()), findsOneWidget);
      expect(find.descendant(of: _row(t('settings.keyReminders')), matching: find.text(t('settings.keyReminders.detail'))), findsOneWidget);
      expect(t('settings.keyReminders'), 'Warn before a key expires');
      expect(t('settings.keyReminders.detail'), '30, 7 and 1 days before');
      expect(tester.widget<Switch>(toggle).value, isFalse);
      // Nothing was asked of the phone, and nothing scheduled, before it is turned on
      expect(app.reminders.permissionRequests, 0);
      expect(app.reminders.scheduled, isEmpty);
    });

    testWidgets('turns on once the phone allows notifications, and schedules the reminders', (tester) async {
      final app = await open(tester);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(app.reminders.permissionRequests, 1);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(jsonDecode(app.store.getItem(prefsKey)!), containsPair('keyReminders', true));
      // The morning a week before has passed by now: the day before and the day itself are ahead
      expect([for (final reminder in app.reminders.inOrder) reminder.body], ['1 key expires tomorrow', '1 key expires today']);
    });

    testWidgets('stays off when the phone refuses, and says where to allow it', (tester) async {
      final app = await open(tester, granted: false);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(app.reminders.permissionRequests, 1);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.text(t('settings.keyReminders.denied')), findsOneWidget);
      expect(t('settings.keyReminders.denied'), contains('turned off for Kemlock in the phone’s settings'));
      expect(app.store.getItem(prefsKey) ?? '', isNot(contains('"keyReminders"')));
      expect(app.reminders.scheduled, isEmpty);
    });

    testWidgets('turning it off cancels every reminder of the vault', (tester) async {
      final app = await open(tester);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(app.reminders.scheduled, hasLength(2));

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(app.reminders.scheduled, isEmpty);
      expect(app.store.getItem(prefsKey), isNot(contains('"keyReminders"')));
      expect(app.store.getItem(keyKeyReminders), isNull);
    });

    testWidgets('is not offered for a vault hidden from the lock screen', (tester) async {
      final app = await open(tester, hidden: true);

      expect(_row(t('settings.keyReminders')), findsNothing);
      // The group stays for the Security keys row, which a hidden vault has too
      expect(find.text(t('settings.section.keys').toUpperCase()), findsOneWidget);
      expect(app.reminders.calls, isEmpty);
    });
  });

  // openspec: add-offline-mode, "Settings shows the switch and what it pauses"
  group('the Network group', () {
    /// The rows of the group's card: the switch's, then one per paused thing.
    Finder networkRows() => find.descendant(
      of: find.ancestor(of: _row(t('settings.offline')), matching: find.byType(GroupCard)),
      matching: find.byType(GroupRow),
    );

    List<String> pausedRows(WidgetTester tester) => [for (final row in tester.widgetList<GroupRow>(networkRows()).skip(1)) row.primary];

    testWidgets('is first on the page and shows the switch and its line alone while off', (tester) async {
      await _openSettings(tester);

      expect(find.text(t('settings.section.network').toUpperCase()), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(t('settings.section.network').toUpperCase())).dy,
        lessThan(tester.getTopLeft(find.text(t('app.settings.section.security').toUpperCase())).dy),
      );
      expect(find.descendant(of: _row(t('settings.offline')), matching: find.text(t('settings.offline.detail'))), findsOneWidget);
      expect(tester.widget<Switch>(_switchOf(t('settings.offline'))).value, isFalse);
      expect(networkRows(), findsOneWidget);
      expect(find.text(t('settings.offline.paused').toUpperCase()), findsNothing);
    });

    testWidgets('lists sync, breach checks and finding keys by email, each tagged, while on', (tester) async {
      final app = await _openSettings(tester);

      await tester.tap(_switchOf(t('settings.offline')));
      await tester.pumpAndSettle();

      expect(app.store.getItem(keyOffline), '{"on":true}');
      expect(tester.widget<Switch>(_switchOf(t('settings.offline'))).value, isTrue);
      // The tests run as Android, which has the passkey row too
      expect(pausedRows(tester), [
        t('settings.offline.sync'),
        t('settings.offline.breaches'),
        t('settings.offline.keyLookup'),
        t('settings.offline.passkeyApps'),
      ]);
      for (final row in tester.widgetList<GroupRow>(networkRows()).skip(1)) {
        expect(
          find.descendant(of: find.byWidget(row), matching: find.widgetWithText(StatusTag, t('settings.offline.paused').toUpperCase())),
          findsOneWidget,
          reason: row.primary,
        );
      }

      await tester.tap(_switchOf(t('settings.offline')));
      await tester.pumpAndSettle();

      expect(app.store.getItem(keyOffline), isNull);
      expect(networkRows(), findsOneWidget);
    });

    testWidgets('is on from the start when the phone was left offline', (tester) async {
      await _openSettings(tester, before: (app, _) async => app.store.setItem(keyOffline, '{"on":true}'));

      expect(tester.widget<Switch>(_switchOf(t('settings.offline'))).value, isTrue);
      expect(pausedRows(tester), hasLength(4));
    });

    for (final (platform, shown) in [(TargetPlatform.android, true), (TargetPlatform.iOS, false)]) {
      testWidgets('${shown ? 'lists' : 'does not list'} passkey sign-in to apps on ${platform.name}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await _openSettings(tester, before: (app, _) async => app.store.setItem(keyOffline, '{"on":true}'));

          expect(pausedRows(tester).contains(t('settings.offline.passkeyApps')), shown);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('tags the Sync row paused, and "Network settings" in its sheet comes back to Settings', (tester) async {
      await _openSettings(tester, before: (app, _) async => app.store.setItem(keyOffline, '{"on":true}'));
      final syncRow = find.widgetWithText(GroupRow, t('settings.sync.hint'));

      expect(find.descendant(of: syncRow, matching: find.byType(StatusTag)), findsOneWidget);
      expect(find.descendant(of: syncRow, matching: find.text(t('settings.value.off'))), findsNothing);

      await tester.tap(syncRow);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OfflineAlert, t('sync.offline.setup')), findsOneWidget);
      await tester.tap(find.text(t('offline.settings')));
      await tester.pumpAndSettle();

      expect(find.byType(SyncSheet), findsNothing);
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('names the switch and each tag for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await _openSettings(tester, before: (app, _) async => app.store.setItem(keyOffline, '{"on":true}'));

      final toggle = tester.getSemantics(_switchOf(t('settings.offline')));
      expect(toggle, isSemantics(hasToggledState: true, isToggled: true));
      expect(toggle.label, contains(t('settings.offline')));
      for (final row in pausedRows(tester)) {
        final label = RegExp('^${RegExp.escape(row)}\\s+${RegExp.escape(t('settings.offline.paused'))}\$');
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: row);
      }
      handle.dispose();
    });
  });

  testWidgets('has a Security keys row that opens the Security key sheet', (tester) async {
    final phone = FakeSecurityKeys();
    await _openSettings(tester, overrides: [phone.asOverride]);

    expect(find.text(t('settings.section.keys').toUpperCase()), findsOneWidget);
    final row = _row(t('securityKeys.settings.row'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(t('securityKeys.settings.detail'))), findsOneWidget);
    expect(phone.isWatching, isFalse, reason: 'no key is looked for before the sheet is open');

    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.byType(SecurityKeySheet), findsOneWidget);
    expect(find.text(t('securityKeys.wait.android')), findsOneWidget);
    expect(phone.isWatching, isTrue);
  });
  // openspec: add-pgp-mail-provider, task 8.1
  group('mail apps that use your PGP keys', () {
    final november2 = DateTime.utc(2026, 11, 2, 12).millisecondsSinceEpoch;
    final november9 = DateTime.utc(2026, 11, 9, 12).millisecondsSinceEpoch;

    /// Puts the fixture keys [keys] (short names of `fixtureKeys`) and [apps] in the vault of [session].
    Future<void> fill(TestApp app, VaultSession session, {List<String> keys = const ['ed'], List<MailApp> apps = const []}) async {
      await app.vaultStore.saveKeys([
        for (final name in keys)
          vaultKeyOf(
            await crypto.readPrivateKey(fixtureBytes(fixtureKeys[name]!.$1)),
            id: 'pgp-$name',
            name: fixtureKeys[name]!.$2,
            origin: KeyOrigin.imported,
          ),
      ], session);
      await MailAppsStore(app.vaultStore).save(apps, session);
    }

    MailApp mailApp(String package, String name, int allowedAt, List<String> keys) =>
        MailApp(package: package, cert: 'aa', name: name, allowedAt: allowedAt, keys: keys);

    Future<TestApp> open(WidgetTester tester, {List<String> keys = const ['ed'], List<MailApp> apps = const [], AppLocale? locale}) {
      return _openSettings(
        tester,
        before: (app, session) async {
          if (locale != null) app.store.setItem(keyLocale, locale.name);
          await fill(app, session, keys: keys, apps: apps);
        },
      );
    }

    testWidgets('two approved apps have a row each, with the key and the day in the app\'s language', (tester) async {
      final apps = [
        mailApp('net.thunderbird.android', 'Thunderbird', november2, ['pgp-ed']),
        mailApp('eu.faircode.email', 'FairEmail', november9, ['pgp-ed']),
      ];
      await open(tester, apps: apps);
      expect(find.text(t('settings.section.mailApps').toUpperCase()), findsOneWidget);
      expect(find.widgetWithText(GroupRow, 'Thunderbird'), findsOneWidget);
      expect(find.text('Uses Fixture Ed25519 · allowed 2 November'), findsOneWidget);
      expect(find.text('Uses Fixture Ed25519 · allowed 9 November'), findsOneWidget);
      expect(find.text('Th'), findsOneWidget);
      expect(find.text('Fe'), findsOneWidget);
      expect(find.text(t('settings.mailApps.note')), findsOneWidget);
    });

    testWidgets('writes the day in French', (tester) async {
      await open(
        tester,
        apps: [
          mailApp('net.thunderbird.android', 'Thunderbird', november2, ['pgp-ed']),
        ],
        locale: AppLocale.fr,
      );
      expect(find.text('Utilise Fixture Ed25519 · autorisée le 2 novembre'), findsOneWidget);
    });

    testWidgets('an app with two keys uses 2 keys, and one whose key was deleted uses none', (tester) async {
      await open(
        tester,
        keys: const ['ed', 'rsa'],
        apps: [
          mailApp('net.thunderbird.android', 'Thunderbird', november2, ['pgp-ed', 'pgp-rsa']),
          mailApp('eu.faircode.email', 'FairEmail', november9, ['pgp-gone']),
        ],
      );
      expect(find.text('Uses 2 keys · allowed 2 November'), findsOneWidget);
      expect(find.text('Uses no key · allowed 9 November'), findsOneWidget);
    });

    testWidgets('Remove deletes the approval, says so, and leaves the other row', (tester) async {
      final app = await open(
        tester,
        apps: [
          mailApp('net.thunderbird.android', 'Thunderbird', november2, ['pgp-ed']),
          mailApp('eu.faircode.email', 'FairEmail', november9, ['pgp-ed']),
        ],
      );
      await tester.ensureVisible(find.byKey(const ValueKey('mail-app-net.thunderbird.android')));
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('mail-app-net.thunderbird.android')), matching: find.byType(TextButton)),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text(t('settings.mailApps.removed', {'app': 'Thunderbird'})), findsOneWidget);
      expect(find.byKey(const ValueKey('mail-app-net.thunderbird.android')), findsNothing);
      expect(find.byKey(const ValueKey('mail-app-eu.faircode.email')), findsOneWidget);
      final left = (await tester.runAsync(() => app.container.read(mailAppsProvider.notifier).current()))!;
      expect(left.map((a) => a.package), ['eu.faircode.email']);
    });

    testWidgets('with no app, says how to add one', (tester) async {
      await open(tester);
      expect(find.text(t('settings.mailApps.none')), findsOneWidget);
      expect(find.text(t('settings.mailApps.none.hint')), findsOneWidget);
    });

    testWidgets('is absent on iOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await _openSettings(tester);
        expect(find.text(t('settings.section.mailApps').toUpperCase()), findsNothing);
        expect(find.text(t('settings.mailApps.note')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets("a hidden vault's Settings lists its own apps, not the listed vault's", (tester) async {
      final app = await _openSettings(
        tester,
        before: (app, session) async {
          await fill(
            app,
            session,
            apps: [
              mailApp('net.thunderbird.android', 'Thunderbird', november2, ['pgp-ed']),
            ],
          );
          final hidden = await app.vaultStore.createVault('Hidden', 'hidden pw', listed: false);
          final hiddenSession = await app.vaultStore.unlockAnyVault('hidden pw', null);
          expect(app.vaults.active, hidden);
          await fill(
            app,
            hiddenSession,
            apps: [
              mailApp('eu.faircode.email', 'FairEmail', november9, ['pgp-ed']),
            ],
          );
          app.vaults.active = mainVault;
        },
      );
      expect(find.text('Thunderbird'), findsOneWidget);
      await tester.runAsync(() async {
        app.controller.lock();
        await app.controller.open(await app.vaultStore.unlockAnyVault('hidden pw', mainVault));
      });
      await tester.pumpAndSettle();
      app.container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(app.state.vault.hidden, isTrue);
      expect(find.text('FairEmail'), findsOneWidget);
      expect(find.text('Thunderbird'), findsNothing);
    });
  });

  // openspec: add-security-key-unlock, task 6.6
  group('how the vault opens', () {
    /// The open vault gets a kit and one key, as what the key gave, and is
    /// set to open in [mode].
    Future<void> keyUp(WidgetTester tester, TestApp app, UnlockMode mode) async {
      await tester.runAsync(() async {
        final store = app.vaultStore;
        final session = app.controller.state.session!;
        await store.setRecoveryKey(session, newKit());
        final proof = await store.enrolKey(
          session,
          await store.proveOwner(password: 'pw'),
          salt: store.keyChallenge().salt,
          credential: randomBytes(64),
          output: randomBytes(32),
          name: 'Example Key',
          pinBound: true,
        );
        if (mode != UnlockMode.password) await store.setUnlockMode(session, proof, mode);
      });
      await tester.pumpAndSettle();
    }

    Finder opensRow() => _row(t('unlockMethod.title'));

    testWidgets('a row says how the vault opens, under Change master password, and opens the sheet', (tester) async {
      await _openSettings(tester);

      expect(find.descendant(of: opensRow(), matching: find.text(t('unlockMethod.mode.password'))), findsOneWidget);
      expect(_row(t('app.menu.changePassword')), findsOneWidget);
      await tester.ensureVisible(opensRow());
      await tester.tap(opensRow());
      await tester.pumpAndSettle();

      expect(find.byType(UnlockMethodSheet), findsOneWidget);
    });

    testWidgets('for a vault that opens with its key alone it takes the place of Change master password', (tester) async {
      final app = await _openSettings(tester);
      await keyUp(tester, app, UnlockMode.key);

      expect(_row(t('app.menu.changePassword')), findsNothing);
      expect(find.descendant(of: opensRow(), matching: find.text(t('unlockMethod.mode.key'))), findsOneWidget);
    });

    testWidgets('biometric unlock reads as off in the health card while the vault needs its key, with no switch', (tester) async {
      final app = await _openSettings(tester);
      expect(_switchOf(t('settings.health.biometric')), findsOneWidget);
      await keyUp(tester, app, UnlockMode.both);

      expect(find.text(t('unlockMethod.health.biometricOff')), findsOneWidget);
      expect(_switchOf(t('settings.health.biometric')), findsNothing);
      expect(find.descendant(of: opensRow(), matching: find.text(t('unlockMethod.mode.both'))), findsOneWidget);
    });

    testWidgets('the Security key sheet has "Open the vault with this key", which says how many keys open it', (tester) async {
      final phone = FakeSecurityKeys();
      final app = await _openSettings(tester, overrides: [phone.asOverride]);
      final row = _row(t('securityKeys.settings.row'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      phone.arrive(
        FakeKey(
          productName: 'Example Key',
          ctap: FakeFidoKey(pin: '123456'),
        ).device(kinds: {SecurityKeyLinkKind.nfc}),
      );
      await tester.pumpAndSettle();

      expect(find.text(t('unlockMethod.securityKey.section').toUpperCase()), findsOneWidget);
      expect(find.text(t('unlockMethod.securityKey.notSetUp')), findsOneWidget);
      await keyUp(tester, app, UnlockMode.password);
      expect(find.text(t('unlockMethod.securityKey.count', {'count': 1})), findsOneWidget);

      // Its reset warning says a key of the vault's stops opening it
      await tester.ensureVisible(find.text(t('securityKeys.reset.button')));
      await tester.tap(find.text(t('securityKeys.reset.button')));
      await tester.pumpAndSettle();
      expect(find.text(t('unlockMethod.securityKey.reset')), findsOneWidget);
      await tester.tap(find.text(t('export.cancel')));
      await tester.pumpAndSettle();

      await tester.tap(find.text(t('unlockMethod.securityKey.row')));
      await tester.pumpAndSettle();
      expect(find.byType(UnlockMethodSheet), findsOneWidget);
    });
  });
}
