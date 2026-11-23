// The user ID sheet (openspec: add-pgp-key-editing, design decision 10).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_sheet.dart';
import 'package:kemlock/features/keys/key_user_id_sheet.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'keys_kit.dart';

const _key = 'gnupg/editing/signing-subkey.secret.asc';

void main() {
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(KeyUserIdSheet), matching: finder);
  Finder add() => inSheet(find.text(t('keys.change.userId.add')));
  Finder field(String id) => inSheet(find.widgetWithText(TextField, t(id)));

  Future<KeysApp> open(WidgetTester tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    await keys.openChange('keys.change.addUserId');
    return keys;
  }

  testWidgets('both fields are needed, with the generate sheet\'s errors', (tester) async {
    final keys = await open(tester);

    await keys.tap(add());

    expect(find.text(t('keys.generate.pgp.nameMissing')), findsOneWidget);
    expect(find.text(t('keys.generate.pgp.emailMissing')), findsOneWidget);
    await tester.enterText(field('keys.generate.pgp.name'), 'Ada');
    await tester.pump();
    expect(find.text(t('keys.generate.pgp.nameMissing')), findsNothing);
    expect(keys.changes, isEmpty);
  });

  testWidgets('a user ID the key has is refused under the form', (tester) async {
    final keys = await open(tester);

    await tester.enterText(field('keys.generate.pgp.name'), ' Fixture Signing ');
    await tester.enterText(field('keys.generate.pgp.email'), 'signing@example.org');
    await tester.pump();

    expect(find.text(t('keys.change.userId.duplicate')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.ancestor(of: add(), matching: find.byType(FilledButton))).onPressed, isNull);
    expect(keys.changes, isEmpty);
  });

  testWidgets('the new user ID is listed afterwards, first when it is made the main one', (tester) async {
    final keys = await open(tester);

    await tester.enterText(field('keys.generate.pgp.name'), 'Ada Lovelace');
    await tester.enterText(field('keys.generate.pgp.email'), 'ada@work.example');
    await keys.tap(inSheet(find.byType(AppSwitch)));
    await keys.tap(add());
    await keys.finishChange();

    expect(find.byType(KeyUserIdSheet), findsNothing);
    expect(find.text(t('keys.change.done.userId')), findsOneWidget);
    final info = crypto.readPgpKeyInfo(unb64(keys.key('k1').publicKey!));
    expect(info.userIds, ['Fixture Signing <signing@example.org>', 'Ada Lovelace <ada@work.example>']);
    expect(info.mainUserId, 'Ada Lovelace <ada@work.example>');
    final listed = [
      for (final text in tester.widgetList<Text>(find.descendant(of: find.byType(KeySheet), matching: find.byType(Text))))
        if (text.data != null && text.data!.contains('<')) text.data!,
    ];
    expect(listed.take(2), ['Ada Lovelace <ada@work.example>', 'Fixture Signing <signing@example.org>']);
    expect(find.byKey(const ValueKey('key-changed')), findsOneWidget);
  });
}
