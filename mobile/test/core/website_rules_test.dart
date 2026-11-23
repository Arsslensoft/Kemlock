import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/website_rules.dart';
import 'package:kemlock/features/autofill/autofill_copy.dart' show sharedHosts;
import 'package:kemlock/models/website_rule.dart';

typedef _Json = Map<String, Object?>;

final _fixture = jsonDecode(File('test/fixtures/websites/rules.json').readAsStringSync()) as _Json;
final _registrable = (_fixture['registrable']! as _Json).cast<String, String>();
final _cases = [for (final c in _fixture['cases']! as List<Object?>) c! as _Json];

String _registrableOf(String host) => _registrable[host] ?? host;

bool _isShared(String host) => sharedHosts.any((shared) => host == shared || host.endsWith('.$shared'));

WebsiteRule _ruleOf(_Json c) => WebsiteRule(c['uri']! as String, match: c['match'] as int?);

String _addressOf(_Json c) {
  final fill = c['addressFill'];
  if (fill is _Json) return (fill['repeat']! as String) * (fill['times']! as int) + (fill['then']! as String);
  return c['address']! as String;
}

// the add-cards-identities-and-websites plan, tasks 6.2 and 6.3
void main() {
  group('rules.json', () {
    for (final c in _cases) {
      test('fills: ${c['name']}', () {
        expect(fillsOn(_ruleOf(c), _addressOf(c), registrable: _registrableOf, isShared: _isShared), c['fills']);
      });
    }

    for (final c in _cases) {
      test('phones: ${c['name']}', () {
        final phones = c['phones']! as _Json;
        for (final (kind, key) in [(WebsiteKind.login, 'login'), (WebsiteKind.account, 'account')]) {
          expect(
            phoneDomains([_ruleOf(c)], kind, registrable: _registrableOf, isShared: _isShared),
            (phones[key]! as List<Object?>).cast<String>(),
            reason: key,
          );
        }
      });
    }
  });

  group('phone domains', () {
    test('of several websites come in order, each once', () {
      final rules = [
        const WebsiteRule('example.co'),
        const WebsiteRule('shop.example.co', match: WebsiteMatch.baseDomain),
        const WebsiteRule('example-co.okta.com', match: WebsiteMatch.host),
        const WebsiteRule('wiki.example.co', match: WebsiteMatch.never),
      ];

      expect(phoneDomains(rules, WebsiteKind.login, registrable: _registrableOf, isShared: _isShared), [
        'example.co',
        '=example-co.okta.com',
      ]);
    });

    test('without a Public Suffix List a host stays as it is', () {
      expect(phoneDomains([const WebsiteRule('accounts.larkspur.example')], WebsiteKind.login), ['accounts.larkspur.example']);
    });
  });

  group('the pattern engine', () {
    bool matches(String pattern, String text) {
      final compiled = compilePattern(pattern);
      expect(compiled.refusal, isNull, reason: pattern);
      return compiled.program!.hasMatchIn(text);
    }

    test('matches literals, escapes, classes, groups, alternatives and counts, as a search', () {
      expect(matches('abc', 'xxabcxx'), isTrue);
      expect(matches('^abc', 'xxabc'), isFalse);
      expect(matches('abc\$', 'xxabc'), isTrue);
      expect(matches('a.c', 'abc'), isTrue);
      expect(matches('a\\.c', 'abc'), isFalse);
      expect(matches('a\\.c', 'a.c'), isTrue);
      expect(matches('[a-c]+x', 'zzabcx'), isTrue);
      expect(matches('^[^a-c]+\$', 'xyz'), isTrue);
      expect(matches('^[^a-c]+\$', 'xaz'), isFalse);
      expect(matches('\\d{3}-\\d{2}', 'tel 123-45'), isTrue);
      expect(matches('^\\w+\\s\\w+\$', 'two words'), isTrue);
      expect(matches('^\\D\\W\\S\$', 'a-b'), isTrue);
      expect(matches('(cat|dog)s?', 'hotdogs'), isTrue);
      expect(matches('(?:ab){2,3}\$', 'xababab'), isTrue);
      expect(matches('^(?:ab){2}\$', 'ababab'), isFalse);
      expect(matches('^a{2,}\$', 'aaaa'), isTrue);
      expect(matches('^a{2,}\$', 'a'), isFalse);
      expect(matches('^colou?r\$', 'color'), isTrue);
      expect(matches('a{', 'a{'), isTrue, reason: 'a lone brace is a literal');
      expect(matches('^\\x41\\u0042\$', 'AB'), isTrue);
      expect(matches('^[\\d.]+\$', '1.5'), isTrue);
      expect(matches('^[a\\-z]+\$', 'a-z'), isTrue);
    });

    test('ignores case, in literals and in classes', () {
      expect(matches('HELLO', 'say hello'), isTrue);
      expect(matches('^[a-z]+\$', 'ABC'), isTrue);
      expect(matches('^[^a-z]+\$', 'ABC'), isFalse);
    });

    test('lazy forms answer as greedy ones do', () {
      expect(matches('^a+?b\$', 'aaab'), isTrue);
      expect(matches('^a*?\$', 'aaa'), isTrue);
    });

    test('an empty pattern, and an empty alternative, match anywhere', () {
      expect(matches('', 'anything'), isTrue);
      expect(matches('a|', 'b'), isTrue);
    });

    test('an address over 2048 characters never matches, and one of 2048 can', () {
      final program = compilePattern('a').program!;

      expect(program.hasMatchIn('a' * 2048), isTrue);
      expect(program.hasMatchIn('a' * 2049), isFalse);
    });
  });

  group('refusals', () {
    for (final (pattern, reason) in [
      ('(a)\\1', PatternRefusal.backReference),
      ('\\k<name>', PatternRefusal.backReference),
      ('a(?=b)', PatternRefusal.lookaround),
      ('a(?!b)', PatternRefusal.lookaround),
      ('(?<=a)b', PatternRefusal.lookaround),
      ('(?<!a)b', PatternRefusal.lookaround),
      ('\\bword\\b', PatternRefusal.wordBoundary),
      ('\\Bx', PatternRefusal.wordBoundary),
      ('\\p{L}', PatternRefusal.unicodeProperty),
      ('[\\P{L}]', PatternRefusal.unicodeProperty),
      ('(?i)abc', PatternRefusal.flags),
      ('a{101}', PatternRefusal.repeatTooBig),
      ('a{2,101}', PatternRefusal.repeatTooBig),
      ('a{3,2}', PatternRefusal.syntax),
      ('((a{100}){100}){100}', PatternRefusal.tooLarge),
      ('(a', PatternRefusal.syntax),
      ('a)', PatternRefusal.syntax),
      ('[abc', PatternRefusal.syntax),
      ('*a', PatternRefusal.syntax),
      ('a**', PatternRefusal.syntax),
      ('^*', PatternRefusal.syntax),
      ('[z-a]', PatternRefusal.syntax),
    ]) {
      test('$pattern is refused as ${reason.name}', () {
        expect(patternRefusal(pattern), reason);
        expect(compilePattern(pattern).program, isNull);
      });
    }

    test('a pattern over 256 characters is refused, and one of 256 is not', () {
      expect(patternRefusal('a' * 257), PatternRefusal.tooLong);
      expect(patternRefusal('a' * 256), isNull);
    });

    test('a refused pattern fills nowhere', () {
      expect(fillsOn(const WebsiteRule('(a)\\1', match: WebsiteMatch.regularExpression), 'aa'), isFalse);
    });

    test('a pattern the engine accepts is one it has a reason to refuse nowhere else', () {
      expect(patternRefusal('^https://([a-z]+\\.)?example\\.co/'), isNull);
      expect(patternRefusal('(a|b)*c{1,5}[0-9]\$'), isNull);
    });
  });

  group('time', () {
    // No wall-clock timing: the engine counts the states a search takes, and that is bounded
    for (final (pattern, text) in [
      ('(a+)+\$', '${'a' * 2000}!'),
      ('(a|a)*\$', '${'a' * 2000}!'),
      ('.*.*.*x', 'a' * 2000),
      ('(.*a){20}', 'a' * 2000),
      ('^(a?){100}a{100}\$', 'a' * 100),
    ]) {
      test('$pattern on ${text.length} characters stays under states x (length + 1)', () {
        final program = compilePattern(pattern).program!;

        final result = program.search(text);

        expect(result.steps, lessThanOrEqualTo(program.states * (text.length + 1)));
      });
    }

    test('(a+)+\$ does not match 2000 letters and a bang, and answers at once', () {
      final program = compilePattern('(a+)+\$').program!;

      expect(program.hasMatchIn('${'a' * 2000}!'), isFalse);
      expect(program.hasMatchIn('a' * 2000), isTrue);
    });
  });
}
