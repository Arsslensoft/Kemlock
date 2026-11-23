// PGP messages from end to end, in the whole app: a key generated in the
// vault encrypts to itself, decrypts, replies, signs and verifies; and a
// hidden vault that encrypted a message leaves nothing on the phone that
// names it, its key or whom it wrote to.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/pgp/add_someone_sheet.dart';
import 'package:kemlock/features/pgp/decrypt_sheet.dart';
import 'package:kemlock/features/pgp/encrypt_sheet.dart';
import 'package:kemlock/features/pgp/pgp_controller.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';

import '../features/pgp/pgp_kit.dart';
import '../helpers/test_app.dart';
import 'flow_kit.dart';

/// Generates an Ed25519 PGP key for [name] and puts it in the open vault.
Future<VaultKey> _generate(PgpApp pgp, String name, String email, {required String id}) async {
  final parsed = (await pgp.tester.runAsync(() => crypto.makeKey(crypto.PgpKeyRequest(name: name, email: email))))!;
  final key = vaultKeyOf(parsed, id: id, name: '$name <$email>', origin: KeyOrigin.generated);
  await pgp.tester.runAsync(() => pgp.app.controller.addKey(key));
  await pgp.tester.pump();
  pgp.hideToast();
  await pgp.tester.pumpAndSettle();
  return key;
}

void main() {
  testWidgets('a generated key: encrypt to self, decrypt, reply, sign, verify', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start();
    final key = await _generate(pgp, 'Ada Lovelace', 'ada@example.org', id: 'ada');
    final fingerprint = crypto.readPgpKeyInfo(base64.decode(key.publicKey!)).primary.fingerprintHex;

    // Encrypt: "Also encrypt to me" is on, so the message is to oneself
    await pgp.open('encrypt');
    await pgp.enter(t('pgp.encrypt.message'), 'A note to myself.');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    final encrypted = pgp.files.sharedTexts.single;
    expect(encrypted, startsWith('-----BEGIN PGP MESSAGE-----'));
    await pgp.closeSheet();

    // Decrypt it: the key is found, and the signature is one's own
    await pgp.open('decrypt');
    await pgp.enter(t('pgp.decrypt.field'), encrypted);
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
    expect(find.text('A note to myself.'), findsOneWidget);
    expect(tester.widget<AppAlert>(find.byType(AppAlert)).severity, AlertSeverity.success);
    expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Ada Lovelace'})), findsOneWidget);
    expect(find.text(t('pgp.decrypted.matchesYours')), findsOneWidget);
    expect(inSheet<DecryptSheet>(find.text('Ada Lovelace')), findsOneWidget);
    expect(find.text('X25519, AES-256'), findsOneWidget);

    // Reply encrypted: the signer is the recipient, the message is empty
    await pgp.tap(find.text(t('pgp.decrypted.reply')));
    expect(find.byType(EncryptSheet), findsOneWidget);
    expect(tester.widgetList<InputChip>(find.byType(InputChip)).map((chip) => (chip.label as Text).data), ['Ada Lovelace']);
    await pgp.enter(t('pgp.encrypt.message'), 'And a reply.');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    final reply = pgp.files.sharedTexts.last;
    expect(reply, isNot(encrypted));
    await pgp.closeSheet();

    await pgp.open('decrypt');
    await pgp.enter(t('pgp.decrypt.field'), reply);
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
    expect(find.text('And a reply.'), findsOneWidget);
    await pgp.closeSheet();

    // Sign, then verify what was signed
    await pgp.open('sign');
    await pgp.enter(t('pgp.sign.message'), 'I agree.\n- Ada');
    await pgp.tap(find.text(t('pgp.sign.button')));
    final signed = pgp.files.sharedTexts.last;
    expect(signed, startsWith('-----BEGIN PGP SIGNED MESSAGE-----'));
    expect(signed, contains('\nI agree.\n- - Ada\n'));
    await pgp.closeSheet();

    await pgp.open('verify');
    await pgp.enter(t('pgp.verify.field'), signed);
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.verify.button')));
    expect(tester.widget<AppAlert>(find.byType(AppAlert)).severity, AlertSeverity.success);
    expect(find.text(t('pgp.decrypted.matchesYours')), findsOneWidget);
    expect(find.textContaining(fingerprint.substring(0, 4)), findsWidgets);
    // The signed text, as it was typed, under the banner
    expect(find.text('I agree.\n- Ada'), findsOneWidget);
    await pgp.closeSheet();

    // Nothing of it was kept
    expect(pgp.tempEntries, isEmpty);
    expect(storedText(pgp.app), isNot(contains('A note to myself')));
  });

  testWidgets('a hidden vault that encrypted a message leaves no trace of it', (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start();
    // A second vault that the lock screen does not list
    final hidden = (await tester.runAsync(() => pgp.app.vaultStore.createVault('Diary', 'another password', listed: false)))!;
    pgp.app.controller.lock();
    await tester.pumpAndSettle();
    await tester.runAsync(() async => pgp.app.controller.open(await pgp.app.vaultStore.unlockAnyVault('another password', hidden)));
    await tester.pumpAndSettle();
    expect(pgp.app.state.vault.hidden, isTrue);
    await tapOn(tester, tab('nav.vault'));

    final key = await _generate(pgp, 'Harriet Hidden', 'harriet@example.org', id: 'harriet');
    final fingerprint = crypto.readPgpKeyInfo(base64.decode(key.publicKey!)).primary.fingerprintHex;
    // What the phone holds before the message: the vault itself, sealed
    final before = storedText(pgp.app);

    await pgp.open('encrypt');
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
    await pgp.enter(t('pgp.people.paste'), fixtureText('keys/gnupg/rsa3072.public.asc'));
    await pgp.tap(find.text(t('pgp.people.read')));
    await pgp.tap(find.text(t('pgp.people.use')));
    expect(find.byType(AddSomeoneSheet), findsNothing);
    await pgp.enter(t('pgp.encrypt.message'), 'Meet me at the usual place.');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect(pgp.files.sharedTexts.single, startsWith('-----BEGIN PGP MESSAGE-----'));
    // The key chosen to sign as is remembered while the vault is open, in memory
    expect(pgp.app.container.read(pgpLastSignerProvider), isNull, reason: 'it was never chosen, only defaulted');

    pgp.app.controller.lock();
    await pgp.settle();
    expect(find.byType(EncryptSheet), findsNothing);

    // Preferences and the registry: not one byte changed, so nothing was written
    final after = storedText(pgp.app);
    expect(after, before);
    for (final secret in [
      'Harriet',
      'harriet@example.org',
      fingerprint,
      'Fixture RSA',
      'rsa@example.org',
      'EA29C79D1C6570277907BB485D49D28C8EFC2F98',
      'Meet me at the usual place',
      'BEGIN PGP',
    ]) {
      expect(after, isNot(contains(secret)), reason: secret);
    }
    // The temporary directory: empty
    expect(pgp.tempEntries, isEmpty);
    // And nothing in memory that the next vault could see
    expect(pgp.app.container.read(pgpJobControllerProvider), isNull);
    expect(pgp.app.container.read(pgpLastSignerProvider), isNull);
    expect(pgp.jobs.isRunning, isFalse);
  });
}
