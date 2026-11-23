// The app reaches the OpenPGP code through two files only: `keys.dart` for
// keys and `pgp.dart` for messages. Nothing under lib/features imports a
// file of `crypto/keys/openpgp/` itself.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/features imports no file of crypto/keys/openpgp', () {
    final import = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
    final offenders = <String>[];
    var files = 0;
    for (final file in Directory('lib/features').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      files++;
      for (final match in import.allMatches(file.readAsStringSync())) {
        if (match.group(1)!.contains('crypto/keys/openpgp/')) offenders.add('${file.path}: ${match.group(1)}');
      }
    }
    expect(files, greaterThan(50), reason: 'the folder was read');
    expect(offenders, isEmpty);
  });

  test('pgp.dart and keys.dart are where the OpenPGP code is exported', () {
    for (final entry in ['lib/crypto/keys/pgp.dart', 'lib/crypto/keys/keys.dart']) {
      expect(File(entry).readAsStringSync(), contains("'openpgp/"), reason: entry);
    }
  });
}
