// "Add someone": one of the vault's keys at a tap; a key pasted or chosen
// as a file read, shown with its user ID and fingerprint, and added only
// on a yes.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as openpgp;
import 'package:kemlock/features/contacts/recipients.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/features/pgp/add_someone_sheet.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/features/pgp/pgp_people.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../helpers/test_app.dart';
import '../contacts/contacts_kit.dart' show alan, contactOf, expired, grace1, graceFingerprint, keyBytes, revoked, signOnly;
import 'pgp_kit.dart';

const _rsaFingerprint = 'EA29C79D1C6570277907BB485D49D28C8EFC2F98';
const _rsaGrouped = 'EA29 C79D 1C65 7027 7907 BB48 5D49 D28C 8EFC 2F98';

void main() {
  /// Opens Encrypt, then "Add someone".
  Future<PgpApp> open(WidgetTester tester, {List<String> keys = const ['ed']}) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: keys);
    await pgp.open('encrypt');
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    expect(find.byType(AddSomeoneSheet), findsOneWidget);
    return pgp;
  }

  Future<void> paste(PgpApp pgp, String text) async {
    if (find.widgetWithText(TextField, t('pgp.people.paste')).evaluate().isEmpty) {
      await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
    }
    await pgp.enter(t('pgp.people.paste'), text);
    await pgp.tap(find.text(t('pgp.people.read')));
  }

  /// The chips in the Encrypt sheet's "To" card.
  List<String> recipients(WidgetTester tester) => [
    for (final chip in tester.widgetList<InputChip>(find.byType(InputChip))) (chip.label as Text).data!,
  ];

  testWidgets('one of the vault\'s own keys is added at a tap, and counts as checked', (tester) async {
    final pgp = await open(tester, keys: ['ed', 'rsa']);
    expect(find.text(t('pgp.people.yourKeys').toUpperCase()), findsOneWidget);
    final sheet = find.byType(AddSomeoneSheet);
    expect(find.descendant(of: sheet, matching: find.text('Fixture Ed25519')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('rsa@example.org')), findsOneWidget);

    await pgp.tap(find.descendant(of: sheet, matching: find.text('Fixture RSA')));
    // No confirmation: the sheet is gone and the name is among the recipients
    expect(sheet, findsNothing);
    expect(find.text(t('pgp.people.confirm.title')), findsNothing);
    expect(recipients(tester), ['Fixture RSA']);
    expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Fixture RSA'})), findsNothing);

    // It is not offered a second time
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    expect(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Fixture RSA')), findsNothing);
    expect(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Fixture Ed25519')), findsOneWidget);
  });

  testWidgets('a pasted GnuPG public key shows its user ID and fingerprint, and is added as not checked', (tester) async {
    final pgp = await open(tester);
    await paste(pgp, fixtureText('keys/gnupg/rsa3072.public.asc'));

    expect(find.text(t('pgp.people.confirm.title')), findsOneWidget);
    expect(find.text('Fixture RSA <rsa@example.org>'), findsOneWidget);
    expect(find.text(_rsaGrouped), findsOneWidget);
    expect(recipients(tester), isEmpty, reason: 'nothing is added before the yes');

    await pgp.tap(find.text(t('pgp.people.use')));
    expect(find.byType(AddSomeoneSheet), findsNothing);
    expect(recipients(tester), ['Fixture RSA']);
    expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Fixture RSA'})), findsOneWidget);
    // Nothing of it went into the vault
    expect(pgp.app.container.read(vaultControllerProvider).keys.map((k) => k.id), ['pgp-ed']);
    expect(pgp.app.container.read(pgpPeopleProvider).map((p) => p.fingerprint), isNot(contains(_rsaFingerprint)));
  });

  testWidgets('Back from the confirmation adds nothing', (tester) async {
    final pgp = await open(tester);
    await paste(pgp, fixtureText('keys/gnupg/rsa3072.public.asc'));
    await pgp.tap(find.text(t('pgp.people.back')));
    expect(find.text(t('pgp.people.title')), findsWidgets);
    await pgp.closeSheet();
    expect(recipients(tester), isEmpty);
  });

  testWidgets('a key file is read the same way, armored or binary', (tester) async {
    final pgp = await open(tester);
    final bytes = fixtureBytes('keys/gnupg/rsa3072.public.gpg');
    pgp.files.nextPick = PickedFile(name: 'grace.gpg', bytes: bytes);
    await pgp.tap(find.text(t('pgp.people.chooseFile')));
    expect(find.text(_rsaGrouped), findsOneWidget);
    await pgp.tap(find.text(t('pgp.people.use')));
    expect(recipients(tester), ['Fixture RSA']);
  });

  testWidgets('a secret key pasted by mistake adds only its public part', (tester) async {
    final pgp = await open(tester);
    await paste(pgp, fixtureText('keys/gnupg/rsa3072.secret.asc'));
    expect(find.text(_rsaGrouped), findsOneWidget);
    await pgp.tap(find.text(t('pgp.people.use')));
    expect(recipients(tester), ['Fixture RSA']);

    // What is encrypted to is the public key GnuPG exports for it
    await pgp.enter(t('pgp.encrypt.message'), 'hello');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    final request = pgp.requests.single as EncryptRequest;
    final keys = request.recipients.map(base64.encode).toList();
    expect(keys, contains(base64.encode(fixtureBytes('keys/gnupg/rsa3072.public.gpg'))));
    expect(keys.any((k) => k == base64.encode(fixtureBytes('keys/gnupg/rsa3072.secret.gpg'))), isFalse);
    expect(pgp.app.container.read(vaultControllerProvider).keys, hasLength(1));
  });

  testWidgets('a damaged key and text that is no key each say so and add nothing', (tester) async {
    final pgp = await open(tester);
    final armored = fixtureText('keys/gnupg/rsa3072.public.asc');
    await paste(pgp, armored.substring(0, armored.length ~/ 2));
    expect(find.text(t('pgp.people.error.damaged')), findsOneWidget);
    expect(find.text(t('pgp.people.confirm.title')), findsNothing);

    await paste(pgp, 'This is my key, I promise.');
    expect(find.text(t('pgp.people.error.notAKey')), findsOneWidget);

    // A message is not a key either
    await paste(pgp, fixtureText('pgp/gnupg/armored.asc'));
    expect(find.text(t('pgp.people.error.notAKey')), findsOneWidget);
    await pgp.closeSheet();
    expect(recipients(tester), isEmpty);
  });

  testWidgets('an expired key, a revoked key and a kind Kemlock does not use show their message and add nothing', (tester) async {
    final pgp = await open(tester);
    await paste(pgp, fixtureText('keys/gnupg/expiry/expired.public.asc'));
    expect(find.text(t('pgp.standing.expired', {'name': 'Fixture Expired'})), findsOneWidget);
    expect(find.text(t('pgp.people.use')), findsNothing);

    await paste(pgp, fixtureText('keys/gnupg/expiry/revoked.public.asc'));
    expect(find.text(t('pgp.standing.revoked', {'name': 'Fixture Revoked'})), findsOneWidget);

    await paste(pgp, fixtureText('pgp/gnupg/brainpoolP256r1.public.asc'));
    expect(find.text(t('pgp.error.unsupportedKey', {'name': 'brainpoolP256r1'})), findsOneWidget);

    // A version 6 key is written to since add-post-quantum-pgp; RFC 9980's
    // ML-DSA-87 key is of a kind Kemlock does not use, named in full
    await paste(pgp, fixtureText('keys/rfc9980/a4-public.asc'));
    expect(find.text(t('pgp.error.unsupportedKey', {'name': 'ML-DSA-87 + Ed448'})), findsOneWidget);

    // A key whose subkey binding was tampered with
    final broken = fixtureBytes('keys/gnupg/rsa3072.public.gpg');
    broken[broken.length - 3] ^= 1;
    pgp.files.nextPick = PickedFile(name: 'tampered.gpg', bytes: broken);
    await pgp.tap(find.text(t('pgp.people.chooseFile')));
    // Nothing a tampered key says of itself is believed: it is named by its key ID
    expect(find.text(t('pgp.standing.invalid', {'name': '5D49D28C8EFC2F98'})), findsOneWidget);

    await pgp.closeSheet();
    expect(recipients(tester), isEmpty);
  });

  group('the other people\'s keys the vault keeps', () {
    final checkedAt = DateTime(2026, 10, 3, 9).millisecondsSinceEpoch;
    final held = [
      contactOf(alan, id: 'c-alan', name: 'Alan Turing'),
      contactOf(grace1, id: 'c-grace', checkedAt: checkedAt),
      contactOf(signOnly, id: 'c-sign', name: 'Sign Only', checkedAt: checkedAt),
      contactOf(expired, id: 'c-expired', name: 'Expired Contact'),
      contactOf(revoked, id: 'c-revoked', name: 'Revoked Contact'),
      contactOf(alan, id: 'c-unreadable', name: 'Unreadable').copyWith(publicKey: 'AAAA'),
    ];

    /// Opens Encrypt, then "Add someone", in a vault holding the Ed25519 key and [held].
    Future<PgpApp> openWithContacts(WidgetTester tester) async {
      final pgp = PgpApp(tester);
      await pgp.start(keys: ['ed']);
      for (final contact in held) {
        await pgp.addContact(contact);
      }
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      return pgp;
    }

    /// The names the Add someone sheet lists under [label].
    List<String> listedUnder(WidgetTester tester, String label) {
      final heading = find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text(label.toUpperCase()));
      final group = find.ancestor(of: heading, matching: find.byType(Group)).first;
      return [for (final row in tester.widgetList<GroupRow>(find.descendant(of: group, matching: find.byType(GroupRow)))) row.primary];
    }

    testWidgets('everyone at hand: the vault\'s own keys, then each contact whose key can be read, checked as it is', (tester) async {
      final pgp = await openWithContacts(tester);
      final people = pgp.app.container.read(pgpPeopleProvider);

      expect(
        [for (final person in people) (person.name, person.vaultKeyId, person.contactId)],
        [
          ('Fixture Ed25519', 'pgp-ed', null),
          ('Alan Turing', null, 'c-alan'),
          ('Expired Contact', null, 'c-expired'),
          ('Grace Hopper', null, 'c-grace'),
          ('Revoked Contact', null, 'c-revoked'),
          ('Sign Only', null, 'c-sign'),
        ],
      );
      final grace = people.firstWhere((person) => person.contactId == 'c-grace');
      expect(
        (base64.encode(grace.publicKey), grace.address, grace.fingerprint, grace.checkedAt, grace.isChecked),
        (base64.encode(keyBytes(grace1)), 'grace@example.org', graceFingerprint, DateTime.fromMillisecondsSinceEpoch(checkedAt), true),
      );
      final alanTuring = people.firstWhere((person) => person.contactId == 'c-alan');
      expect((alanTuring.checkedAt, alanTuring.isChecked, alanTuring.isOwn), (null, false, false));
      expect(people.firstWhere((person) => person.contactId == 'c-expired').standing, Standing.expired);
      expect(people.firstWhere((person) => person.contactId == 'c-revoked').standing, Standing.revoked);
    });

    testWidgets('they are listed under their own label, those that can be encrypted to', (tester) async {
      final pgp = await openWithContacts(tester);

      expect(listedUnder(tester, t('pgp.people.yourKeys')), ['Fixture Ed25519']);
      expect(listedUnder(tester, t('vault.section.contacts')), ['Alan Turing', 'Grace Hopper']);

      // Which contacts may be encrypted to is answered the same way the
      // message layer answers it for any key
      final offered = {for (final recipient in pgp.app.container.read(contactRecipientsProvider)) recipient.contact.id};
      for (final person in pgp.app.container.read(pgpPeopleProvider).where((person) => person.isContact)) {
        final trouble = await tester.runAsync(() => openpgp.pgpKeyTrouble(person.publicKey, testNow));
        expect(offered.contains(person.contactId), trouble == null, reason: person.name);
      }

      // One is added at a tap, as the vault's own keys are, and not offered again
      await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Alan Turing')));
      expect(find.byType(AddSomeoneSheet), findsNothing);
      expect(recipients(tester), ['Alan Turing']);
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      expect(listedUnder(tester, t('vault.section.contacts')), ['Grace Hopper']);
    });
  });

  testWidgets('a recipient can be removed before encrypting', (tester) async {
    final pgp = await open(tester, keys: ['ed', 'rsa']);
    await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Fixture RSA')));
    expect(recipients(tester), ['Fixture RSA']);
    await pgp.tap(find.byTooltip(t('pgp.encrypt.remove', {'name': 'Fixture RSA'})));
    expect(recipients(tester), isEmpty);
  });
}
