import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/i18n/icu.dart';

/// What intl-messageformat made of the patterns, from tool/fixtures/i18n_messages.mjs.
final _fixture = jsonDecode(File('test/fixtures/i18n/syntax.json').readAsStringSync()) as Map<String, Object?>;

String _format(String pattern, String locale, [Map<String, Object?> args = const {}]) => IcuMessage.parse(pattern).format(locale, args);

void main() {
  group('formats as intl-messageformat does', () {
    for (final entry in _fixture['syntax']! as List<Object?>) {
      final example = entry! as Map<String, Object?>;
      final pattern = example['pattern']! as String;
      final locale = example['locale']! as String;
      final values = example['values']! as Map<String, Object?>;
      final text = example['text'] as String?;

      test('$locale: $pattern with $values', () {
        if (text != null) {
          expect(_format(pattern, locale, values), text);
        } else {
          // intl-messageformat fails to parse these or, like a missing value, to format them
          expect(() => _format(pattern, locale, values), throwsA(anyOf(isA<FormatException>(), isA<IcuFormatError>())));
        }
      });
    }
  });

  test('has fixtures to compare with', () {
    expect((_fixture['syntax']! as List<Object?>).length, greaterThan(100));
  });

  test('groups the thousands in # by locale, French with a narrow no-break space', () {
    const pattern = '{n, plural, one {# code} other {# codes}}';

    expect(_format(pattern, 'en', {'n': 1234567}), '1,234,567 codes');
    expect(_format(pattern, 'fr', {'n': 1234567}), '1 234 567 codes');
    expect(_format('{n} codes', 'fr', {'n': 1234567}), '1234567 codes');
  });

  test('writes a whole double as JavaScript writes the number', () {
    expect(_format('{n}', 'en', {'n': 30.0}), '30');
    expect(_format('{n}', 'en', {'n': -0.0}), '0');
    expect(_format('{n, plural, =30 {thirty} other {#}}', 'en', {'n': 30.0}), 'thirty');
  });

  test('picks French "one" for 0 and 1, and English "one" for 1 only', () {
    expect(
      [
        for (final n in [0, 1, 1.5, 1.9, 2]) pluralCategory(n, 'fr'),
      ],
      ['one', 'one', 'one', 'one', 'other'],
    );
    expect(
      [
        for (final n in [0, 1, 1.5, 2]) pluralCategory(n, 'en'),
      ],
      ['other', 'one', 'other', 'other'],
    );
  });

  test('reads plural categories of negative and odd numbers as Intl.PluralRules does', () {
    expect(pluralCategory(-1, 'en'), 'one');
    expect(pluralCategory(double.nan, 'fr'), 'other');
    expect(pluralCategory(double.infinity, 'en'), 'other');
    expect(pluralCategory(1000000, 'fr'), 'many');
    expect(pluralCategory(1000000, 'en'), 'other');
  });

  test('lists the arguments a message takes, nested ones too', () {
    final message = IcuMessage.parse(
      '{name} has {count, plural, one {# {kind}} other {# {kind}s and {extra, select, a {{deep}} other {}}}}',
    );

    expect(message.argumentNames, ['count', 'deep', 'extra', 'kind', 'name']);
    expect(IcuMessage.parse("It's plain").argumentNames, isEmpty);
  });

  test('treats a null argument as given, and writes nothing for it', () {
    expect(_format('[{a}]', 'en', {'a': null}), '[]');
    expect(() => _format('[{a}]', 'en'), throwsA(isA<IcuFormatError>()));
  });

  test('refuses what it does not support rather than misreading it', () {
    for (final pattern in ['{n, number}', '{d, date, short}', '{n, selectordinal, one {#st} other {#th}}', 'a <b>bold</b> word']) {
      expect(() => IcuMessage.parse(pattern), throwsFormatException, reason: pattern);
    }
  });
}
