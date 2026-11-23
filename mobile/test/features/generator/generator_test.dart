import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/generator/generator.dart';
import 'package:kemlock/features/generator/password_rules.dart';
import 'package:kemlock/features/generator/word_list.dart';

const _casesPath = 'test/fixtures/generator/cases.json';

/// The cases the shared fixture holds: what each is made from. Their bytes
/// and expected passwords are written once (WRITE_GENERATOR_CASES=1) and then
/// only read, by these tests and the Kotlin and Swift ones.
const _inputs = <Map<String, Object?>>[
  {'name': 'the defaults', 'kind': 'random', 'choices': <String, Object?>{}},
  {
    'name': 'eight characters, no symbols',
    'kind': 'random',
    'choices': {'length': 8, 'symbols': false},
  },
  {
    'name': 'sixty-four characters, look-alikes allowed',
    'kind': 'random',
    'choices': {'length': 64, 'avoidLookAlikes': false},
  },
  {
    'name': 'small letters only',
    'kind': 'random',
    'choices': {'capitals': false, 'digits': false, 'symbols': false},
  },
  {
    'name': 'a site that limits the length',
    'kind': 'random',
    'choices': <String, Object?>{},
    'rules': 'minlength: 8; maxlength: 16; required: lower; required: upper; required: digit',
  },
  {
    'name': 'a site that requires its own symbols and no runs',
    'kind': 'random',
    'choices': {'symbols': false},
    'rules': 'required: lower; required: upper; required: digit; required: [-().&@?\'#,/"+]; max-consecutive: 2',
  },
  {'name': 'a site that refuses symbols', 'kind': 'random', 'choices': <String, Object?>{}, 'rules': 'allowed: lower, upper, digit'},
  {'name': 'rules that contradict each other', 'kind': 'random', 'choices': <String, Object?>{}, 'rules': 'minlength: 30; maxlength: 12'},
  {
    'name': 'a custom set holding a bracket',
    'kind': 'random',
    'choices': {'length': 12},
    'rules': 'required: []-]; required: lower; minlength: 10',
  },
  {'name': 'a passphrase', 'kind': 'passphrase', 'choices': <String, Object?>{}},
  {
    'name': 'a passphrase with capitals, a digit and spaces',
    'kind': 'passphrase',
    'choices': {'words': 7, 'separator': ' ', 'capitalise': true, 'digit': true},
  },
];

