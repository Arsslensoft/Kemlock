import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/contacts/contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/contacts/contact_widgets.dart';
import 'package:kemlock/features/keys/key_widgets.dart';
import 'package:kemlock/models/contact.dart';

import '../../helpers/test_app.dart';
import 'contacts_app.dart';
import 'contacts_kit.dart';

void main() {
  final checkedAt = DateTime(2026, 11, 3, 9).millisecondsSinceEpoch;

  /// The vault holding [contact], with its sheet open.
  Future<ContactsApp> open(WidgetTester tester, Contact contact) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    await contacts.hold(contact);
    await contacts.tap(find.text(contact.name));
    expect(find.byType(ContactSheet), findsOneWidget);
    return contacts;
  }

  String checkLine(WidgetTester tester) => tester.widget<RowValue>(find.byKey(const ValueKey('contact-check'))).text;

  Future<void> scan(ContactsApp contacts, String code) async {
    if (!contacts.scanner.isScanning) await contacts.tap(find.text(t('contacts.sheet.checkScan')));
    await contacts.scanner.emitScan(contacts.tester, code);
    await contacts.settle();
  }

  testWidgets('shows the check, the key, where it came from, the fingerprint, the names on it and its subkeys', (tester) async {
    await open(tester, contactOf(grace1, checkedAt: checkedAt, source: ContactSource.file));

    expect(checkLine(tester), 'Checked on 3 November');
    expect(find.text('Ed25519'), findsOneWidget);
    expect(find.text(DateFormat('d MMM y', 'en').format(DateTime.fromMillisecondsSinceEpoch(1826420030 * 1000))), findsOneWidget);
    expect(find.text(t('contacts.source.file')), findsOneWidget);
    expect(find.text('Grace Hopper <grace@example.org>'), findsOneWidget);
    expect(find.text('894F'), findsOneWidget);
    expect(find.text('3495'), findsOneWidget);
    expect(find.textContaining('cv25519'), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-standing')), findsNothing);
    // Checked already: the mark can be taken back, and there is nothing to check
    expect(find.text(t('contacts.sheet.uncheck')), findsOneWidget);
    expect(find.text(t('contacts.sheet.checkNow')), findsNothing);
  });

  testWidgets('renaming saves the name and a note, and leaves the key and the check as they were', (tester) async {
    final before = contactOf(grace1, checkedAt: checkedAt);
    final contacts = await open(tester, before);

    await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'Grace (work)');
    await tester.enterText(find.widgetWithText(TextField, t('passkeys.note')), 'Met in Lisbon');
    await tester.pump();
    await contacts.tap(find.text(t('passkeys.save')));

    final contact = contacts.contacts.single;
    expect((contact.name, contact.note), ('Grace (work)', 'Met in Lisbon'));
    expect(contact.publicKey, before.publicKey);
    expect((contact.checkedAt, contact.checkedFingerprint), (before.checkedAt, before.checkedFingerprint));
    expect(find.byType(ContactSheet), findsNothing);
    expect(find.text('Grace (work)'), findsOneWidget);
  });

  testWidgets('"Check the fingerprint" then "It matches" checks it now', (tester) async {
    final contacts = await open(tester, contactOf(alan, name: 'Alan Turing'));
    expect(checkLine(tester), t('contacts.notChecked'));

    await contacts.tap(find.text(t('contacts.sheet.checkNow')));
    expect(find.byKey(const ValueKey('check-fingerprint')), findsOneWidget);
    expect(find.text(t('contacts.review.advice', {'name': 'Alan Turing', 'count': 10})), findsOneWidget);
    await contacts.tap(find.text(t('contacts.sheet.check.confirm')));

    final contact = contacts.contacts.single;
    expect((contact.checkedAt, contact.checkedFingerprint), (contactsNow.millisecondsSinceEpoch, alanFingerprint));
    expect(checkLine(tester), contains('Checked on'));
    expect(find.text(t('contacts.sheet.checked', {'name': 'Alan Turing'})), findsOneWidget);
  });

  testWidgets('cancelling the comparison leaves it not checked', (tester) async {
    final contacts = await open(tester, contactOf(alan, name: 'Alan Turing'));

    await contacts.tap(find.text(t('contacts.sheet.checkNow')));
    await contacts.tap(find.descendant(of: find.byType(Dialog), matching: find.text(t('export.cancel'))));

    expect(contacts.contacts.single.checkedAt, isNull);
  });

  testWidgets('"Mark as not checked" removes the date and the fingerprint', (tester) async {
    final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt));

    await contacts.tap(find.text(t('contacts.sheet.uncheck')));

    final contact = contacts.contacts.single;
    expect(contact.toJson().keys, isNot(anyOf(contains('checkedAt'), contains('checkedFingerprint'))));
    expect(contactStanding(contact, contactsNow).checked, isFalse);
    expect(checkLine(tester), t('contacts.notChecked'));
    expect(find.text(t('contacts.sheet.checkNow')), findsOneWidget);
  });

  testWidgets('a key that only signs says messages cannot be encrypted to it', (tester) async {
    await open(tester, contactOf(signOnly, name: 'Signer'));

    expect(
      find.descendant(of: find.byKey(const ValueKey('contact-standing')), matching: find.text(t('contacts.review.cannotEncrypt'))),
      findsOneWidget,
    );
    expect(find.descendant(of: find.byKey(const ValueKey('contact-expiry')), matching: find.text(t('keys.expiry.never'))), findsOneWidget);
  });

  testWidgets('an expired key shows the date it expired, and a revoked one that it was revoked', (tester) async {
    final contacts = await open(tester, contactOf(expired, name: 'Expired'));

    final when = DateTime.utc(2020, 12, 31, 12).toLocal();
    expect(find.text(t('contacts.review.expired', {'date': DateFormat('d MMMM y', 'en').format(when)})), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('contact-expiry')), matching: find.text(DateFormat('d MMM y', 'en').format(when))),
      findsOneWidget,
    );

    await contacts.tap(find.text(t('contacts.sheet.delete')));
    await contacts.clearToast();
    await contacts.hold(contactOf(revoked, id: 'c2', name: 'Revoked'));
    await contacts.tap(find.text('Revoked'));
    expect(find.text(t('contacts.review.revokedBody')), findsOneWidget);
  });

  testWidgets('delete then Undo brings it back, with its check', (tester) async {
    final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt, note: 'kept'));

    await contacts.tap(find.text(t('contacts.sheet.delete')));

    expect(find.byType(ContactSheet), findsNothing);
    expect(contacts.contacts, isEmpty);
    expect(find.text(t('vault.snack.contactRemoved', {'name': 'Grace Hopper'})), findsOneWidget);
    await contacts.tap(find.text(t('app.undo')));

    final back = contacts.contacts.single;
    expect(
      (back.id, back.name, back.note, back.checkedAt, back.checkedFingerprint),
      ('c1', 'Grace Hopper', 'kept', checkedAt, graceFingerprint),
    );
    expect(back.publicKey, b64(keyBytes(grace1)));
  });

  testWidgets('the QR code of a short key holds the armored key another Kemlock scans', (tester) async {
    final contacts = await open(tester, contactOf(grace1));

    await contacts.tap(find.text(t('keys.public.qr')));

    final qr = tester.widget<PublicKeyQr>(find.byType(PublicKeyQr));
    expect(qr.data, startsWith('-----BEGIN PGP PUBLIC KEY BLOCK-----'));
    expect((await contacts.tester.runAsync(() async => qr.data.length))!, lessThan(publicKeyQrLimit));
  });

  // openspec: add-pgp-contacts, task 5.3
  group('checking by scanning their code', () {
    testWidgets('the armored key of the contact checks it', (tester) async {
      final contacts = await open(tester, contactOf(grace1));

      await scan(contacts, keyText(grace1));

      final contact = contacts.contacts.single;
      expect((contact.checkedAt, contact.checkedFingerprint), (contactsNow.millisecondsSinceEpoch, graceFingerprint));
      expect(contacts.scanner.isScanning, isFalse);
      expect(checkLine(tester), contains('Checked on'));
    });

    testWidgets('a later copy of the same key checks it too, and changes nothing else', (tester) async {
      final before = contactOf(grace1);
      final contacts = await open(tester, before);

      await scan(contacts, keyText(grace2));

      expect(contacts.contacts.single.checkedFingerprint, graceFingerprint);
      expect(contacts.contacts.single.publicKey, before.publicKey);
    });

    testWidgets('a fingerprint-only code of its fingerprint checks it', (tester) async {
      final contacts = await open(tester, contactOf(grace1));

      await scan(contacts, 'OPENPGP4FPR:$graceFingerprint');

      expect(contacts.contacts.single.checkedFingerprint, graceFingerprint);
      expect(contacts.contacts.single.checkedAt, contactsNow.millisecondsSinceEpoch);
    });

    for (final (name, code) in [('the key', keyText(graceOther)), ('the fingerprint', 'OPENPGP4FPR:$graceOtherFingerprint')]) {
      testWidgets('$name of another key leaves it not checked and says the fingerprints differ', (tester) async {
        final contacts = await open(tester, contactOf(grace1));

        await scan(contacts, code);

        expect(
          find.descendant(of: find.byKey(const ValueKey('scan-check-error')), matching: find.text(t('contacts.sheet.scan.differs'))),
          findsOneWidget,
        );
        expect(contacts.contacts.single.checkedAt, isNull);
        expect(contactStanding(contacts.contacts.single, contactsNow).checked, isFalse);
        // The right code after the wrong one still checks it
        await scan(contacts, 'OPENPGP4FPR:$graceFingerprint');
        expect(contacts.contacts.single.checkedFingerprint, graceFingerprint);
      });
    }

    for (final (name, code) in [('a web address', 'https://example.org/grace'), ('a fingerprint cut short', 'OPENPGP4FPR:894F6AAC')]) {
      testWidgets('$name is neither a key nor a fingerprint, and says so', (tester) async {
        final contacts = await open(tester, contactOf(grace1));

        await scan(contacts, code);

        expect(find.text(t('contacts.sheet.scan.notAKey')), findsOneWidget);
        expect(contacts.contacts.single.checkedAt, isNull);
      });
    }
  });
}
