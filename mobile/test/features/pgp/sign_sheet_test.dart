// The Sign sheet: clear-signed text for a message, a detached signature
// for a file, and the keys that may not sign saying why.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as openpgp;
import 'package:kemlock/features/pgp/sign_sheet.dart';
import 'package:kemlock/features/vault/add_to_vault_sheet.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import 'pgp_kit.dart';

Future<openpgp.PgpVerified> _verify(WidgetTester tester, Uint8List signed, String key, {Uint8List? data}) async {
  final public = (await tester.runAsync(() => crypto.readPrivateKey(fixtureBytes(fixtureKeys[key]!.$1))))!.public!;
  return (await tester.runAsync(
    () => openpgp.verify(
      signed: openpgp.PgpData.bytes(signed),
      data: data == null ? null : openpgp.PgpData.bytes(data),
      verifiers: [public],
      now: testNow,
    ),
  ))!;
}

void main() {
  Future<PgpApp> open(WidgetTester tester, {List<String> keys = const ['ed']}) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: keys);
    await pgp.open('sign');
    return pgp;
  }

  testWidgets('a message is shared as clear-signed text that stays readable and verifies', (tester) async {
    final pgp = await open(tester);
    await pgp.enter(t('pgp.sign.message'), 'hello');
    await pgp.tap(find.text(t('pgp.sign.button')));

    final shared = pgp.files.sharedTexts.single;
    expect(shared, startsWith('-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nhello\n-----BEGIN PGP SIGNATURE-----\n'));
    final verified = await _verify(tester, Uint8List.fromList(utf8.encode(shared)), 'ed');
    expect(verified.signatures.single.verdict, openpgp.SignatureVerdict.good);
    expect(verified.signatures.single.made, testNow, reason: 'signed at the app\'s clock');
    expect(utf8.decode(verified.content!), 'hello');

    // It can be shared again, and a changed message is signed afresh
    await pgp.tap(find.text(t('pgp.encrypt.shareAgain')));
    expect(pgp.files.sharedTexts, hasLength(2));
    expect(pgp.requests, hasLength(1));
  });

  testWidgets('lines that start with a dash and lines that end in spaces survive', (tester) async {
    final pgp = await open(tester);
    const text = '- a list\n-- \ntrailing spaces   \nFrom here';
    await pgp.enter(t('pgp.sign.message'), text);
    await pgp.tap(find.text(t('pgp.sign.button')));
    final shared = pgp.files.sharedTexts.single;
    expect(shared, contains('\n- - a list\n- -- \ntrailing spaces   \n- From here\n'));
    final verified = await _verify(tester, Uint8List.fromList(utf8.encode(shared)), 'ed');
    expect(verified.signatures.single.verdict, openpgp.SignatureVerdict.good);
    expect(utf8.decode(verified.content!), text);
  });

  testWidgets('a file gives <name>.sig that verifies against the file, whose bytes are unchanged', (tester) async {
    final pgp = await open(tester, keys: ['rsa']);
    final content = Uint8List.fromList(List.generate(50000, (i) => i * 13 & 0xff));
    pgp.files.nextPath = FakeFiles.onDisk('report.pdf', content);
    final picked = File(pgp.files.nextPath!.path);
    final before = picked.readAsBytesSync();
    addTearDown(() {
      if (picked.parent.existsSync()) picked.parent.deleteSync(recursive: true);
    });
    await pgp.tap(find.text(t('pgp.encrypt.chooseFile')));
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.widgetWithText(TextField, t('pgp.sign.message')), findsNothing);

    await pgp.tap(find.text(t('pgp.sign.button')));
    final shared = pgp.files.saved.single;
    expect((shared.name, shared.shared, shared.mimeType), ('report.pdf.sig', true, 'application/pgp-signature'));
    expect(pgp.files.sharedTexts, isEmpty);
    expect(before, content, reason: 'the file itself was only read');

    final verified = await _verify(tester, shared.bytes, 'rsa', data: content);
    expect(verified.signatures.single.verdict, openpgp.SignatureVerdict.good);
    // One changed byte of the file, and it no longer matches
    final changed = Uint8List.fromList(content)..[100] ^= 1;
    expect((await _verify(tester, shared.bytes, 'rsa', data: changed)).signatures.single.verdict, openpgp.SignatureVerdict.bad);
  });

  testWidgets('with several keys, "Sign as" chooses which', (tester) async {
    final pgp = await open(tester, keys: ['ed', 'rsa']);
    expect(inSheet<SignSheet>(find.text('Fixture Ed25519')), findsOneWidget);
    await pgp.tap(find.text(t('pgp.sign.signAs')));
    await pgp.tap(find.byKey(const ValueKey('signer:pgp-rsa')));
    expect(inSheet<SignSheet>(find.text('Fixture RSA')), findsOneWidget);

    await pgp.enter(t('pgp.sign.message'), 'by the RSA key');
    await pgp.tap(find.text(t('pgp.sign.button')));
    final signed = Uint8List.fromList(utf8.encode(pgp.files.sharedTexts.single));
    expect((await _verify(tester, signed, 'rsa')).signatures.single.verdict, openpgp.SignatureVerdict.good);
    expect((await _verify(tester, signed, 'ed')).signatures.single.verdict, openpgp.SignatureVerdict.unknownSigner);
  });

  testWidgets('an expired key is refused with its message', (tester) async {
    final pgp = await open(tester, keys: ['ed', 'expired']);
    await pgp.tap(find.text(t('pgp.sign.signAs')));
    // Listed, and marked: the person may want to know why it will not do
    await pgp.tap(find.byKey(const ValueKey('signer:pgp-expired')));
    await pgp.enter(t('pgp.sign.message'), 'too late');
    await pgp.tap(find.text(t('pgp.sign.button')));
    expect(find.text(t('pgp.standing.expired', {'name': 'Fixture Expired'})), findsOneWidget);
    expect(pgp.files.sharedTexts, isEmpty);
  });

  // openspec: add-post-quantum-pgp, task 6.4: version 6 keys sign now
  testWidgets('a version 6 key signs, and the signature is good', (tester) async {
    final pgp = await open(tester, keys: ['v6']);
    await pgp.enter(t('pgp.sign.message'), 'with the new kind of key');
    await pgp.tap(find.text(t('pgp.sign.button')));
    final signed = Uint8List.fromList(utf8.encode(pgp.files.sharedTexts.single));
    expect((await _verify(tester, signed, 'v6')).signatures.single.verdict, openpgp.SignatureVerdict.good);
  });

  // openspec: add-post-quantum-pgp, task 6.6
  for (final (key, name) in [('sq-protected', 'Fixture Sequoia'), ('kyber-protected', 'Fixture Kyber Protected')]) {
    testWidgets('a protected post-quantum key, $key, asks, refuses a wrong passphrase and signs with the right one', (tester) async {
      final pgp = await open(tester, keys: [key]);
      await pgp.enter(t('pgp.sign.message'), 'signed after a passphrase');
      await pgp.tap(find.text(t('pgp.sign.button')));
      expect(find.text(t('pgp.keyPassphrase.title', {'name': name})), findsOneWidget);
      await pgp.answerPassphrase('wrong');
      expect(find.text(t('pgp.error.wrongKeyPassphrase')), findsOneWidget);
      expect(pgp.files.sharedTexts, isEmpty);
      await pgp.answerPassphrase(fixturePassphrase);
      final signed = Uint8List.fromList(utf8.encode(pgp.files.sharedTexts.single));
      expect((await _verify(tester, signed, key)).signatures.single.verdict, openpgp.SignatureVerdict.good);
    });
  }

  testWidgets('a copy of a key whose secret is elsewhere says it cannot sign', (tester) async {
    final pgp = await open(tester, keys: ['stub']);
    await pgp.enter(t('pgp.sign.message'), 'no secret here');
    await pgp.tap(find.text(t('pgp.sign.button')));
    expect(find.text(t('pgp.error.noSecretHere')), findsOneWidget);
  });

  testWidgets('a protected key asks for its passphrase, each time, and its stored bytes do not change', (tester) async {
    final pgp = await open(tester, keys: ['rsa-protected']);
    final stored = pgp.app.container.read(vaultControllerProvider).keys.single.privateKey;
    await pgp.enter(t('pgp.sign.message'), 'locked');
    await pgp.tap(find.text(t('pgp.sign.button')));
    expect(find.text(t('pgp.keyPassphrase.title', {'name': 'Fixture RSA Protected'})), findsOneWidget);
    await pgp.answerPassphrase('nope');
    expect(find.text(t('pgp.error.wrongKeyPassphrase')), findsOneWidget);
    expect(pgp.files.sharedTexts, isEmpty);
    await pgp.answerPassphrase(fixturePassphrase);
    final signed = Uint8List.fromList(utf8.encode(pgp.files.sharedTexts.single));
    expect((await _verify(tester, signed, 'rsa-protected')).signatures.single.verdict, openpgp.SignatureVerdict.good);

    await pgp.enter(t('pgp.sign.message'), 'locked again');
    await pgp.tap(find.text(t('pgp.sign.button')));
    expect(find.byType(Dialog), findsOneWidget, reason: 'asked for again');
    await pgp.tap(find.descendant(of: find.byType(Dialog), matching: find.text(t('pgp.cancel'))));
    // Exporting it gives the bytes it had before it was used
    expect(pgp.app.container.read(vaultControllerProvider).keys.single.privateKey, stored);
    expect(base64.decode(stored), readArmorBlock(fixtureBytes('keys/gnupg/rsa3072-protected.secret.asc')));
  });

  testWidgets('with no PGP key that can sign, the sheet says one is needed and offers to add one', (tester) async {
    final pgp = await open(tester, keys: ['expired']);
    expect(find.text(t('pgp.sign.needKey')), findsOneWidget);
    expect(find.text(t('pgp.sign.button')), findsNothing);
    await pgp.tap(find.text(t('pgp.sign.addKey')));
    expect(find.byType(SignSheet), findsNothing);
    expect(find.byType(AddToVaultSheet), findsOneWidget);
  });

  testWidgets('closing and reopening shows no earlier text', (tester) async {
    final pgp = await open(tester);
    await pgp.enter(t('pgp.sign.message'), 'gone with the sheet');
    await pgp.closeSheet();
    await pgp.open('sign');
    expect(find.text('gone with the sheet'), findsNothing);
  });

  // openspec: add-post-quantum-pgp, task 8.3
  testWidgets('a key Kemlock cannot sign with is not offered; a GnuPG-format key says its signatures stay Ed25519', (tester) async {
    final pgp = await open(tester, keys: ['mldsa87', 'pq-gnupg']);
    // RFC 9980's A.4 key, first in the vault, goes by its user ID's name
    expect(find.descendant(of: find.byType(SignSheet), matching: find.textContaining('PQC user')), findsNothing);
    expect(find.descendant(of: find.byType(SignSheet), matching: find.text('Ada Lovelace')), findsOneWidget);
    expect(find.text(t('pgp.sign.ed25519Only')), findsOneWidget);
    await pgp.enter(t('pgp.sign.message'), 'Ed25519 still');
    await pgp.tap(find.text(t('pgp.sign.button')));
    final signed = Uint8List.fromList(utf8.encode(pgp.files.sharedTexts.single));
    expect((await _verify(tester, signed, 'pq-gnupg')).signatures.single.verdict, openpgp.SignatureVerdict.good);
  });
}