String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
List<int> _unhex(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

String _make(Map<String, Object?> input, ByteSource source, List<String> words) {
  final choices = input['choices']! as Map<String, Object?>;
  if (input['kind'] == 'passphrase') return generatePassphrase(source, words, PassphraseChoices.fromJson(choices));
  final rules = input['rules'] as String?;
  return generatePassword(source, PasswordChoices.fromJson(choices), rules == null ? null : PasswordRules.parse(rules));
}

void main() {
  final words = parseWordList(File(effWordListAsset).readAsStringSync());

  test('writes the shared cases once', () {
    final random = Random.secure();
    final cases = [
      for (final input in _inputs)
        () {
          final bytes = List.generate(768, (_) => random.nextInt(256));
          return {...input, 'bytes': _hex(bytes), 'password': _make(input, FixedByteSource(bytes), words)};
        }(),
    ];
    File(_casesPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({'about': 'Generator cases, written once by generator_test.dart (openspec: add-passwords, design decision 5). Never regenerate: the Dart, Kotlin and Swift generators must each make every password here from its choices, rules and bytes.', 'cases': cases})}\n',
      );
  }, skip: Platform.environment['WRITE_GENERATOR_CASES'] != '1');

  group('the shared cases', () {
    final file = File(_casesPath);
    final cases = file.existsSync() ? ((jsonDecode(file.readAsStringSync()) as Map<String, Object?>)['cases']! as List<Object?>) : const [];

    test('are all there', () => expect(cases, hasLength(_inputs.length)));

    for (final raw in cases) {
      final c = raw! as Map<String, Object?>;
      test('${c['name']}', () {
        expect(_make(c, FixedByteSource(_unhex(c['bytes']! as String)), words), c['password']);
      });
    }
  });

  group('random passwords', () {
    String make(PasswordChoices choices, [String? rules]) =>
        generatePassword(SecureByteSource(), choices, rules == null ? null : PasswordRules.parse(rules));

    test('the defaults: 20 characters, one of each set, no look-alikes', () {
      for (var i = 0; i < 200; i++) {
        final password = make(const PasswordChoices());
        expect(password, hasLength(20));
        expect(password, contains(RegExp('[a-z]')));
        expect(password, contains(RegExp('[A-Z]')));
        expect(password, contains(RegExp('[0-9]')));
        expect(password, contains(RegExp('[!#%&_?-]')));
        expect(password, isNot(contains(RegExp('[0O1lI]'))));
      }
    });

    test('leaves out a set that is off, and keeps one of each that is on at the shortest length', () {
      for (var i = 0; i < 200; i++) {
        expect(make(const PasswordChoices(digits: false)), isNot(contains(RegExp('[0-9]'))));
        final short = make(const PasswordChoices(length: 8));
        expect(short, hasLength(8));
        for (final set in ['[a-z]', '[A-Z]', '[0-9]', '[!#%&_?-]']) {
          expect(short, contains(RegExp(set)), reason: set);
        }
      }
    });

    test('may use look-alikes once allowed', () {
      final all = List.generate(300, (_) => make(const PasswordChoices(length: 64, avoidLookAlikes: false))).join();
      expect(all, contains(RegExp('[0O1lI]')));
    });

    test('follows a site that limits the length', () {
      final password = make(const PasswordChoices(), 'minlength: 8; maxlength: 16; required: lower; required: upper; required: digit');
      expect(password, hasLength(16));
      expect(password, isNot(contains(RegExp('[^A-Za-z0-9]'))));
    });

    test('follows a site that refuses symbols, though Symbols is on', () {
      expect(make(const PasswordChoices(), 'allowed: lower, upper, digit'), isNot(contains(RegExp('[^A-Za-z0-9]'))));
    });

    test('takes a digit a site requires, though Digits is off', () {
      expect(make(const PasswordChoices(digits: false), 'required: digit; allowed: lower'), contains(RegExp('[0-9]')));
    });

    test('ignores rules that contradict each other', () {
      expect(make(const PasswordChoices(), 'minlength: 30; maxlength: 12'), hasLength(20));
    });

    test('keeps runs within the most a site allows', () {
      for (var i = 0; i < 300; i++) {
        final password = make(const PasswordChoices(length: 32, capitals: false, digits: false, symbols: false), 'max-consecutive: 1');
        for (var j = 1; j < password.length; j++) {
          expect(password[j], isNot(password[j - 1]));
        }
      }
    });

    test('gives every character the same chance', () {
      const choices = PasswordChoices();
      final alphabet = passwordPlan(choices).alphabet;
      final counts = <String, int>{for (final c in alphabet.split('')) c: 0};
      const n = 100000;
      for (var i = 0; i < n; i++) {
        for (final c in make(choices).split('')) {
          counts[c] = counts[c]! + 1;
        }
      }
      // The required characters lean their sets a little; each set's characters among themselves are even
      for (final set in passwordPlan(choices).required) {
        final inSet = [for (final c in set.split('')) counts[c]!];
        final mean = inSet.reduce((a, b) => a + b) / inSet.length;
        for (final count in inSet) {
          expect((count - mean).abs(), lessThan(6 * sqrt(mean)), reason: set);
        }
      }
    });
  });

  group('passphrases', () {
    test('the bundled list has 7,776 words, each once', () {
      expect(words, hasLength(7776));
      expect(words.toSet(), hasLength(7776));
    });

    test('five words from the list, joined by dashes, by default', () {
      final phrase = generatePassphrase(SecureByteSource(), words, const PassphraseChoices());
      final parts = phrase.split('-');
      expect(parts, hasLength(5));
      expect(parts.every(words.contains), isTrue);
    });

    test('capitals and a digit when asked', () {
      final phrase = generatePassphrase(SecureByteSource(), words, const PassphraseChoices(capitalise: true, digit: true));
      final parts = phrase.split('-');
      expect(parts.every((word) => word[0] == word[0].toUpperCase()), isTrue);
      expect(RegExp(r'\d').allMatches(phrase), hasLength(1));
    });
  });

  group('password rules', () {
    test('reads lengths, required sets, allowed sets and runs', () {
      final rules = PasswordRules.parse(
        'minlength: 8; maxlength: 16; required: lower, upper; required: [-_]; allowed: digit; max-consecutive: 2;',
      );
      expect((rules.minLength, rules.maxLength, rules.maxConsecutive), (8, 16, 2));
      expect(rules.required, ['$lowerChars$upperChars', '-_']);
      expect(rules.allowed, digitChars);
    });

    test('reads a set holding a semicolon or a bracket', () {
      expect(PasswordRules.parse('required: [;]; minlength: 9').required, [';']);
      expect(PasswordRules.parse('required: []-]').required, [']-']);
      expect(PasswordRules.parse('required: [;]; minlength: 9').minLength, 9);
    });

    test('skips what it doesn’t know', () {
      expect(PasswordRules.parse('nonsense; colour: blue').isEmpty, isTrue);
    });

    test('takes any whitespace between classes, and a set never closed', () {
      expect(PasswordRules.parse('required: lower,\tdigit').required, [lowerChars + digitChars]);
      expect(PasswordRules.parse('required: upper\ndigit').required, [upperChars + digitChars]);
      expect(PasswordRules.parse('allowed: [').allowed, '');
      expect(PasswordRules.parse('allowed: [ab').allowed, 'ab');
    });
  });
}
