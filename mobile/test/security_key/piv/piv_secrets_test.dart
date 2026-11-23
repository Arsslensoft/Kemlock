import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The PIV code: the protocol under `lib/security_key/piv/` and the sheets
/// under `lib/features/security_keys/` whose names start with `piv_`.
List<File> _pivFiles() => [
  ...Directory('lib/security_key/piv').listSync(recursive: true).whereType<File>(),
  ...Directory('lib/features/security_keys').listSync().whereType<File>().where((file) => file.uri.pathSegments.last.startsWith('piv_')),
].where((file) => file.path.endsWith('.dart')).toList();

/// Where a value would outlive the operation: a provider, the preferences,
/// a sealed value of the vault, or a log.
final _sinks = RegExp(
  r'\bref\.(read|watch|listen)\(|\bProvider\b|\bprefs?\b|\bPrefs\b|\bsaveEncryptedValue\(|\bprint\(|\bdebugPrint\(|\blog\(|\bdeveloper\.|\bLogger\b',
);

/// A name that holds a PIN, a PUK or a management key, and not something
/// said about one (its tries, whether it is blocked, its kind, its row).
final _secret = RegExp(r'\b_?\w*(?:pin|puk|managementkey|newkey|typedkey)\w*\b', caseSensitive: false);
final _aboutOne = RegExp(
  r'(tries|blocked|reference|type|kind|metadata|state|sheet|row|form|field|prompt|length|default|factory|source|found|label|title|'
  r'holds|verified|error|warning|wrong|message|text|policy|refused|note|lasttry|mismatch|spinner|pinned)',
  caseSensitive: false,
);

/// The statement the note of design decision 10 is saved with: the one
/// place a management key may go, into the open vault.
final _theNote = RegExp(r'\.(add|update|delete)\(');

/// Each statement of [source], on one line, with comments taken out.
List<String> _statements(String source) {
  final code = source.replaceAll(RegExp(r'//.*'), '').replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return [for (final statement in code.split(RegExp(r'[;{}]'))) statement.replaceAll(RegExp(r'\s+'), ' ').trim()];
}

/// The statements of [source] that hand a PIN, a PUK or a management key
/// to somewhere it would be kept or seen.
List<String> offendingStatements(String source) => [
  for (final statement in _statements(source))
    if (_sinks.hasMatch(statement) && !_theNote.hasMatch(statement))
      if (_secret.allMatches(statement).any((match) => !_aboutOne.hasMatch(match[0]!))) statement,
];

void main() {
  test('no PIN, PUK or management key goes to a provider, the preferences, a sealed value or a log', () {
    final files = _pivFiles();
    expect(files, isNotEmpty);
    final offending = [
      for (final file in files)
        for (final statement in offendingStatements(file.readAsStringSync())) '${file.path.replaceAll('\\', '/')}: $statement',
    ];
    expect(offending, isEmpty);
  });

  test('the check finds such a line, and lets the vault note and talk of the codes pass', () {
    expect(offendingStatements("debugPrint('PIN \$pin');"), hasLength(1));
    expect(offendingStatements('ref.read(prefsProvider).setString("x", hex(managementKey));'), hasLength(1));
    expect(offendingStatements('await store.saveEncryptedValue(session, "piv", newKey);'), hasLength(1));
    expect(offendingStatements('log(puk.toString());'), hasLength(1));
    expect(offendingStatements('await ref.read(pivNotesProvider).add(note);'), isEmpty);
    expect(offendingStatements('final tries = ref.watch(provider).pinTries;'), isEmpty);
    expect(offendingStatements('final pin = TextEditingController();'), isEmpty);
  });
}
