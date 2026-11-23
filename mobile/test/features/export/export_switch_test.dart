// The two halves of the export switch (plan add-credential-exchange, task 8.6): Dart's `credentialExportBuilt` and the
// Android plugin's `credential_export_enabled` resource, which decides whether the exported activity exists. They must
// flip together, so the plugin's build reads the Dart switch's own define instead of keeping a second copy of it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _define = 'KEMLOCK_CREDENTIAL_EXPORT';
const _plugin = 'packages/credential_transfer/android';

void main() {
  test("Dart's switch is read from the define the plugin's build reads", () {
    final dart = File('lib/features/export/credential_export.dart').readAsStringSync();
    final gradle = File('$_plugin/build.gradle.kts').readAsStringSync();

    expect(dart, contains("bool.fromEnvironment('$_define')"));
    expect(gradle, contains('"$_define=true"'));
    expect(gradle, contains('findProperty("dart-defines")'));
    expect(gradle, contains('resValue("bool", "credential_export_enabled"'));
  });

  test('the resource has one source, the build, and no copy that is false for ever in a file', () {
    final values = Directory('$_plugin/src/main/res/values');
    final files = values.existsSync() ? values.listSync().map((entry) => entry.path) : const <String>[];
    for (final path in files) {
      expect(File(path).readAsStringSync(), isNot(contains('credential_export_enabled')), reason: path);
    }
    // The manifest still names it, so the activity exists only when the build says it may
    final manifest = File('$_plugin/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:enabled="@bool/credential_export_enabled"'));
  });
}
