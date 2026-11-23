import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/time.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/features/recovery/kit_printout.dart';
import 'package:kemlock/features/recovery/recovery_kit_sheet.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/recovery/recovery_unlock_sheet.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_store.dart';
import 'package:pdf/pdf.dart';

import '../fakes/fake_scanner.dart';
import '../features/recovery/recovery_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the Recovery Kit's sheets in their main states, in dark and
/// light, and writes two printouts as PDFs beside them:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/recovery_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<List<String>> openUnlock(WidgetTester tester, RecoveryVaults vaults, {List<Override> overrides = const []}) async {
      usePhoneScreen(tester);
      final session = await vaults.vaults.setupVault('pw');
      final kit = makeKit(2, 3, random: Random(3));
      await vaults.vaults.setRecoveryKey(
        session,
        RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 2, shares: 3, createdAt: isoString(testNow)),
      );
      await pumpLauncher(
        tester,
        vaults,
        (context) async => unawaited(showRecoveryUnlockSheet(context)),
        brightness: brightness,
        overrides: overrides,
      );
      return kit.pieces;
    }

    Future<void> addPiece(WidgetTester tester, String text) async {
      await tester.enterText(find.widgetWithText(TextField, t('recovery.collect.field')), text);
      await tester.pump();
      final add = find.widgetWithText(FilledButton, t('recovery.collect.add'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
    }

    testScreenshot('recovery: unlock, first piece, $name', (tester) async {
      await openUnlock(tester, RecoveryVaults());
      await takeScreenshot(tester, 'recovery_unlock_start_$name');
    });

    testScreenshot('recovery: unlock, a piece in and a typo, $name', (tester) async {
      final pieces = await openUnlock(tester, RecoveryVaults());
      await addPiece(tester, pieces[1]);
      await addPiece(tester, '${pieces[0].substring(0, 30)}X${pieces[0].substring(31)}');
      FocusManager.instance.primaryFocus?.unfocus();
      await takeScreenshot(tester, 'recovery_unlock_progress_$name');
    });

    testScreenshot('recovery: unlock, scanning, $name', (tester) async {
      final pieces = await openUnlock(tester, RecoveryVaults(), overrides: [FakeScanner().asOverride]);
      await addPiece(tester, pieces[1]);
      final scan = find.widgetWithText(FilledButton, t('recovery.collect.scan'));
      await tester.ensureVisible(scan);
      await tester.tap(scan);
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'recovery_unlock_scanning_$name');
    });

    testScreenshot('recovery: unlock, new password, $name', (tester) async {
      final pieces = await openUnlock(tester, RecoveryVaults());
      await addPiece(tester, pieces[1]);
      await addPiece(tester, pieces[2]);
      await tester.enterText(find.widgetWithText(TextField, t('changePw.field.new')), 'brand new password');
      await tester.enterText(find.widgetWithText(TextField, t('changePw.field.confirm')), 'brand new');
      FocusManager.instance.primaryFocus?.unfocus();
      await takeScreenshot(tester, 'recovery_unlock_password_$name');
    });

    /// The kit sheet over a page, on an open vault with backup codes, after [setUp].
    Future<RecoveryVaults> openKit(WidgetTester tester, {Future<void> Function(VaultStore, VaultSession)? setUp}) async {
      usePhoneScreen(tester);
      final vaults = RecoveryVaults();
      final session = await vaults.vaults.setupVault('pw');
      await setUp?.call(vaults.vaults, session);
      await pumpLauncher(
        tester,
        vaults,
        (context) async => unawaited(showRecoveryKitSheet(context)),
        brightness: brightness,
        before: (container) async {
          final controller = container.read(vaultControllerProvider.notifier);
          await controller.open(session);
          await controller.addBackupService('GitHub', ['1111-2222', '3333-4444']);
          container.read(toastsProvider.notifier).dismiss();
        },
      );
      return vaults;
    }

    Future<void> tapText(WidgetTester tester, String text) async {
      final target = find.text(text);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    testScreenshot('recovery: kit, choosing, $name', (tester) async {
      await openKit(tester);
      await takeScreenshot(tester, 'recovery_kit_choose_$name');
    });

    testScreenshot('recovery: kit, choosing people, $name', (tester) async {
      await openKit(tester);
      await tapText(tester, t('recovery.kit.people'));
      await takeScreenshot(tester, 'recovery_kit_people_$name');
    });

    testScreenshot('recovery: kit, one piece, $name', (tester) async {
      await openKit(tester);
      await tapText(tester, t('recovery.kit.make'));
      await tapText(tester, t('recovery.kit.withCodes'));
      await takeScreenshot(tester, 'recovery_kit_piece_$name');
    });

    testScreenshot('recovery: kit, second of three pieces, $name', (tester) async {
      await openKit(tester);
      await tapText(tester, t('recovery.kit.people'));
      await tapText(tester, t('recovery.kit.make'));
      await tapText(tester, t('qrExport.next'));
      await takeScreenshot(tester, 'recovery_kit_pieces_$name');
    });

    testScreenshot('recovery: kit, made, $name', (tester) async {
      await openKit(
        tester,
        setUp: (store, session) {
          final kit = makeKit(2, 3);
          return store.setRecoveryKey(
            session,
            RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 2, shares: 3, createdAt: isoString(testNow)),
          );
        },
      );
      await takeScreenshot(tester, 'recovery_kit_status_$name');
    });
  }

  testScreenshot('recovery: the printouts, as PDFs', (tester) async {
    await tester.runAsync(() async {
      final fonts = await KitPdfFonts.load();
      final split = makeKit(2, 3, random: Random(5));
      final mine = makeKit(1, 1, random: Random(6));
      final printouts = {
        'recovery_kit_split': KitPrintout(
          pages: [
            for (final (i, piece) in split.pieces.indexed)
              (title: t('recovery.print.title', {'index': i + 1, 'total': 3, 'vault': 'Personal'}), piece: piece),
          ],
          meta: t('recovery.print.meta', {'date': 'Oct 16, 2026', 'needed': 2, 'total': 3}),
          howTo: t('recovery.print.howTo', {'needed': 2}),
        ),
        'recovery_kit_mine': KitPrintout(
          pages: [
            (title: t('recovery.print.title', {'index': 1, 'total': 1, 'vault': 'My vault'}), piece: mine.pieces.single),
          ],
          meta: t('recovery.print.meta', {'date': 'Oct 16, 2026', 'needed': 1, 'total': 1}),
          howTo: t('recovery.print.howTo', {'needed': 1}),
          codesTitle: t('recovery.print.codes'),
          codes: [
            (name: 'GitHub', codes: ['a1b2c-3d4e5', 'f6g7h-8i9j0', 'k1l2m-3n4o5', 'p6q7r-8s9t0', 'u1v2w-3x4y5']),
            (name: 'Google', codes: ['1234 5678', '8765 4321', '1111 2222']),
          ],
        ),
      };
      for (final MapEntry(key: file, value: printout) in printouts.entries) {
        final pdf = await buildKitPdf(printout, PdfPageFormat.a4, fonts);
        await (await File('test/screenshots/goldens/$file.pdf').create(recursive: true)).writeAsBytes(pdf);
      }
    });
  });
}
