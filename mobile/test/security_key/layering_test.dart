import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String folder) =>
    Directory(folder).listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'));

String _path(File file) => file.path.replaceAll('\\', '/');

void main() {
  test('the protocol code under lib/security_key imports neither Flutter nor a feature', () {
    final files = _dartFiles('lib/security_key').toList();
    expect(files, isNotEmpty);
    final imports = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

    final offending = [
      for (final file in files)
        for (final match in imports.allMatches(file.readAsStringSync()))
          if (match[1]!.startsWith('package:flutter') || match[1]!.contains('features/') || match[1]!.startsWith('dart:ui'))
            '${_path(file)}: ${match[1]}',
    ];

    expect(offending, isEmpty);
  });

  test('only lib/platform/security_keys.dart names the security key channels', () {
    final naming = [
      for (final file in _dartFiles('lib'))
        if (file.readAsStringSync().contains('com.kemlock.app/security_keys')) _path(file),
    ];

    expect(naming, ['lib/platform/security_keys.dart']);
  });
}
