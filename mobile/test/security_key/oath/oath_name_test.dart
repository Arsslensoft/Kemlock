import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/oath/oath_name.dart';

void main() {
  test('reads issuer and label around the first colon', () {
    expect(parseOathName('Example:alice@example.org', timeBased: true), const OathName(issuer: 'Example', label: 'alice@example.org'));
    expect(parseOathName('Example:a:b', timeBased: true), const OathName(issuer: 'Example', label: 'a:b'));
    expect(parseOathName('Crédit Coopératif:hélène', timeBased: true), const OathName(issuer: 'Crédit Coopératif', label: 'hélène'));
    expect(parseOathName('例の会社:山田', timeBased: true), const OathName(issuer: '例の会社', label: '山田'));
  });

  test('a name with no colon, or nothing on one side of it, is a label alone', () {
    expect(parseOathName('alice@example.org', timeBased: true), const OathName(label: 'alice@example.org'));
    expect(parseOathName(':alice', timeBased: true), const OathName(label: ':alice'));
    expect(parseOathName('Example:', timeBased: true), const OathName(label: 'Example:'));
  });

  test('reads a period in front of a time-based name, and leaves it in a counter-based one', () {
    expect(
      parseOathName('60/Example:alice@example.org', timeBased: true),
      const OathName(issuer: 'Example', label: 'alice@example.org', period: 60),
    );
    expect(parseOathName('15/alice', timeBased: true), const OathName(label: 'alice', period: 15));
    expect(parseOathName('60/Example:alice', timeBased: false), const OathName(issuer: '60/Example', label: 'alice'));
    expect(parseOathName('a/b:c', timeBased: true), const OathName(issuer: 'a/b', label: 'c'));
    expect(parseOathName('0/b:c', timeBased: true), const OathName(issuer: '0/b', label: 'c'));
  });

  test('builds the name Yubico’s apps write, the period only when it is not 30', () {
    expect(buildOathName(issuer: 'Example', label: 'alice@example.org', timeBased: true), 'Example:alice@example.org');
    expect(buildOathName(issuer: 'Example', label: 'alice', period: 60, timeBased: true), '60/Example:alice');
    expect(buildOathName(issuer: 'Example', label: 'alice', period: 60, timeBased: false), 'Example:alice');
    expect(buildOathName(issuer: '', label: 'alice', timeBased: true), 'alice');
    expect(buildOathName(issuer: '例の会社', label: '山田', timeBased: true), '例の会社:山田');
  });

  test('a built name reads back as its parts', () {
    for (final (issuer, label, period) in [
      ('Example', 'alice@example.org', 30),
      ('Crédit', 'hélène', 60),
      ('', 'alone', 30),
      ('例', '山田', 45),
    ]) {
      final name = buildOathName(issuer: issuer, label: label, period: period, timeBased: true);
      expect(parseOathName(name, timeBased: true), OathName(issuer: issuer, label: label, period: period));
    }
  });

  test('fits up to 64 bytes of UTF-8, not 65, whatever the letters', () {
    final ascii64 = 'Example:${'a' * 56}';
    expect(utf8.encode(ascii64), hasLength(64));
    expect(oathNameFits(ascii64), isTrue);
    expect(oathNameFits('${ascii64}a'), isFalse);

    // 'é' is two bytes and '山' three: the limit counts bytes, not letters.
    final accented = 'é' * 32;
    expect(utf8.encode(accented), hasLength(64));
    expect(oathNameFits(accented), isTrue);
    expect(oathNameFits('${accented}a'), isFalse);
    expect(oathNameFits('山' * 21), isTrue);
    expect(oathNameFits('山' * 22), isFalse);
    expect(oathNameFits(''), isFalse);
  });

  test('knows the names Yubico’s apps hide', () {
    expect(isHiddenOathName('_hidden:Example:alice'), isTrue);
    expect(isHiddenOathName('Example:_hidden:'), isFalse);
    expect(isHiddenOathName('hidden:Example'), isFalse);
  });
}
