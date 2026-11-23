import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The closed packages the free build leaves out (openspec: add-fdroid-release, design
/// decision 1): ML Kit's barcode scanner and text recognition, and pdfrx, whose
/// PDFium is a prebuilt binary fetched while the app is built. And credential_transfer, the
/// Android plugin over the providerevents libraries, one of which brings Google Play services
/// (openspec: plan add-credential-exchange, design decision 8).
const _closed = ['mobile_scanner', 'google_mlkit_text_recognition', 'pdfrx', 'credential_transfer'];

final _closedImport = RegExp('''^\\s*(?:import|export)\\s+['"]package:(${_closed.join('|')})/''', multiLine: true);

/// The files under [root] that import or export one of the closed packages, as paths from [root].
List<String> closedImporters(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const [];
  final found = <String>[];
  for (final file in dir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    if (_closedImport.hasMatch(file.readAsStringSync())) {
      found.add(file.path.replaceAll(r'\', '/').substring(root.length + 1));
    }
  }
  return found..sort();
}

void main() {
  // Only packages/parts_store, the store build's kemlock_parts, may use them; the app reads
  // what it needs through kemlock_parts' defaults and kemlock_ports' interfaces.
  test('nothing under lib/ imports the closed packages', () {
    expect(closedImporters('lib'), isEmpty);
  });

  test('nor do the tests, which reach them only through kemlock_parts', () {
    expect(closedImporters('test'), isEmpty);
    expect(closedImporters('integration_test'), isEmpty);
  });

  test('nor the interfaces or the free build, so it builds without them', () {
    for (final package in ['packages/kemlock_ports', 'packages/parts_free']) {
      expect(closedImporters(package), isEmpty, reason: package);
    }
  });
}
