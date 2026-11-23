import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/core/build_kind.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/settings/app_version.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../features/pgp/pgp_kit.dart' show fixtureBytes, fixtureKeys;
import '../helpers/app_harness.dart';
import '../helpers/old_biometric_entry.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders Settings, the vaults sheet, About and the terms, in dark and
/// light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/settings_test.dart
void main() {
  /// The whole app on a phone, unlocked on [location], in [brightness].
  /// [before] gets the vault ready before the app starts.
  Future<TestApp> open(
    WidgetTester tester,
    Brightness brightness,
    String location, {
    double height = 852,
    Future<void> Function(TestApp app, VaultSession session)? before,
  }) async {
    usePhoneScreen(tester, size: Size(393, height));
    final app = TestApp();
    await tester.runAsync(() async {
      final session = await app.createVault('pw');
      await before?.call(app, session);
    });
    app.store.setItem(keyTheme, (brightness == Brightness.dark ? ThemeChoice.dark : ThemeChoice.light).name);
    await app.pump(tester, overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0')]);
    await app.unlock(tester, 'pw');
    app.container.read(routerProvider).go(location);
    await tester.pumpAndSettle();
    return app;
  }

  /// A Recovery Kit of three pieces, biometric unlock and a backup today.
  Future<void> wellKept(TestApp app, VaultSession session) async {
    await app.vaultStore.setRecoveryKey(
      session,
      RecoveryKey(kitId: 'kit', key: Uint8List(32), threshold: 2, shares: 3, createdAt: '2026-10-01T00:00:00.000Z'),
    );
    await writeOldBiometricEntry(app.store, app.vaults, session);
    app.store.setItem(prefsKey, jsonEncode({'lastBackupAt': testNow.millisecondsSinceEpoch, 'lockOnHide': true}));
  }

  /// Scrolls the Vaults row clear of the tab bar and opens the sheet.
  Future<void> openVaults(WidgetTester tester) async {
    final row = find.widgetWithText(GroupRow, t('vaults.title'));
    final below = find.widgetWithText(GroupRow, t('app.menu.qrImport'));
    await tester.scrollUntilVisible(below, 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Scrolls the mail apps group to the top of the screen, with the foot of the group above it in view.
  Future<void> showMailApps(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text(t('settings.section.mailApps').toUpperCase()),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(find.text(t('settings.section.mailApps').toUpperCase())), alignment: 0.25);
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('settings: a new vault, $name', (tester) async {
      await open(tester, brightness, '/settings', height: 2300);
      await takeScreenshot(tester, 'settings_new_vault_$name');
    });

    testScreenshot('settings: a well-kept vault, $name', (tester) async {
      await open(tester, brightness, '/settings', before: wellKept);
      await takeScreenshot(tester, 'settings_well_kept_$name');
    });

    testScreenshot('settings: the Keys group with reminders on, $name', (tester) async {
      await open(
        tester,
        brightness,
        '/settings',
        height: 2700,
        before: (app, session) async {
          await wellKept(app, session);
          app.store.setItem(prefsKey, jsonEncode({'lastBackupAt': testNow.millisecondsSinceEpoch, 'keyReminders': true}));
        },
      );
      await takeScreenshot(tester, 'settings_keys_$name');
    });

    // openspec: add-offline-mode, against the Network group of Settings.dc.html
    testScreenshot('settings: offline mode on, $name', (tester) async {
      await open(tester, brightness, '/settings', height: 1400, before: (app, _) async => app.store.setItem(keyOffline, '{"on":true}'));
      await takeScreenshot(tester, 'settings_offline_on_$name');
    });

    testScreenshot('settings: offline mode off, $name', (tester) async {
      await open(tester, brightness, '/settings');
      await takeScreenshot(tester, 'settings_offline_off_$name');
    });

    testScreenshot('settings: auto-lock menu, $name', (tester) async {
      await open(tester, brightness, '/settings', height: 1400, before: wellKept);
      await tester.tap(find.text(t('settings.autoLock.value', {'minutes': 5})));
      await takeScreenshot(tester, 'settings_auto_lock_menu_$name');
    });

    testScreenshot('settings: vaults sheet, $name', (tester) async {
      await open(
        tester,
        brightness,
        '/settings',
        before: (app, _) async {
          await app.vaultStore.createVault('Work', 'work password', listed: true);
          await app.vaultStore.createVault('Family', 'family password', listed: true);
        },
      );
      await openVaults(tester);
      await takeScreenshot(tester, 'settings_vaults_$name');
    });

    testScreenshot('settings: vaults sheet, hidden, $name', (tester) async {
      await open(tester, brightness, '/settings');
      await openVaults(tester);
      await tester.tap(find.text(t('vaults.showOnLock')));
      await takeScreenshot(tester, 'settings_vaults_hidden_$name');
    });

    testScreenshot('settings: new vault form, $name', (tester) async {
      await open(tester, brightness, '/settings');
      await openVaults(tester);
      await tester.tap(find.text(t('vaults.new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t('vaults.field.name')), 'Diary');
      await tester.enterText(find.widgetWithText(TextField, t('setup.field.password')), 'diary password');
      await tester.enterText(find.widgetWithText(TextField, t('setup.field.confirm')), 'diary pass');
      await tester.tap(find.text(t('vaults.new.hide')));
      FocusManager.instance.primaryFocus?.unfocus();
      await takeScreenshot(tester, 'settings_new_vault_$name');
    });

    // openspec: add-pgp-mail-provider, against the mail apps group of Settings.dc.html
    testScreenshot('settings: mail apps that use your PGP keys, $name', (tester) async {
      await open(
        tester,
        brightness,
        '/settings',
        before: (app, session) async {
          final parsed = await crypto.readPrivateKey(fixtureBytes(fixtureKeys['kemlock-ed']!.$1));
          await app.vaultStore.saveKeys([vaultKeyOf(parsed, id: 'pgp-ada', name: 'Ada Lovelace', origin: KeyOrigin.imported)], session);
          await MailAppsStore(app.vaultStore).save([
            MailApp(
              package: 'net.thunderbird.android',
              cert: 'aa',
              name: 'Thunderbird',
              allowedAt: DateTime(2026, 11, 2, 12).millisecondsSinceEpoch,
              keys: const ['pgp-ada'],
            ),
            MailApp(
              package: 'eu.faircode.email',
              cert: 'bb',
              name: 'FairEmail',
              allowedAt: DateTime(2026, 11, 9, 12).millisecondsSinceEpoch,
              keys: const ['pgp-ada'],
            ),
          ], session);
        },
      );
      await showMailApps(tester);
      await takeScreenshot(tester, 'settings_mail_apps_$name');
    });

    testScreenshot('settings: no mail app yet, $name', (tester) async {
      await open(tester, brightness, '/settings');
      await showMailApps(tester);
      await takeScreenshot(tester, 'settings_mail_apps_none_$name');
    });

    testScreenshot('settings: about, $name', (tester) async {
      await open(tester, brightness, '/about', height: 1900);
      await takeScreenshot(tester, 'settings_about_$name');
    });

    testScreenshot('settings: terms, $name', (tester) async {
      await open(tester, brightness, '/terms', height: 3500);
      await takeScreenshot(tester, 'settings_terms_$name');
    });

    // openspec: add-fdroid-release; no mockup. Written only by a run on the free build.
    if (buildKind == BuildKind.free) {
      testScreenshot('settings: about, the free build, $name', (tester) async {
        await open(tester, brightness, '/about', height: 1900);
        await takeScreenshot(tester, 'settings_about_free_build_$name');
      });
    }
  }
}
