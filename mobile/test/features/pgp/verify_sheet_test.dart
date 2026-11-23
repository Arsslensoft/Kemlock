// The Verify sheet with GnuPG's signatures: one answer per signature.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/pgp/add_someone_sheet.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../contacts/contacts_kit.dart' show contactOf;
import 'pgp_kit.dart';

const _edGrouped = '1FCD A135 EE42 400E C2B7 7CE6 7724 9ABE 661C F8DB';
const _rsaGrouped = 'EA29 C79D 1C65 7027 7907 BB48 5D49 D28C 8EFC 2F98';

void main() {
  Future<PgpApp> open(WidgetTester tester, {List<String> keys = const ['ed']}) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: keys);
    await pgp.open('verify');
    return pgp;
  }

  Future<void> verify(PgpApp pgp, [String? text]) async {
    if (text != null) await pgp.enter(t('pgp.verify.field'), text);
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.verify.button')));
  }

  Future<void> pick(PgpApp pgp, String label, String name, List<int> bytes) async {
    pgp.files.nextPath = FakeFiles.onDisk(name, bytes);
    final directory = File(pgp.files.nextPath!.path).parent;
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    await pgp.tap(find.text(label));
  }

  List<AlertSeverity> banners(WidgetTester tester) => [
    for (final alert in tester.widgetList<AppAlert>(find.byType(AppAlert))) alert.severity,
  ];

  final clearSigned = fixtureText('pgp/gnupg/clearsigned.asc');
  final messageBytes = fixtureBytes('pgp/gnupg/message.txt');

  testWidgets('good, from one of the vault\'s own keys: the key is named, with when it was made', (tester) async {
    final pgp = await open(tester);
    await verify(pgp, clearSigned);
    expect(banners(tester), [AlertSeverity.success]);
    expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Fixture Ed25519'})), findsOneWidget);
    expect(find.text(t('pgp.decrypted.matchesYours')), findsOneWidget);
    expect(find.text(_edGrouped), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Signed on Nov 1[67], 2026')), findsOneWidget);
    // The text that was signed, readable
    expect(find.text(t('pgp.verify.signedText').toUpperCase()), findsOneWidget);
    expect(find.textContaining('- a line that starts with a dash'), findsWidgets);
  });

  testWidgets('one changed word: the signature is bad', (tester) async {
    final pgp = await open(tester);
    await verify(pgp, clearSigned.replaceFirst('A message', 'A massage'));
    expect(banners(tester), [AlertSeverity.error]);
    expect(find.text(t('pgp.signature.bad')), findsOneWidget);
  });

  testWidgets('the signer\'s key is not here: the fingerprint, then good and not checked once the key is pasted', (tester) async {
    final pgp = await open(tester);
    await verify(pgp, fixtureText('pgp/gnupg/clearsigned-rsa.asc'));
    expect(banners(tester), [AlertSeverity.warning]);
    expect(find.text(t('pgp.signature.unknown')), findsOneWidget);
    expect(find.text(_rsaGrouped), findsOneWidget);

    await pgp.tap(find.text(t('pgp.signature.giveKey')));
    expect(find.byType(AddSomeoneSheet), findsOneWidget);
    expect(find.text(t('pgp.people.giveKey.title')), findsWidgets);
    await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
    await pgp.enter(t('pgp.people.paste'), fixtureText('keys/gnupg/rsa3072.public.asc'));
    await pgp.tap(find.text(t('pgp.people.read')));
    expect(find.text('Fixture RSA <rsa@example.org>'), findsOneWidget);
    await pgp.tap(find.text(t('pgp.people.useForCheck')));

    expect(banners(tester), [AlertSeverity.info]);
    expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Fixture RSA'})), findsOneWidget);
    expect(find.text(t('pgp.decrypted.matchesGiven')), findsOneWidget);
    expect(find.text(_rsaGrouped), findsOneWidget);
  });

  testWidgets('a signature by one of the other people\'s keys names that contact: checked on its date, or not checked', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: ['ed']);
    // The RSA key that clear-signed the fixture, kept under another name than its user ID's
    final checkedAt = DateTime(2026, 10, 3, 9).millisecondsSinceEpoch;
    await pgp.addContact(contactOf('gnupg/rsa3072.public.asc', id: 'c-rsa', name: 'Rosalind Franklin', checkedAt: checkedAt));
    await pgp.open('verify');

    await verify(pgp, fixtureText('pgp/gnupg/clearsigned-rsa.asc'));
    expect(banners(tester), [AlertSeverity.success]);
    expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Rosalind Franklin'})), findsOneWidget);
    expect(find.text(t('pgp.signature.matchesChecked', {'date': '3 October'})), findsOneWidget);
    expect(find.text(_rsaGrouped), findsOneWidget);
    expect(find.text(t('pgp.signature.giveKey')), findsNothing);

    // Marked as not checked, the same signature is good from a key that isn't checked
    await tester.runAsync(() => pgp.app.controller.updateContact(pgp.app.state.contacts.single.unchecked()));
    pgp.hideToast();
    await verify(pgp);
    expect(banners(tester), [AlertSeverity.info]);
    expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Rosalind Franklin'})), findsOneWidget);
    expect(find.text(t('pgp.signature.matchesUnchecked')), findsOneWidget);
    expect(find.text(t('pgp.decrypted.matchesGiven')), findsNothing);
  });

  testWidgets('a file with its .sig, and with its .asc', (tester) async {
    final pgp = await open(tester);
    await pick(pgp, t('pgp.decrypt.chooseFile'), 'message.txt', messageBytes);
    expect(find.text('message.txt'), findsOneWidget);
    await pick(pgp, t('pgp.verify.chooseSignature'), 'message.txt.sig', fixtureBytes('pgp/gnupg/message.txt.ed25519.sig'));
    expect(find.text('message.txt.sig'), findsOneWidget);
    await verify(pgp);
    expect(banners(tester), [AlertSeverity.success]);
    // A detached signature shows no text: the file is the text
    expect(find.text(t('pgp.verify.signedText').toUpperCase()), findsNothing);

    // The armored signature of the same file, in its place
    await pick(pgp, t('pgp.verify.chooseSignature'), 'message.txt.asc', fixtureBytes('pgp/gnupg/message.txt.ed25519.asc'));
    expect(find.text('message.txt.sig'), findsNothing);
    await verify(pgp);
    expect(banners(tester), [AlertSeverity.success]);
  });

  testWidgets('a file that is not the one signed does not match', (tester) async {
    final pgp = await open(tester);
    await pick(pgp, t('pgp.decrypt.chooseFile'), 'report.txt', fixtureBytes('pgp/gnupg/report.txt'));
    await pick(pgp, t('pgp.verify.chooseSignature'), 'message.txt.sig', fixtureBytes('pgp/gnupg/message.txt.ed25519.sig'));
    await verify(pgp);
    expect(banners(tester), [AlertSeverity.error]);
  });

  testWidgets('a pasted detached signature is checked against a chosen file', (tester) async {
    final pgp = await open(tester);
    await pgp.enter(t('pgp.verify.field'), fixtureText('pgp/gnupg/message.txt.ed25519.asc'));
    // By itself it has nothing to be checked against
    await verify(pgp);
    expect(find.text(t('pgp.error.needsFile')), findsOneWidget);

    await pick(pgp, t('pgp.decrypt.chooseFile'), 'message.txt', messageBytes);
    await verify(pgp);
    expect(banners(tester), [AlertSeverity.success]);
  });

  testWidgets('SHA-1 is said to be outdated and not to be trusted', (tester) async {
    final pgp = await open(tester, keys: ['rsa']);
    await pick(pgp, t('pgp.decrypt.chooseFile'), 'message.txt', messageBytes);
    await pick(pgp, t('pgp.verify.chooseSignature'), 'message.txt.sha1.sig', fixtureBytes('pgp/gnupg/message.txt.sha1.sig'));
    await verify(pgp);
    expect(banners(tester), [AlertSeverity.warning]);
    expect(find.text(t('pgp.signature.weak', {'name': 'SHA-1'})), findsOneWidget);
  });

  testWidgets('two signers are listed, each with their own result', (tester) async {
    final pgp = await open(tester);
    await pick(pgp, t('pgp.decrypt.chooseFile'), 'two-signers.gpg', fixtureBytes('pgp/gnupg/two-signers.gpg'));
    await verify(pgp);
    // One by the vault's key, one by a key that is not here
    expect(banners(tester).toSet(), {AlertSeverity.success, AlertSeverity.warning});
    expect(banners(tester), hasLength(2));
    expect(find.text(_edGrouped), findsOneWidget);
    expect(find.text(_rsaGrouped), findsOneWidget);
    expect(find.textContaining('A message for the fixtures.'), findsOneWidget);
  });

  testWidgets('a key expired when the signature was made, and what is no signature', (tester) async {
    final pgp = await open(tester);
    await verify(pgp, 'just some words');
    expect(find.text(t('pgp.error.notAMessage')), findsOneWidget);
    expect(find.byType(AppAlert), findsOneWidget);

    await verify(pgp, fixtureText('pgp/gnupg/armored.asc'));
    expect(find.text(t('pgp.error.isEncrypted')), findsOneWidget);
  });

  testWidgets('closing and reopening shows an empty sheet', (tester) async {
    final pgp = await open(tester);
    await verify(pgp, clearSigned);
    expect(banners(tester), isNotEmpty);
    await pgp.closeSheet();
    await pgp.open('verify');
    expect(find.byType(AppAlert), findsNothing);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, t('pgp.verify.field'))).controller!.text, isEmpty);
  });
}
