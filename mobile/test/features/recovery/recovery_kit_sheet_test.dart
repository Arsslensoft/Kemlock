import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/time.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/recovery/recovery_kit_sheet.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/key_unlock.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_files.dart';
import '../../fakes/fake_printer.dart';
import '../../helpers/test_app.dart';
import 'pdf_text.dart';
import 'recovery_harness.dart';

/// The Recovery Kit sheet over a page, on vaults in memory with the vault
/// open, a fake printer and share sheet.
class _KitSheet {
  final vaults = RecoveryVaults();
  final printer = FakePrinter(holds: AutoLockHolds());
  final files = FakeFiles();
  late VaultSession session;

  VaultStore get store => vaults.vaults;

  /// Sets the vault up, opens it unless not [unlocked], runs [setUp] and opens the sheet.
  Future<void> open(WidgetTester tester, {bool unlocked = true, Future<void> Function(VaultController controller)? setUp}) async {
    session = await store.setupVault('pw');
    await pumpLauncher(
      tester,
      vaults,
      (context) => showAppBottomSheet<void>(context, label: 'Recovery Kit', builder: (_) => const RecoveryKitSheet()),
      overrides: [autoLockHoldsProvider.overrideWithValue(printer.holds!), printer.asOverride, files.asOverride],
      before: (container) async {
        final controller = container.read(vaultControllerProvider.notifier);
        if (unlocked) await controller.open(session);
        if (setUp != null) await setUp(controller);
        await tester.pump();
      },
    );
  }
}

