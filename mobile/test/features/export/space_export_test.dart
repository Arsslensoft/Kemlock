import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/export_sheet.dart';
import 'package:kemlock/features/export/qr_export_sheet.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/features/spaces/remembered_export_policies.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/vault/vault_export.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../spaces/chain_kit.dart';
import '../spaces/policy_kit.dart';
import 'transfer_harness.dart';

// What a file export leaves out of its spaces (docs/plans/add-server-spaces.md, task 7.4): the items of a space whose
// verified chain forbids export, named on the sheet, and the items of a server space whose chain hasn't been read, which
// fail closed. The vault's own items always go, and so do a space's whose chain allows it.
void main() {
  final space = uuid(0x5a);
  final bob = Person(2);

  const own = OtpAccount(id: 'own', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);
  final shared = OtpAccount(id: 'shared', issuer: 'Larkspur', label: 'ada', secret: 'JBSWY3DPEHPK3PXP', spaceId: space, addedAt: 0);
  const ownNote = SecureNote(id: 'own-note', title: 'Passport', addedAt: 0);
  final sharedNote = SecureNote(id: 'shared-note', title: 'Router', spaceId: space, addedAt: 0);

  RecordingVault vault() => RecordingVault(accounts: [own, shared], notes: [ownNote, sharedNote]);

  late ProviderContainer container;

  /// A chain of the space where Bob is a confirmed Member and the Owner's `disableExport` was set to each of [flags] in turn.
  SpaceState chainWith(List<bool> flags) {
    final chain = ChainBuilder(space)
      ..create(policyOwner, collection: uuid(0xe0 + 0x5a))
      ..invite(policyOwner, bob)
      ..confirm(policyOwner, bob);
    for (final flag in flags) {
      // A policies record that changes nothing is refused, so a flag the chain already has needs none
      if ((chain.state.policies['disableExport'] == true) != flag) {
        chain.policies(policyOwner, {'disableExport': flag});
      }
    }
    return chain.state;
  }

  /// Opens [sheet] over the vault, with the chain of the space reported as a run would when [policies] is given, and the policy
  /// of an earlier compared chain remembered, as the vault does across a lock, when [remembered] is.
  Future<FakeFiles> openWith(
    WidgetTester tester,
    Future<void> Function(BuildContext context) sheet, {
    Map<String, Object?>? policies,
    SpaceState? remembered,
  }) async {
    final files = FakeFiles();
    container = await openSheet(tester, sheet, files: files, vault: vault());
    if (remembered != null) {
      container.read(rememberedExportPoliciesProvider.notifier).remember(space, bob.id, remembered);
      await tester.pump(const Duration(seconds: 10));
    }
    if (policies != null) {
      container.read(spacePoliciesProvider.notifier)
        ..report(space, bob.id, spaceWithPolicies(0x5a, bob, policies))
        ..name(space, 'Example Co');
      await tester.pump(const Duration(seconds: 10));
    }
    return files;
  }

  Future<VaultExportPayload> exportPlain(WidgetTester tester, FakeFiles files) async {
    await tapOn(tester, find.text(t('export.mode.plaintext')));
    await tester.ensureVisible(find.text(t('export.plaintext.button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t('export.plaintext.button')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    return importVaultPlaintext(files.lastSavedText);
  }

  group('the export sheet', () {
    testWidgets('leaves out the items of a space whose chain forbids export, and names the space', (tester) async {
      final files = await openWith(tester, showExportSheet, policies: {'disableExport': true});

      expect(find.text(t('export.cxf.space', {'count': 2, 'name': 'Example Co'})), findsOneWidget);
      final payload = await exportPlain(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub']);
      expect([for (final note in payload.notes) note.title], ['Passport']);
    });

    testWidgets('takes the items of a space whose chain allows it', (tester) async {
      final files = await openWith(tester, showExportSheet, policies: {'twoStep': true});

      expect(find.textContaining('Example Co'), findsNothing);
      final payload = await exportPlain(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub', 'Larkspur']);
      expect([for (final note in payload.notes) note.title], ['Passport', 'Router']);
    });

    testWidgets('leaves out the items of a server space whose chain hasn’t been read, and says why', (tester) async {
      final files = await openWith(tester, showExportSheet);

      expect(find.text(t('export.space.unknown', {'count': 2})), findsOneWidget);
      final payload = await exportPlain(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub']);
      expect([for (final note in payload.notes) note.title], ['Passport']);
    });

    testWidgets('leaves them out of an encrypted export as well', (tester) async {
      final files = await openWith(tester, showExportSheet, policies: {'disableExport': true});

      await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
      await tester.pump();
      await tapOn(tester, find.text(t('export.button')));

      final payload = (await tester.runAsync(() => importVault(files.lastSavedText, 'long enough password', deriveKey: fastKdf)))!;
      expect([for (final account in payload.accounts) account.issuer], ['GitHub']);
      expect([for (final note in payload.notes) note.title], ['Passport']);
    });
  });

  /// Makes the encrypted backup the open sheet asks for and reads it back.
  Future<VaultExportPayload> exportEncrypted(WidgetTester tester, FakeFiles files) async {
    await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
    await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
    await tester.pump();
    await tapOn(tester, find.text(t('export.button')));
    return (await tester.runAsync(() => importVault(files.lastSavedText, 'long enough password', deriveKey: fastKdf)))!;
  }

  group('the export sheet, with the policies the vault remembers', () {
    testWidgets('takes the items of a space that allowed export when its chain can’t be read now, and counts the backup', (tester) async {
      final files = await openWith(tester, showExportSheet, remembered: chainWith([false]));

      expect(find.text(t('export.space.unknown', {'count': 2})), findsNothing);
      final payload = await exportEncrypted(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub', 'Larkspur']);
      expect([for (final note in payload.notes) note.title], ['Passport', 'Router']);
      expect(container.read(prefsProvider).lastBackupAt, testNow.millisecondsSinceEpoch);
      expect(find.text(t('export.space.partial')), findsNothing);
    });

    testWidgets('still leaves out the items of a space that forbade export, and names it', (tester) async {
      final files = await openWith(tester, showExportSheet, remembered: chainWith([true]));

      expect(find.text(t('export.cxf.space', {'count': 2, 'name': space})), findsOneWidget);
      expect(find.text(t('export.space.unknown', {'count': 2})), findsNothing);
      final payload = await exportEncrypted(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub']);
      expect([for (final note in payload.notes) note.title], ['Passport']);
      expect(container.read(prefsProvider).lastBackupAt, testNow.millisecondsSinceEpoch, reason: 'the space’s own rule, not a gap');
    });

    testWidgets('leaves out a space never verified, says so before saving, and records no backup of a partial one', (tester) async {
      final files = await openWith(tester, showExportSheet);

      expect(find.text(t('export.space.unknown', {'count': 2})), findsOneWidget);
      expect(find.text(t('export.space.partial')), findsOneWidget, reason: 'said before anything is saved');
      final payload = await exportEncrypted(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub']);
      expect([for (final note in payload.notes) note.title], ['Passport']);
      expect(container.read(prefsProvider).lastBackupAt, isNull);
      expect(find.text(t('export.success')), findsOneWidget);
      expect(find.text(t('export.space.partial')), findsOneWidget, reason: 'and said again once it is saved');
    });

    testWidgets('records no backup for a partial one, and says nothing of it for a plain export', (tester) async {
      final files = await openWith(tester, showExportSheet);
      await exportPlain(tester, files);

      expect(container.read(prefsProvider).lastBackupAt, isNull);
      expect(find.text(t('export.space.partial')), findsNothing);
    });

    testWidgets('follows a chain read since over the remembered policy that allowed export', (tester) async {
      final files = await openWith(tester, showExportSheet, remembered: chainWith([false]));
      container.read(spacePoliciesProvider.notifier).reportCompared(space, bob.id, chainWith([false, true]));
      await tester.pump(const Duration(seconds: 10));

      expect(find.text(t('export.cxf.space', {'count': 2, 'name': space})), findsOneWidget);
      final payload = await exportEncrypted(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub']);
    });

    testWidgets('follows a chain read since over the remembered policy that forbade export', (tester) async {
      final files = await openWith(tester, showExportSheet, remembered: chainWith([true]));
      container.read(spacePoliciesProvider.notifier).reportCompared(space, bob.id, chainWith([true, false]));
      await tester.pump(const Duration(seconds: 10));

      expect(find.text(t('export.cxf.space', {'count': 2, 'name': space})), findsNothing);
      expect(find.text(t('export.space.unknown', {'count': 2})), findsNothing);
      final payload = await exportEncrypted(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub', 'Larkspur']);
    });

    testWidgets('lets a chain read since decide even when it is older than the remembered one', (tester) async {
      final files = await openWith(tester, showExportSheet, remembered: chainWith([false, true]));
      container.read(spacePoliciesProvider.notifier).report(space, bob.id, chainWith([false]));
      await tester.pump(const Duration(seconds: 10));

      final payload = await exportEncrypted(tester, files);

      expect([for (final account in payload.accounts) account.issuer], ['GitHub', 'Larkspur']);
    });
  });

  group('the QR export sheet, with the policies the vault remembers', () {
    testWidgets('counts the codes of a space that allowed export when its chain can’t be read now', (tester) async {
      await openWith(tester, showQrExportSheet, remembered: chainWith([false]));

      expect(find.text(t('export.chip.accounts', {'count': 2})), findsOneWidget);
      expect(find.text(t('export.space.unknown', {'count': 1})), findsNothing);
    });

    testWidgets('records no backup of codes that left out a space it never verified, and says it is partial', (tester) async {
      await openWith(tester, showQrExportSheet);
      expect(find.text(t('export.space.unknown', {'count': 1})), findsOneWidget);

      await tester.enterText(fieldLabelled('export.field.password'), 'long enough password');
      await tester.enterText(fieldLabelled('export.field.confirm'), 'long enough password');
      await tester.pump();
      await tapOn(tester, find.text(t('qrExport.generate')));
      await pumpUntilFound(tester, find.text(t('qrExport.ready', {'total': 1})));
      await tester.pumpAndSettle();

      expect(container.read(prefsProvider).lastBackupAt, isNull);
      expect(find.text(t('export.space.partial')), findsOneWidget);
    });
  });

  group('the QR export sheet', () {
    testWidgets('counts only the codes the spaces allow, and names the space that forbids them', (tester) async {
      await openWith(tester, showQrExportSheet, policies: {'disableExport': true});

      expect(find.text(t('export.cxf.space', {'count': 1, 'name': 'Example Co'})), findsOneWidget);
      expect(find.text(t('export.chip.accounts', {'count': 1})), findsOneWidget);
    });
  });
}
