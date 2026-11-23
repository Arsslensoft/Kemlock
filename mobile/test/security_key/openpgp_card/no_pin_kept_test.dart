import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// No PIN, admin PIN or reset code of a card may outlive the operation it
// was typed for (openspec: add-openpgp-card, "The vault holds no secret
// of a card key"). This reads the code that handles them and fails when
// a statement hands one to what keeps or tells things: a provider, the
// preferences, the encrypted store, the key-value store or a log.

/// Where something kept would outlive its operation.
final _sink = RegExp(
  r'\bref\s*\.\s*(read|watch|listen)\b|\bstate\s*=|\boverrideWith\w*|\bPrefs\w*\b|\bprefsProvider\b|\bsaveEncryptedValue\b'
  r'|\bsetItem\b|\b(print|debugPrint|debugPrintStack|log)\s*\(|\bdeveloper\s*\.\s*log\b|\bLogger\b',
);

/// The names the code gives a PIN's value.
final _secret = RegExp(r'\b_?(pin|pins|newPin|currentPin|nextPin|typedPin|adminPin|resetCode|pinBytes|heldPin)\b');

/// [source] with comments taken out, and every string literal reduced to
/// the interpolations in it, which may well carry a PIN.
String _code(String source) {
  final withoutComments = source.replaceAll(RegExp(r'//[^\n]*'), '').replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutComments
      .replaceAllMapped(
        RegExp(
          r"'(?:[^'\\\n]|\\.)*'|"
          r'"(?:[^"\\\n]|\\.)*"',
        ),
        (match) {
          final literal = match[0]!;
          return RegExp(r'\$\{[^}]*\}|\$\w+').allMatches(literal).map((m) => m[0]!).join(' ');
        },
      )
      // Which PIN a command is about, by its name, is no secret
      .replaceAll(RegExp(r'\bCardPin\s*\.\s*\w+'), 'CardPin');
}

/// The statements of [source] that hand a PIN to a sink.
List<String> offendingStatements(String source) => [
  for (final statement in _code(source).split(';'))
    if (_sink.hasMatch(statement) && _secret.hasMatch(statement)) statement.trim().replaceAll(RegExp(r'\s+'), ' '),
];

Iterable<File> _dartFiles(String folder) {
  final directory = Directory(folder);
  if (!directory.existsSync()) return const [];
  return directory.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'));
}

void main() {
  test('no PIN of a card is handed to a provider, the preferences, the stores or a log', () {
    final files = [..._dartFiles('lib/security_key/openpgp_card'), ..._dartFiles('lib/features/security_keys')];
    expect(files, isNotEmpty);

    final offending = [
      for (final file in files)
        for (final statement in offendingStatements(file.readAsStringSync())) '${file.path.replaceAll('\\', '/')}: $statement',
    ];

    expect(offending, isEmpty);
  });

  test('the check catches such a statement, and lets the usual ones be', () {
    expect(offendingStatements('ref.read(lastPinProvider.notifier).state = pin;'), hasLength(1));
    expect(offendingStatements("debugPrint('the PIN was \$pin');"), hasLength(1));
    expect(offendingStatements("await store.saveEncryptedValue(\n  'card',\n  {'admin': adminPin},\n  session,\n);"), hasLength(1));
    expect(offendingStatements('ref.read(prefsProvider.notifier).update(Prefs(pinNote: resetCode));'), hasLength(1));
    expect(offendingStatements('log(newPin.toString());'), hasLength(1));

    expect(offendingStatements('final keys = ref.read(securityKeysProvider);\nsession.holdPin(CardPin.pin, pin);'), isEmpty);
    expect(offendingStatements("showToast(context, context.t('securityKeys.pin.wrong'));"), isEmpty);
    expect(offendingStatements('final theme = ref.watch(themeProvider); // keeps the pin out'), isEmpty);
    expect(offendingStatements("debugPrint('\${controller.pin} was refused');"), hasLength(1));
  });
}
