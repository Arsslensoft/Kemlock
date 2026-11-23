import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/core/build_kind.dart';
import 'package:kemlock/features/backup/add_backup_service_sheet.dart';
import 'package:kemlock/features/backup/backup_page.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../fakes/fake_code_readers.dart';
import '../fakes/fake_files.dart';
import '../features/backup/backup_test_kit.dart';
import '../helpers/app_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the Backup tab: its services and coverage, the empty tab, a
/// card adding codes, and the sheet that adds a service, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/backup_tab_test.dart
void main() {
  final march = DateTime(2026, 3, 14).millisecondsSinceEpoch;
  final services = [
    BackupService(
      id: 'gh',
      serviceName: 'GitHub',
      codes: [
        BackupCode(code: 'a1b2c-3d4e5', used: true, usedAt: march),
        const BackupCode(code: 'f6g7h-8i9j0', used: true),
        const BackupCode(code: 'k1l2m-3n4o5'),
        const BackupCode(code: 'p6q7r-8s9t0'),
        const BackupCode(code: 'u1v2w-3x4y5'),
        const BackupCode(code: 'z6a7b-8c9d0'),
      ],
      note: 'Printed copy in the safe',
      addedAt: 1,
    ),
    service('go', 'Google', ['1234 5678', '2345 6789', '3456 7890', '4567 8901'], used: 3),
    service('dr', 'Dropbox', ['QWER-TYUI-OPAS', 'DFGH-JKLZ-XCVB', 'NMQW-ERTY-UIOP', 'ASDF-GHJK-LZXC', 'VBNM-QWER-TYUI']),
  ];
  final accounts = <OtpAccount>[
    account('1', 'GitHub'),
    account('2', 'Google'),
    account('3', 'Dropbox'),
    account('4', 'Steam'),
    account('5', 'Discord'),
    account('6', 'Proton'),
  ];

  /// The whole app on a phone, unlocked on the Backup tab, in [brightness].
  Future<TestApp> open(
    WidgetTester tester,
    Brightness brightness, {
    List<BackupService> services = const [],
    List<OtpAccount> accounts = const [],
    double height = 852,
    List<Override> overrides = const [],
  }) async {
    usePhoneScreen(tester, size: Size(393, height));
    final app = TestApp();
    await tester.runAsync(() async {
      final session = await app.createVault('pw');
      await app.vaultStore.saveAccounts(accounts, session);
      await app.vaultStore.saveBackupServices(services, session);
    });
    app.store.setItem(keyTheme, (brightness == Brightness.dark ? ThemeChoice.dark : ThemeChoice.light).name);
    await app.pump(tester, overrides: [realDirectory, ...overrides]);
    await app.unlock(tester, 'pw');
    app.container.read(routerProvider).go('/backup');
    await tester.pumpAndSettle();
    return app;
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('backup: services and coverage, $name', (tester) async {
      await open(tester, brightness, services: services, accounts: accounts, height: 1900);
      await takeScreenshot(tester, 'backup_services_$name');
    });

    testScreenshot('backup: a service running low, open, $name', (tester) async {
      await open(tester, brightness, services: services, height: 1500);
      await tester.tap(find.text('Google'));
      await takeScreenshot(tester, 'backup_low_$name');
    });

    testScreenshot('backup: empty, $name', (tester) async {
      await open(tester, brightness, accounts: accounts.take(2).toList());
      await takeScreenshot(tester, 'backup_empty_$name');
    });

    testScreenshot('backup: adding codes to a service, $name', (tester) async {
      await open(tester, brightness, services: services.take(1).toList(), height: 1300);
      await tester.tap(find.byTooltip(t('backupCard.addButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'k1l2m-3n4o5\nb4c5d-6e7f8\ng9h0i-1j2k3');
      await tester.pump();
      await tester.tap(find.text(t('codeImport.button')));
      await takeScreenshot(tester, 'backup_add_codes_$name');
    });

    testScreenshot('backup: the add sheet with codes read from a picture, $name', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('codes.png');
      final readers = FakeCodeReaders();
      readers.images.text = 'Google backup codes\n1234 5678  8765 4321\n2468 1357  9753 8642\n1357 2468  8642 9753';
      await open(tester, brightness, accounts: accounts, overrides: [files.asOverride, ...readers.overrides]);
      final context = tester.element(find.byType(BackupPage));
      showAddBackupServiceSheet(context, initialName: 'Google').ignore();
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('codeImport.button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('codeImport.from.photos')));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await takeScreenshot(tester, 'backup_sheet_imported_$name');
    });

    testScreenshot('backup: the add sheet, nothing found, $name', (tester) async {
      final files = FakeFiles()..nextPick = FakeFiles.image('cat.png');
      final readers = FakeCodeReaders();
      readers.images.text = 'A cat on a sofa';
      await open(tester, brightness, overrides: [files.asOverride, ...readers.overrides]);
      await tester.tap(find.text(t('app.empty.backup.action')));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t('addBackup.field.codes')), ' , ,');
      await tester.tap(find.text(t('codeImport.button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('codeImport.from.photos')));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await takeScreenshot(tester, 'backup_sheet_none_$name');
    });

    testScreenshot('backup: deleting a service, $name', (tester) async {
      await open(tester, brightness, services: services.take(1).toList());
      await tester.tap(find.bySemanticsLabel(t('backupCard.tooltip.delete')));
      await takeScreenshot(tester, 'backup_delete_$name');
    });

    // openspec: add-fdroid-release; no mockup. Written only by a run on the free build.
    if (buildKind == BuildKind.free) {
      testScreenshot('backup: the add sheet, text files only, the free build, $name', (tester) async {
        await open(tester, brightness, accounts: accounts);
        showAddBackupServiceSheet(tester.element(find.byType(BackupPage)), initialName: 'Google').ignore();
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await takeScreenshot(tester, 'backup_sheet_free_build_$name');
      });
    }
  }
}
