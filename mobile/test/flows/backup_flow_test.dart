import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/export_key.dart';

import '../fakes/fake_files.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';
import '../vault/fast_kdf.dart';
import 'flow_kit.dart';

const _exportPassword = 'a long export password';

/// Export passwords through cheap scrypt, as the vault's, so the sheets needn't wait for an isolate.
final _fastExportKey = exportDeriveKeyProvider.overrideWithValue(fastKdf);

/// An encrypted backup from end to end, through the screens: saved from
/// Settings on one phone, opened on another with its password.
void main() {
  testWidgets('brings an account back on a new phone from an encrypted backup', (tester) async {
    // The old phone: an account, exported from Settings under a password
    final files = FakeFiles();
    await startApp(tester, TestApp(now: () => rfcTime), overrides: [files.asOverride, _fastExportKey]);
    await createVault(tester);
    await addFirstAccount(tester, 'GitHub', rfcSecret);
    expect(code(rfcCode), findsOneWidget);

    await tapOn(tester, tab('nav.settings'));
    await tapOn(tester, find.text(t('app.menu.export')));
    await tester.enterText(field(t('export.field.password')), _exportPassword);
    await tester.enterText(field(t('export.field.confirm')), _exportPassword);
    await tester.pump();
    await tapOn(tester, find.text(t('export.button')));
    // Whoever holds the open vault shows it is them before anything leaves it
    await confirmOwner(tester);
    await pumpUntil(tester, find.text(t('export.success')));
    await tapOn(tester, find.text(t('export.close')));

    final saved = files.saved.single;
    final backup = utf8.decode(saved.bytes);
    expect(saved.name, matches(RegExp(r'^kemlock-export-.*\.json$')));
    expect(backup, isNot(contains(rfcSecret)));
    expect(backup, isNot(contains('GitHub')));

    // The new phone: a vault of its own, and the file brought in from Settings with its password
    final newFiles = FakeFiles()..nextPick = FakeFiles.text(saved.name, backup);
    await startApp(tester, TestApp(now: () => rfcTime), overrides: [newFiles.asOverride, _fastExportKey]);
    await createVault(tester, password: 'Another-Horse-7');

    await tapOn(tester, tab('nav.settings'));
    await tapOn(tester, find.text(t('app.menu.import')));
    await tapOn(tester, find.text(t('import.browse')));
    await tester.enterText(field(t('import.field.password')), _exportPassword);
    await tester.pump();
    await tapOn(tester, find.text(t('import.decrypt')));
    final importOne = find.text(t('import.button.merge', {'count': 1}));
    await pumpUntil(tester, importOne);
    await tapOn(tester, importOne);
    expect(find.text(t('app.snack.importSuccess', {'count': 1})), findsOneWidget);

    // The account is back, with the same code
    await tapOn(tester, tab('nav.codes'));
    expect(accountRow('GitHub'), findsOneWidget);
    expect(code(rfcCode), findsOneWidget);
  });
}
