// The expiry sheet (openspec: add-pgp-key-editing, design decision 10), for
// a key and for one subkey, with the app's fixed clock (testNow).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_expiry_sheet.dart';
import 'package:kemlock/features/keys/key_sheet.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'keys_kit.dart';

/// GnuPG's key with a signing and an encryption subkey, all expiring on 2030-01-01.
const _key = 'gnupg/editing/signing-subkey.secret.asc';

void main() {
  String date(DateTime when) => DateFormat.yMMMd('en').format(when);
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(KeyExpirySheet), matching: finder);
  Finder save() => inSheet(find.text(t('keys.change.expiry.save')));
  crypto.PgpKeyInfo info(KeysApp keys) => crypto.readPgpKeyInfo(unb64(keys.key('k1').publicKey!));

  testWidgets('each choice shows its date, and "never" says the key does not expire', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    await keys.openChange('keys.change.expiry');

    final now = testNow;
    for (final (choice, years) in [(ExpiryChoice.oneYear, 1), (ExpiryChoice.twoYears, 2), (ExpiryChoice.fiveYears, 5)]) {
      final row = find.byKey(ValueKey('expiry-${choice.name}'));
      expect(find.descendant(of: row, matching: find.text(t(expiryChoiceLabelId(choice)))), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(date(DateTime(now.year + years, now.month, now.day)))), findsOneWidget);
    }
    expect(
      find.descendant(of: find.byKey(const ValueKey('expiry-never')), matching: find.text(t('keys.change.expiry.neverBody'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('expiry-onDate')), matching: find.text(t('keys.change.expiry.pickDate'))),
      findsOneWidget,
    );
    expect(inSheet(find.text(t('keys.change.expiry.alsoSubkeys'))), findsOneWidget);
  });

  testWidgets('a date that is not in the future is refused, and nothing is made', (tester) async {
    final keys = KeysApp(tester)..nextDate = testNow.subtract(const Duration(days: 1));
    await keys.openPgpKey(_key);
    await keys.openChange('keys.change.expiry');

    await keys.tap(find.byKey(const ValueKey('expiry-onDate')));

    expect(find.text(t('keys.change.expiry.notFuture')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.ancestor(of: save(), matching: find.byType(FilledButton))).onPressed, isNull);
    // A date ahead is taken
    keys.nextDate = DateTime(2031, 3, 1);
    await keys.tap(find.byKey(const ValueKey('expiry-onDate')));
    expect(find.text(t('keys.change.expiry.notFuture')), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('expiry-onDate')), matching: find.text(date(DateTime(2031, 3, 1)))),
      findsOneWidget,
    );
    expect(keys.changes, isEmpty);
  });

  testWidgets('"Also the subkeys" off changes the primary key only', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    final before = info(keys);
    await keys.openChange('keys.change.expiry');

    await keys.tap(inSheet(find.byType(AppSwitch)));
    await keys.tap(save());
    await keys.finishChange();

    final after = info(keys);
    expect(
      after.primary.expires,
      DateTime(testNow.year + 2, testNow.month, testNow.day, testNow.toLocal().hour, testNow.toLocal().minute).toUtc(),
    );
    expect(after.subkeys.map((s) => s.expires), before.subkeys.map((s) => s.expires));
  });

  testWidgets("a subkey's own sheet has no switch, and changes that subkey alone", (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    final before = info(keys);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('subkey-1')),
      200,
      scrollable: find.descendant(of: find.byType(KeySheet), matching: find.byType(Scrollable)).first,
    );
    await keys.tap(find.byKey(const ValueKey('subkey-1')));
    expect(inSheet(find.text(t('keys.change.expiry.subkeyTitle'))), findsOneWidget);
    expect(inSheet(find.text(t('keys.change.expiry.alsoSubkeys'))), findsNothing);
    await keys.tap(find.byKey(const ValueKey('expiry-never')));
    await keys.tap(save());
    await keys.finishChange();

    final after = info(keys);
    expect(after.primary.expires, before.primary.expires);
    expect(after.subkeys.map((s) => s.expires), [before.subkeys[0].expires, null]);
  });

  testWidgets('after Save the key sheet shows the new date and says to send the new public key, with Share', (tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    await keys.openChange('keys.change.expiry');

    await keys.tap(save());
    await keys.finishChange();

    expect(find.byType(KeyExpirySheet), findsNothing);
    expect(find.byType(KeySheet), findsOneWidget);
    final alert = find.byKey(const ValueKey('key-changed'));
    expect(find.descendant(of: alert, matching: find.text(t('keys.change.sendPublic'))), findsOneWidget);
    final expires = info(keys).primary.expires!;
    expect(find.descendant(of: find.byKey(const ValueKey('key-expiry')), matching: find.text(date(expires.toLocal()))), findsOneWidget);
    expect(find.text(t('keys.change.done.expiry')), findsOneWidget);

    await keys.tap(find.descendant(of: alert, matching: find.text(t('keys.change.sharePublic'))));
    final shared = keys.files.saved.single;
    expect((shared.name, shared.shared), ('Ada.pub.asc', true));
    expect(shared.bytes, isNotEmpty);
  });
}
