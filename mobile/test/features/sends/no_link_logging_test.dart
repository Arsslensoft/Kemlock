// A Send's link carries its key in the fragment, so nothing that handles one may log. The lint already sets
// `avoid_print`; this fails on `print` and `debugPrint` in the Sends code and the Send routes' client, and checks
// that a failed Send request's errors hold no part of a key.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_sends_api.dart';

final _logging = RegExp(r'(^|[^A-Za-z0-9_])(print|debugPrint|log|developer\.log|stdout\.write\w*|stderr\.write\w*)\s*\(');

/// The lines of [source] that log, comments aside.
List<String> loggingLines(String source) => [
  for (final line in source.split('\n'))
    if (!line.trimLeft().startsWith('//') && _logging.hasMatch(line)) line.trim(),
];

void main() {
  test('a file that logs a link is caught', () {
    expect(loggingLines("void f(String link) {\n  debugPrint('opening \$link');\n}"), isNotEmpty);
    expect(loggingLines('  print(link);'), isNotEmpty);
    expect(loggingLines("  developer.log('x');"), isNotEmpty);
    expect(loggingLines('  // print(link) would leak the key'), isEmpty);
    expect(loggingLines('  final footprint = 1;\n  blueprint(1);'), isEmpty);
  });

  test('nothing under lib/features/sends or km_sends_api.dart logs', () {
    final files = [
      for (final entity in Directory('lib/features/sends').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart')) entity,
      File('lib/features/sync/kemlock/km_sends_api.dart'),
    ];
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(loggingLines(file.readAsStringSync()), isEmpty, reason: file.path);
    }
  });

  test('the errors of a failed Send request hold no part of a key', () {
    final key = b64urlEncode(Uint8List.fromList(List.generate(32, (i) => 100 + i)));
    final errors = <Object>[
      const SendsError(SendsProblem.wrongPassword, status: 401),
      const SendsError(SendsProblem.notFound, status: 404),
      const SendsError(SendsProblem.policy, detail: 'Sends are turned off', status: 403),
      const SendsError(SendsProblem.rateLimited, retryAfter: 9, status: 429),
      const KmError(KmProblem.server, status: 500, message: 'a Send answer'),
      const KmError(KmProblem.network),
    ];
    for (final error in errors) {
      expect('$error', isNot(contains(key)));
      expect('$error', isNot(contains(key.substring(0, 8))));
    }
  });
}
