import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/build_kind.dart';
import 'package:kemlock/features/import/credential_exchange.dart';
import 'package:kemlock/features/import/import_sheet.dart';

import '../../fakes/fake_credential_exchange.dart';
import '../../helpers/test_app.dart';
import '../export/transfer_harness.dart';

// Appendix A of the CXF 1.0 errata, as the fixtures folder's README says.
final _example = File('test/fixtures/import/cxf/fido-example.json').readAsStringSync();

Finder get _androidButton => find.text(t('import.transfer.android.button'));

Finder get _anyTransferError => find.byWidgetPredicate(
  (widget) =>
      widget is Text && CredentialTransferProblem.values.any((problem) => widget.data == t('import.transfer.error.${problem.name}')),
);

void main() {
  group('on Android, in the store build', skip: buildKind == BuildKind.free ? 'the free build has no system list' : null, () {
    testWidgets('offers the system list, asks for the kinds Kemlock keeps, and previews what the exporter sent', (tester) async {
      final transfer = FakeCredentialTransfer(answer: _example);
      await openSheet(tester, showImportSheet, vault: RecordingVault(), overrides: [transfer.asOverride]);
      expect(find.text(t('import.transfer.android.title')), findsOneWidget);
      expect(transfer.asked, isEmpty, reason: 'nothing is asked until the person taps');

      await tapOn(tester, _androidButton);

      expect(transfer.asked.single, credentialTypesKept);
      // Not what Kemlock can't keep
      for (final type in ['file', 'wifi', 'api-key', 'generated-password', 'item-reference']) {
        expect(transfer.asked.single, isNot(contains(type)), reason: type);
      }
      expect(find.text(t('import.detected.transfer', {'app': 'Exporter app'})), findsOneWidget);
      // The preview, without a file and without a second tap
      expect(find.text(t('export.chip.logins', {'count': 1})), findsOneWidget);
      expect(find.text(t('export.chip.cards', {'count': 1})), findsOneWidget);
      expect(find.text(t('import.cxf.skipped', {'count': 4})), findsOneWidget);
      expect(find.text(t('import.mode.replace')), findsNothing);
    });

    testWidgets('closing the list is not an error and leaves the sheet as it was', (tester) async {
      final transfer = FakeCredentialTransfer();
      await openSheet(tester, showImportSheet, vault: RecordingVault(), overrides: [transfer.asOverride]);

      await tapOn(tester, _androidButton);

      expect(transfer.asked, hasLength(1));
      expect(_anyTransferError, findsNothing);
      expect(find.text(t('import.error.unsupported')), findsNothing);
      expect(find.text(t('export.chip.logins', {'count': 1})), findsNothing);
      // The button is there to be tapped again
      final button = find.ancestor(of: _androidButton, matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
      expect(tester.widget<ButtonStyleButton>(button).enabled, isTrue);
    });

    testWidgets('says what went wrong for each kind of failure, and previews nothing', (tester) async {
      for (final problem in CredentialTransferProblem.values) {
        final transfer = FakeCredentialTransfer(answer: _example, problem: CredentialTransferException(problem));
        await openSheet(tester, showImportSheet, vault: RecordingVault(), overrides: [transfer.asOverride]);

        await tapOn(tester, _androidButton);

        expect(find.text(t('import.transfer.error.${problem.name}')), findsOneWidget, reason: problem.name);
        expect(find.text(t('export.chip.logins', {'count': 1})), findsNothing, reason: problem.name);
      }
    });

    testWidgets('names a version it does not read, and a payload that is not Credential Exchange', (tester) async {
      final v2 = jsonEncode({
        ...(jsonDecode(_example) as Map<String, Object?>),
        'version': {'major': 2, 'minor': 0},
      });
      final transfer = FakeCredentialTransfer(answer: v2);
      await openSheet(tester, showImportSheet, vault: RecordingVault(), overrides: [transfer.asOverride]);

      await tapOn(tester, _androidButton);
      expect(find.text(t('import.error.cxf.version', {'version': '2.0'})), findsOneWidget);

      final other = FakeCredentialTransfer(answer: '{"hello": 1}');
      await openSheet(tester, showImportSheet, vault: RecordingVault(), overrides: [other.asOverride]);

      await tapOn(tester, _androidButton);
      expect(find.text(t('import.error.unsupported')), findsOneWidget);
    });

    testWidgets('shows no row where the phone cannot start a transfer', (tester) async {
      final transfer = FakeCredentialTransfer(available: false);
      await openSheet(tester, showImportSheet, vault: RecordingVault(), overrides: [transfer.asOverride]);

      expect(find.text(t('import.transfer.android.title')), findsNothing);
      expect(_androidButton, findsNothing);
      expect(find.text(t('import.transfer.free.help')), findsNothing);
    });
  });

  testWidgets('the free build shows the help and no row, and a file still opens', (tester) async {
    final transfer = FakeCredentialTransfer(answer: _example);
    await openSheet(
      tester,
      showImportSheet,
      vault: RecordingVault(),
      overrides: [transfer.asOverride, buildKindProvider.overrideWithValue(BuildKind.free)],
    );

    expect(find.text(t('import.transfer.free.help')), findsOneWidget);
    expect(_androidButton, findsNothing);
    expect(find.text(t('import.browse')), findsOneWidget);
    expect(transfer.asked, isEmpty);
  });

  group('on iOS 26', () {
    Future<void> openOnIos(WidgetTester tester, FakeIosCredentialExchange exchange, {ImportTransfer? transfer}) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await openSheet(
          tester,
          (context) => showImportSheet(context, transfer: transfer),
          vault: RecordingVault(),
          overrides: [exchange.asOverride],
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('says where an export starts, with no button, because Kemlock cannot start one', (tester) async {
      await openOnIos(tester, FakeIosCredentialExchange());

      expect(find.text(t('import.transfer.ios.title')), findsOneWidget);
      expect(find.text(t('import.transfer.ios.steps')), findsOneWidget);
      expect(_androidButton, findsNothing);
    });

    testWidgets('shows no row before iOS 26', (tester) async {
      await openOnIos(tester, FakeIosCredentialExchange(isSupported: false));

      expect(find.text(t('import.transfer.ios.title')), findsNothing);
    });

    testWidgets('reads the export behind its token as soon as the sheet is open, and previews it', (tester) async {
      final exchange = FakeIosCredentialExchange(json: _example);

      await openOnIos(tester, exchange, transfer: const IosTransfer('token-1'));

      expect(exchange.fetches, ['token-1']);
      expect(find.text(t('import.detected.transfer', {'app': 'Exporter app'})), findsOneWidget);
      expect(find.text(t('export.chip.logins', {'count': 1})), findsOneWidget);
    });

    testWidgets('says so when the system refuses the token, and previews nothing', (tester) async {
      final exchange = FakeIosCredentialExchange(fails: true);

      await openOnIos(tester, exchange, transfer: const IosTransfer('stale'));

      expect(exchange.fetches, ['stale']);
      expect(find.text(t('import.transfer.error.ios')), findsOneWidget);
      expect(find.text(t('export.chip.logins', {'count': 1})), findsNothing);
    });
  });
}