/// The button labelled with the message [id].
Finder _button(String id, [Map<String, Object?> args = const {}]) =>
    find.ancestor(of: find.text(t(id, args)), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The way to keep the kit called [id], as screen readers find it.
Finder _way(String id) => find.bySemanticsLabel(RegExp(RegExp.escape(t(id))));

void main() {
  testWidgets('makes a one-piece kit for the user', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester);

    await _tap(tester, _button('recovery.kit.make'));

    expect(find.textContaining(RegExp('^BMCKIT1-')), findsOneWidget);
    expect(find.text(t('recovery.collect.piece', {'index': 1, 'shares': 1})), findsOneWidget);
    expect(find.text(t('recovery.kit.pieces.me')), findsOneWidget);
    expect(sheet.store.recoveryKitInfo(), isA<RecoveryKitInfo>().having((i) => (i.threshold, i.shares), 'split', (1, 1)));
  });

  testWidgets('splits the kit between people: two of three pieces by default', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester);
    expect(
      tester.getSemantics(_way('recovery.kit.me')),
      isSemantics(isInMutuallyExclusiveGroup: true, hasCheckedState: true, isChecked: true),
    );
    expect(tester.getSemantics(_way('recovery.kit.people')), isSemantics(hasCheckedState: true, isChecked: false));

    await _tap(tester, find.text(t('recovery.kit.people')));
    expect(find.text(t('recovery.kit.warning', {'needed': 2})), findsOneWidget);
    await _tap(tester, _button('recovery.kit.make'));

    expect(find.text(t('recovery.collect.piece', {'index': 1, 'shares': 3})), findsOneWidget);
    expect(find.text(t('recovery.kit.pieces.people', {'needed': 2, 'total': 3})), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(_button('qrExport.prev')).onPressed, isNull);
    await _tap(tester, _button('qrExport.next'));
    expect(find.text(t('recovery.collect.piece', {'index': 2, 'shares': 3})), findsOneWidget);
    await _tap(tester, _button('qrExport.next'));
    expect(tester.widget<ButtonStyleButton>(_button('qrExport.next')).onPressed, isNull);
    expect(sheet.store.recoveryKitInfo(), isA<RecoveryKitInfo>().having((i) => (i.threshold, i.shares), 'split', (2, 3)));
  });

  testWidgets('keeps the pieces needed no more than the pieces made', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester);
    await _tap(tester, find.text(t('recovery.kit.people')));

    Future<void> pick(String label, int n) async {
      await _tap(tester, find.widgetWithText(DropdownButtonFormField<int>, label));
      await tester.tap(find.text('$n').last);
      await tester.pumpAndSettle();
    }

    await pick(t('recovery.kit.shares'), 5);
    await pick(t('recovery.kit.needed'), 4);
    expect(find.text(t('recovery.kit.warning', {'needed': 4})), findsOneWidget);
    await pick(t('recovery.kit.shares'), 3);
    expect(find.text(t('recovery.kit.warning', {'needed': 3})), findsOneWidget);

    await _tap(tester, _button('recovery.kit.make'));
    expect(sheet.store.recoveryKitInfo(), isA<RecoveryKitInfo>().having((i) => (i.threshold, i.shares), 'split', (3, 3)));
  });

  testWidgets('says how the kit was made, and removes it', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(
      tester,
      setUp: (_) async {
        final kit = makeKit(2, 3);
        await sheet.store.setRecoveryKey(
          sheet.session,
          RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 2, shares: 3, createdAt: isoString(testNow)),
        );
      },
    );

    expect(find.text(t('recovery.kit.status.people', {'date': 'Oct 16, 2026', 'needed': 2, 'total': 3})), findsOneWidget);
    expect(find.text(t('recovery.kit.replaceHint')), findsOneWidget);

    await _tap(tester, _button('recovery.kit.remove'));

    expect(sheet.store.recoveryKitInfo(), isNull);
    expect(find.text(t('recovery.kit.body')), findsOneWidget);
  });

  // openspec: add-security-key-unlock, task 6.9
  testWidgets('keeps the kit of a vault that needs its one key, and says why', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(
      tester,
      setUp: (_) async {
        final store = sheet.store;
        final kit = makeKit(1, 1);
        await store.setRecoveryKey(
          sheet.session,
          RecoveryKey(kitId: kit.kitId, key: kit.key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
        );
        final proof = await store.enrolKey(
          sheet.session,
          await store.proveOwner(password: 'pw'),
          salt: store.keyChallenge().salt,
          credential: randomBytes(64),
          output: randomBytes(32),
          name: 'Example Key',
          pinBound: true,
        );
        await store.setUnlockMode(sheet.session, proof, UnlockMode.both);
      },
    );

    await _tap(tester, _button('recovery.kit.remove'));

    expect(find.text(t('unlockMethod.recovery.lastWayBack')), findsOneWidget);
    expect(sheet.store.recoveryKitInfo(), isNotNull);
  });

  testWidgets('replaces the kit, so the old pieces open nothing', (tester) async {
    final sheet = _KitSheet();
    final old = makeKit(1, 1);
    await sheet.open(
      tester,
      setUp: (_) => sheet.store.setRecoveryKey(
        sheet.session,
        RecoveryKey(kitId: old.kitId, key: old.key, threshold: 1, shares: 1, createdAt: isoString(testNow)),
      ),
    );
    expect(find.text(t('recovery.kit.status.me', {'date': 'Oct 16, 2026'})), findsOneWidget);

    await _tap(tester, _button('recovery.kit.replace'));
    await _tap(tester, _button('recovery.kit.make'));

    final piece = parsePiece(tester.widget<SelectableText>(find.byType(SelectableText)).data!);
    expect(piece.kitId, isNot(old.kitId));
    expect(sheet.store.recoveryKitInfo()!.kitId, piece.kitId);
    await expectLater(sheet.store.unlockWithRecoveryKey(old.kitId, old.key), throwsA(isA<KitNotFoundError>()));
  });

  testWidgets('says so when the kit could not be made', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester, unlocked: false);

    await _tap(tester, _button('recovery.kit.make'));

    expect(find.text(t('recovery.kit.error')), findsOneWidget);
    expect(sheet.store.recoveryKitInfo(), isNull);
  });

  testWidgets('closes on Done, and Cancel', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester);

    await _tap(tester, _button('changePw.cancel'));
    expect(find.text(t('recovery.kit.title')), findsNothing);
    expect(sheet.store.recoveryKitInfo(), isNull);

    await _tap(tester, find.text('Open'));
    await _tap(tester, _button('recovery.kit.make'));
    await _tap(tester, _button('enableBiometric.done'));
    expect(find.text(t('recovery.kit.title')), findsNothing);
  });

  testWidgets('prints a page per piece, holding auto-lock while the print dialog is open', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester);
    await _tap(tester, find.text(t('recovery.kit.people')));
    await _tap(tester, _button('recovery.kit.make'));
    final pieces = <String>[];
    for (var i = 0; i < 3; i++) {
      pieces.add(tester.widget<SelectableText>(find.byType(SelectableText)).data!);
      if (i < 2) await _tap(tester, _button('qrExport.next'));
    }

    await _tap(tester, _button('recovery.kit.print', {'total': 3}));

    final job = sheet.printer.jobs.single;
    expect(job.name, 'Kemlock Recovery Kit');
    expect(job.held, isTrue);
    expect(sheet.printer.holds!.isHeld, isFalse);
    final pdf = PdfText(job.pdf);
    expect(pdf.pages, hasLength(3));
    for (final (i, page) in pdf.pages.indexed) {
      expect(page.width, closeTo(595.28, 0.01));
      expect(page.text, contains(t('recovery.print.title', {'index': i + 1, 'total': 3, 'vault': t('vaults.defaultName')})));
      expect(page.text, contains(t('recovery.print.meta', {'date': 'Oct 16, 2026', 'needed': 2, 'total': 3})));
      expect(page.text.replaceAll('\n', ' '), contains(pieces[i]));
      expect(page.text, isNot(contains(t('recovery.print.codes'))));
    }
  });

  testWidgets("adds the unused backup codes to a one-piece kit's printout when asked", (tester) async {
    final sheet = _KitSheet();
    await sheet.open(
      tester,
      setUp: (controller) async {
        await controller.addBackupService('GitHub', ['1111-2222', '3333-4444', '5555-6666']);
        await controller.setBackupCodeUsed(controller.state.backupServices.single.id, 0, true);
        await controller.addBackupService('Proton', ['used-only']);
        await controller.setBackupCodeUsed(controller.state.backupServices.last.id, 0, true);
      },
    );
    await _tap(tester, _button('recovery.kit.make'));

    await _tap(tester, _button('recovery.kit.print', {'total': 1}));
    expect(PdfText(sheet.printer.jobs.last.pdf).text, isNot(contains(t('recovery.print.codes'))));

    await _tap(tester, find.text(t('recovery.kit.withCodes')));
    await _tap(tester, _button('recovery.kit.print', {'total': 1}));

    final page = PdfText(sheet.printer.jobs.last.pdf).pages.single;
    expect(page.text, contains(t('recovery.print.codes')));
    expect(page.lines, containsAllInOrder(['GitHub', '3333-4444 5555-6666']));
    expect(page.text, isNot(contains('1111-2222')));
    expect(page.text, isNot(contains('Proton')));
  });

  testWidgets('offers no backup codes for a kit split between people', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester, setUp: (controller) => controller.addBackupService('GitHub', ['1111-2222']));
    await _tap(tester, find.text(t('recovery.kit.people')));
    await _tap(tester, _button('recovery.kit.make'));

    expect(find.text(t('recovery.kit.withCodes')), findsNothing);
  });

  testWidgets("shares the printout as a PDF on a phone that can't print", (tester) async {
    final sheet = _KitSheet();
    sheet.printer.printing = false;
    await sheet.open(tester);
    await _tap(tester, _button('recovery.kit.make'));

    await _tap(tester, _button('recovery.kit.print', {'total': 1}));

    expect(sheet.printer.jobs, isEmpty);
    final shared = sheet.files.saved.single;
    expect((shared.name, shared.mimeType, shared.shared), ('kemlock-recovery-kit.pdf', 'application/pdf', true));
    expect(PdfText(shared.bytes).pages, hasLength(1));
  });

  testWidgets('prints in the Geist fonts, with the QR code drawn rather than pictured', (tester) async {
    final sheet = _KitSheet();
    await sheet.open(tester);
    await _tap(tester, _button('recovery.kit.make'));

    await _tap(tester, _button('recovery.kit.print', {'total': 1}));

    final page = PdfText(sheet.printer.jobs.single.pdf).pages.single;
    expect(page.fonts, containsAll(['Geist-Bold', 'Geist-Regular', 'GeistMono-Regular']));
    expect(page.images, 0);
  });

  testWidgets('opens through showRecoveryKitSheet with its title', (tester) async {
    final vaults = RecoveryVaults();
    final session = await vaults.vaults.setupVault('pw');
    await pumpLauncher(
      tester,
      vaults,
      showRecoveryKitSheet,
      before: (container) => container.read(vaultControllerProvider.notifier).open(session),
    );

    expect(find.text(t('recovery.kit.title')), findsOneWidget);
    expect(find.text(t('recovery.kit.warning', {'needed': 1})), findsOneWidget);
    expect(find.bySemanticsLabel(t('recovery.kit.title')), findsWidgets);
  });

  // openspec: replace-vault-key-pair, task 3.1
  group('for a replacement of the vault key', () {
    /// Opens the replacement's kit sheet of [threshold] and [shares] over an
    /// open vault, and keeps what it resolves to in [result].
    Future<({RecoveryVaults vaults, Map<String, String?> before, List<RecoveryKey?> result})> open(
      WidgetTester tester, {
      required int threshold,
      required int shares,
    }) async {
      final vaults = RecoveryVaults();
      final session = await vaults.vaults.setupVault('pw');
      final result = <RecoveryKey?>[];
      late Map<String, String?> before;
      await pumpLauncher(
        tester,
        vaults,
        (context) async => result.add(await showReplacementKitSheet(context, threshold: threshold, shares: shares)),
        before: (container) async {
          await container.read(vaultControllerProvider.notifier).open(session);
          before = {for (final key in vaults.store.storedKeys()) key: vaults.store.getItem(key)};
        },
      );
      return (vaults: vaults, before: before, result: result);
    }

    /// The piece on show, as its text reads.
    String shownPiece(WidgetTester tester) => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((text) => text.data!)
        .singleWhere((text) => text.startsWith('BMCKIT'));

    Future<void> confirmSaved(WidgetTester tester) => _tap(tester, find.text(t('recovery.kit.replacement.saved')));

    testWidgets('makes a kit of one piece, and gives it back once it is saved', (tester) async {
      final sheet = await open(tester, threshold: 1, shares: 1);
      final piece = shownPiece(tester);

      expect(find.text(t('recovery.kit.pieces.me')), findsOneWidget);
      expect(tester.widget<FilledButton>(_button('recovery.kit.replacement.use')).onPressed, isNull);
      await confirmSaved(tester);
      await _tap(tester, _button('recovery.kit.replacement.use'));

      final kit = sheet.result.single!;
      expect((kit.threshold, kit.shares), (1, 1));
      expect(rebuildKey([parsePiece(piece)]), kit.key);
      expect(parsePiece(piece).kitId, kit.kitId);
      expect({for (final key in sheet.vaults.store.storedKeys()) key: sheet.vaults.store.getItem(key)}, sheet.before);
    });

    testWidgets('makes a kit split between people, any two of whose three pieces rebuild it', (tester) async {
      final sheet = await open(tester, threshold: 2, shares: 3);
      final pieces = [shownPiece(tester)];
      for (var i = 1; i < 3; i++) {
        await _tap(tester, find.text(t('qrExport.next')));
        pieces.add(shownPiece(tester));
      }

      expect(find.text(t('recovery.kit.pieces.people', {'needed': 2, 'total': 3})), findsOneWidget);
      await confirmSaved(tester);
      await _tap(tester, _button('recovery.kit.replacement.use'));

      final kit = sheet.result.single!;
      expect((kit.threshold, kit.shares), (2, 3));
      for (final pair in [
        [0, 1],
        [0, 2],
        [1, 2],
      ]) {
        expect(rebuildKey([for (final i in pair) parsePiece(pieces[i])]), kit.key, reason: '$pair');
      }
      expect({for (final key in sheet.vaults.store.storedKeys()) key: sheet.vaults.store.getItem(key)}, sheet.before);
    });

    testWidgets('gives back nothing when cancelled, saved pieces or not', (tester) async {
      final sheet = await open(tester, threshold: 1, shares: 1);
      await confirmSaved(tester);

      await _tap(tester, find.text(t('changePw.cancel')));

      expect(sheet.result, [null]);
      expect({for (final key in sheet.vaults.store.storedKeys()) key: sheet.vaults.store.getItem(key)}, sheet.before);
    });
  });
}
