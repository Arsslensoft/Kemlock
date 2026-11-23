import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What the lock screen's own work covers, whose fields are not checked
/// here yet: the lock and setup screens, the Recovery Kit sheets and the
/// vaults sheet, as paths from `lib/`.
const _notYet = {'features/lock/', 'features/recovery/', 'features/settings/vaults_sheet.dart'};

/// The editors this branch added, as paths from `mobile/`.
const _editors = [
  'lib/features/cards/card_edit_sheet.dart',
  'lib/features/identities/identity_edit_sheet.dart',
  'lib/features/autofill/website_rule_fields.dart',
];

/// The arguments of each `TextField(` and `TextFormField(` call in [code],
/// from the paren that opens them to the one that closes them.
Iterable<String> textFieldCalls(String code) sync* {
  for (final match in RegExp(r'\bText(?:Form)?Field\(').allMatches(code)) {
    var depth = 0;
    for (var i = match.end - 1; i < code.length; i++) {
      if (code[i] == '(') depth++;
      if (code[i] == ')' && --depth == 0) {
        yield code.substring(match.end, i);
        break;
      }
    }
  }
}

/// The files under `lib/` with a field that lets the keyboard learn, as
/// paths from `lib/`, once for each such field.
List<String> filesWithLearningFields() {
  final found = <String>[];
  for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
    final path = file.path.replaceAll(r'\', '/').substring('lib/'.length);
    if (!path.endsWith('.dart') || _notYet.any((prefix) => path.startsWith(prefix))) continue;
    final code = file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
    for (final call in textFieldCalls(code)) {
      if (!call.contains('enableIMEPersonalizedLearning: false')) found.add(path);
    }
  }
  return found..sort();
}

void main() {
  // Gboard and the iPhone's keyboard learn the words typed in a field unless it says not to, and offer
  // them again in other apps: a note's text, a code's secret, a name searched for, a PIN.
  test('no field inside the vault lets the keyboard learn what is typed in it', () {
    expect(filesWithLearningFields(), isEmpty, reason: 'Give each of these fields enableIMEPersonalizedLearning: false.');
  });

  // The sheets of cards, identities and a login's websites, named so that the check can't pass by skipping them
  test('every field of the card, identity and website editors turns learning off', () {
    for (final path in _editors) {
      final calls = textFieldCalls(File(path).readAsStringSync()).toList();
      expect(calls, isNotEmpty, reason: path);
      expect(calls.where((call) => !call.contains('enableIMEPersonalizedLearning: false')), isEmpty, reason: path);
    }
  });

  test('the check finds the fields it looks at', () {
    expect(textFieldCalls(File('lib/features/notes/note_page.dart').readAsStringSync()), hasLength(2));
    // A login's name, username, password and note; its websites are in the website editor
    expect(textFieldCalls(File('lib/features/logins/login_edit_sheet.dart').readAsStringSync()), hasLength(4));
    // A website's address and the address to test a pattern on
    expect(textFieldCalls(File('lib/features/autofill/website_rule_fields.dart').readAsStringSync()), hasLength(2));
    // A card's name, cardholder, number, expiry, valid from, note, and its security code and PIN through one helper
    expect(textFieldCalls(File('lib/features/cards/card_edit_sheet.dart').readAsStringSync()), hasLength(7));
    expect(textFieldCalls(File('lib/features/identities/identity_edit_sheet.dart').readAsStringSync()), hasLength(8));
    expect(textFieldCalls('TextField(a: f(1), b: 2) _MyTextField(c) TextFormField(d)'), ['a: f(1), b: 2', 'd']);
  });
}
