// Writes new cases for test/fixtures/i18n/plurals.json, in its shape, for the
// messages named in IDS, and runs only when asked:
//
//   IDS=lock.failures,lock.erase.warning OUT=/tmp/cases.json \
//     flutter test test/i18n/plural_cases_generator_test.dart
//
// The existing cases in that fixture came from react-intl in the TypeScript
// app and are never regenerated. These come from this app's own formatting,
// so a case made here checks the app against itself: read each one against
// the language's plural rules before adding it to the fixture.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/i18n/icu.dart';
import 'package:kemlock/i18n/messages.dart';

import '../helpers/test_app.dart';

void main() {
  final ids = Platform.environment['IDS'];
  final outPath = Platform.environment['OUT'];

  test('writes the plural cases of the messages in IDS to OUT', () {
    const counts = <num>[0, 1, 2, 3, 5, 21, 100, 1000, 1001, 12345, 1000000, 1234567, 1.5, -1];
    final out = <String, Object?>{};
    for (final locale in AppLocale.values) {
      final messages = testCatalog.of(locale);
      out[locale.name] = {
        for (final id in ids!.split(','))
          id: [
            for (final count in counts)
              () {
                final names = IcuMessage.parse(messages.pattern(id)!).argumentNames.toList()..sort();
                final args = {for (final name in names) name: count};
                return [args, messages.t(id, args)];
              }(),
          ],
      };
    }
    File(outPath!).writeAsStringSync(jsonEncode(out));
  }, skip: ids == null || outPath == null ? 'Set IDS and OUT to write plural cases' : false);
}
