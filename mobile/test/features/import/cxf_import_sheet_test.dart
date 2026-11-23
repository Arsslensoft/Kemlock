import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/import/import_sheet.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../export/transfer_harness.dart';

// Appendix A of the CXF 1.0 errata, as the fixtures folder's README says.
final _example = File('test/fixtures/import/cxf/fido-example.json').readAsStringSync();

Future<void> _read(WidgetTester tester, FakeFiles files, String content) async {
  files.nextPick = FakeFiles.text('export.json', content);
  await tapOn(tester, find.text(t('import.browse')));
}

void main() {
  testWidgets('names a Credential Exchange file after its exporter and previews what it brings and what it leaves out', (tester) async {
    final files = FakeFiles();
    await openSheet(tester, showImportSheet, vault: RecordingVault(), files: files);

    await _read(tester, files, _example);
    expect(find.text(t('import.detected.cxf', {'app': 'Exporter app'})), findsOneWidget);
    await tapOn(tester, find.text(t('import.read')));

    expect(find.text(t('export.chip.logins', {'count': 1})), findsOneWidget);
    expect(find.text(t('export.chip.cards', {'count': 1})), findsOneWidget);
    expect(find.text(t('export.chip.identities', {'count': 5})), findsOneWidget);
    expect(find.text(t('import.cxf.skipped', {'count': 4})), findsOneWidget);
    expect(find.textContaining(t('import.cxf.skip.wifi')), findsOneWidget);
    expect(find.textContaining(t('import.cxf.skip.file')), findsOneWidget);
    expect(find.text(t('import.cxf.notice.passkeyExtras', {'title': 'WebAuthn.io'})), findsOneWidget);
    // Another app's entries are only ever added
    expect(find.text(t('import.mode.replace')), findsNothing);
  });

  testWidgets('says that a version Kemlock does not read is not read, naming it', (tester) async {
    final files = FakeFiles();
    await openSheet(tester, showImportSheet, vault: RecordingVault(), files: files);
    final v2 = jsonEncode({
      ...(jsonDecode(_example) as Map<String, Object?>),
      'version': {'major': 2, 'minor': 0},
    });

    await _read(tester, files, v2);
    await tapOn(tester, find.text(t('import.read')));

    expect(find.text(t('import.error.cxf.version', {'version': '2.0'})), findsOneWidget);
  });
}
