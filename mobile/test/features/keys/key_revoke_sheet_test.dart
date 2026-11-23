// The revocation sheet (openspec: add-pgp-key-editing, design decision
// 10): making a certificate, applying one, revoking at once.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_revoke_sheet.dart';
import 'package:kemlock/features/keys/key_sheet.dart';

import '../../fakes/fake_clipboard.dart';
import '../../helpers/test_app.dart';
import 'keys_kit.dart';

const _key = 'gnupg/editing/signing-subkey.secret.asc';

String _certificate(String name) => File('test/fixtures/keys/gnupg/editing/$name.rev').readAsStringSync();

void main() {
  Finder inSheet(Finder finder) => find.descendant(of: find.byType(KeyRevokeSheet), matching: finder);
  bool revoked(KeysApp keys) => crypto.readPgpKeyInfo(unb64(keys.key('k1').publicKey!)).primary.revoked;

  Future<KeysApp> open(WidgetTester tester) async {
    final keys = KeysApp(tester);
    await keys.openPgpKey(_key);
    await keys.openChange('keys.change.revoke');
    return keys;
  }

  Future<void> apply(KeysApp keys, String text) async {
    await keys.tap(inSheet(find.text(t('keys.change.revoke.apply'))));
    await keys.tester.enterText(inSheet(find.widgetWithText(TextField, t('keys.change.revoke.paste'))), text);
    await keys.tap(inSheet(find.text(t('keys.change.revoke.applyButton'))));
    await keys.finishChange();
  }

  testWidgets('making a certificate leaves the key unrevoked, and offers Save, Share and Copy', (tester) async {
    final copied = <String>[];
    answerSensitiveCopies(copied.add);
    final keys = await open(tester);
    await keys.tap(inSheet(find.text(t('keys.change.revoke.reason.none'))));
    await keys.tap(find.text(t('keys.change.revoke.reason.retired')).last);

    await keys.tap(inSheet(find.text(t('keys.change.revoke.make'))));

    final shown = tester.widget<Text>(find.byKey(const ValueKey('revocation-certificate'))).data!;
    expect(
      shown,
      startsWith('-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: Revocation certificate for E770227F48E661EAF271EAA7F92D39E6751913DD'),
    );
    expect(keys.changes, isEmpty);
    expect(revoked(keys), isFalse);
    expect(find.text(t('keys.change.revoke.warning')), findsOneWidget);

    await keys.tap(inSheet(find.text(t('notes.copy.save'))));
    await keys.tap(inSheet(find.text(t('notes.copy.share'))));
    await keys.tap(inSheet(find.text(t('keys.public.copy'))));
    expect(keys.files.saved.map((file) => (file.name, file.shared)), [('Ada.rev.asc', false), ('Ada.rev.asc', true)]);
    expect(utf8.decode(keys.files.saved.first.bytes), shown);
    expect(copied, [shown]);
    // It applies to its key, with the reason chosen
    final applied = await tester.runAsync(
      () => crypto.makeKey(
        crypto.PgpChangeRequest(unb64(keys.key('k1').privateKey), crypto.ApplyPgpRevocation(utf8.encode(shown)), now: testNow),
      ),
    );
    expect(applied!.pgp!.primary.revoked, isTrue);
  });

  testWidgets("applying GnuPG's certificate revokes the key, whose sheet then offers no change", (tester) async {
    final keys = await open(tester);

    await apply(keys, _certificate('signing-subkey'));

    expect(revoked(keys), isTrue);
    expect(find.byType(KeyRevokeSheet), findsNothing);
    expect(find.text(t('keys.change.done.revoked')), findsOneWidget);
    expect(find.descendant(of: find.byType(KeySheet), matching: find.text(t('keys.change.blocked.revoked'))), findsOneWidget);
    expect(find.byKey(const ValueKey('key-change')), findsNothing);
  });

  testWidgets('a certificate for another key, and a damaged one, each say so and change nothing', (tester) async {
    final keys = await open(tester);
    final before = keys.key('k1');

    await apply(keys, _certificate('rsa3072-expiring'));
    expect(
      find.descendant(of: find.byKey(const ValueKey('apply-error')), matching: find.text(t('keys.change.revoke.error.otherKey'))),
      findsOneWidget,
    );
    expect(keys.key('k1'), before);

    // A letter of the signature itself changed
    final damaged = _certificate('signing-subkey').replaceFirst('078sVnZqX6tccjOd', '078sVnZqX6tccjOe');
    await tester.enterText(inSheet(find.widgetWithText(TextField, t('keys.change.revoke.paste'))), damaged);
    await keys.tap(inSheet(find.text(t('keys.change.revoke.applyButton'))));
    await keys.finishChange();
    expect(
      find.descendant(of: find.byKey(const ValueKey('apply-error')), matching: find.text(t('keys.change.revoke.error.damaged'))),
      findsOneWidget,
    );
    expect(keys.key('k1'), before);
    expect(find.byType(KeyRevokeSheet), findsOneWidget);
  });

  testWidgets('"Revoke this key now" asks first: cancelled, nothing changes; confirmed, the key is revoked', (tester) async {
    final keys = await open(tester);

    await keys.tap(inSheet(find.text(t('keys.change.revoke.now'))));
    expect(find.text(t('keys.change.revoke.confirm.title', {'name': 'Ada'})), findsOneWidget);
    await keys.tap(keys.dialogButton('export.cancel'));
    expect(keys.changes, isEmpty);
    expect(revoked(keys), isFalse);

    await keys.tap(inSheet(find.text(t('keys.change.revoke.now'))));
    await keys.tap(keys.dialogButton('keys.change.revoke.confirm.button'));
    expect((keys.changes.single.request as crypto.PgpChangeRequest).change, isA<crypto.RevokePgpKey>());
    await keys.finishChange();
    expect(revoked(keys), isTrue);
  });
}
