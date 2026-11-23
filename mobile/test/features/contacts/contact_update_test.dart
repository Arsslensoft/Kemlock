import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/edit.dart' show changePgpKey;
import 'package:kemlock/crypto/keys/openpgp/key_info.dart' show transferablePublicKey;
import 'package:kemlock/crypto/keys/openpgp/packets.dart' show readPackets;
import 'package:kemlock/features/contacts/contact_keys.dart' show withCheckedAddresses;
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/contacts/contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/contacts/contact_widgets.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/ui/ui.dart' show GroupRow, StatusTag;

import '../../helpers/test_app.dart';
import 'contacts_app.dart';
import 'contacts_kit.dart';

// "Update this key" on a contact's sheet (openspec: add-pgp-contacts, decision 10): a copy of the same key is
// merged in, and a key of another fingerprint is shown beside the one it would replace.
void main() {
  final checkedAt = DateTime(2026, 11, 3, 9).millisecondsSinceEpoch;

  Future<ContactsApp> open(WidgetTester tester, Contact contact) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    await contacts.hold(contact);
    await contacts.tap(find.text(contact.name));
    return contacts;
  }

  /// Gives the open contact the key [text], pasted into "Update this key".
  Future<void> paste(ContactsApp contacts, String text) async {
    await contacts.tap(find.text(t('contacts.sheet.update')));
    await contacts.tap(find.text(t('contacts.add.paste')));
    await contacts.tester.enterText(find.widgetWithText(TextField, t('contacts.add.pasteField')), text);
    await contacts.tester.pump();
    await contacts.tap(find.text(t('contacts.add.read')));
  }

  /// Gives the open contact the key of the fixture [path], pasted into "Update this key".
  Future<void> update(ContactsApp contacts, String path) => paste(contacts, keyText(path));

  String wordsOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))).data!;

  List<String> groupsOf(WidgetTester tester, String key) => [
    for (final text in tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))))
      if (text.data!.isNotEmpty) text.data!,
  ];

  testWidgets('the later copy updates the expiry, keeps the check and says what changed', (tester) async {
    final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt));

    await update(contacts, grace2);

    expect(find.text(t('contacts.update.title')), findsOneWidget);
    final date = DateFormat('d MMMM y', 'en').format(DateTime.fromMillisecondsSinceEpoch(1893517200 * 1000));
    final words = wordsOf(tester, 'update-changes');
    expect(words, contains(t('contacts.update.expiry', {'date': date})));
    expect(words, contains(t('contacts.update.subkeys', {'count': 1})));
    expect(words, contains(t('contacts.update.keepsCheck')));
    await contacts.tap(find.text(t('contacts.update.confirm')));

    final contact = contacts.contacts.single;
    final standing = contactStanding(contact, contactsNow);
    expect(standing.key.expires, DateTime.fromMillisecondsSinceEpoch(1893517200 * 1000, isUtc: true));
    expect(standing.checked, isTrue);
    expect((contact.checkedAt, contact.checkedFingerprint), (checkedAt, graceFingerprint));
    expect(find.byType(ContactReviewSheet), findsNothing);
    // The sheet underneath shows the key as it is now
    expect(find.byType(ContactSheet), findsOneWidget);
    expect(find.text(DateFormat('d MMM y', 'en').format(DateTime.fromMillisecondsSinceEpoch(1893517200 * 1000))), findsOneWidget);
  });

  testWidgets('the revoked copy, then the old copy, leaves it revoked', (tester) async {
    final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt));

    await update(contacts, grace3);
    expect(wordsOf(tester, 'update-changes'), contains(t('contacts.update.revoked')));
    await contacts.tap(find.text(t('contacts.update.confirm')));
    expect(contactStanding(contacts.contacts.single, contactsNow).key.standing, Standing.revoked);
    final revokedCopy = contacts.contacts.single.publicKey;
    await contacts.clearToast();

    await update(contacts, grace1);

    // The old copy holds nothing the stored one lacks
    expect(find.text(t('contacts.update.same', {'name': 'Grace Hopper'})), findsOneWidget);
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.review.close')));
    expect(contacts.contacts.single.publicKey, revokedCopy);
    expect(contactStanding(contacts.contacts.single, contactsNow).key.standing, Standing.revoked);
    expect(contactStanding(contacts.contacts.single, contactsNow).canEncrypt, isFalse);
  });

  testWidgets('the identical copy says the key is already there, and saves nothing', (tester) async {
    final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt));
    // As the vault opened it, with the addresses of its check written down
    final before = contacts.contacts.single;
    expect(before.checkedAddresses, ['grace@example.org']);
    final stored = contacts.app.store.getItem('backmycodes_contact_data');

    await update(contacts, grace1);

    expect(find.text(t('contacts.update.same', {'name': 'Grace Hopper'})), findsOneWidget);
    expect(find.text(t('contacts.update.confirm')), findsNothing);
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.review.close')));
    expect(contacts.contacts.single, before);
    expect(contacts.app.store.getItem('backmycodes_contact_data'), stored);
  });

  group('a key of another fingerprint', () {
    Future<ContactsApp> offered(WidgetTester tester) async {
      final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt, note: 'From the conference', source: ContactSource.qr));
      await update(contacts, graceOther);
      return contacts;
    }

    testWidgets('shows both fingerprints, the old above the new, and says the keys differ', (tester) async {
      await offered(tester);

      expect(find.text(t('contacts.replace.title')), findsOneWidget);
      expect(groupsOf(tester, 'replace-current').join(), graceFingerprint);
      expect(groupsOf(tester, 'replace-next').join(), graceOtherFingerprint);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('replace-current'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('replace-next'))).dy),
      );
      expect(wordsOf(tester, 'replace-warning'), t('contacts.replace.warning', {'name': 'Grace Hopper'}));
      expect(find.byType(FingerprintCard), findsNWidgets(3), reason: 'the two of the review, and the one of the sheet underneath');
    });

    testWidgets('"Add without checking" replaces the key, keeps the id, name and note, and removes the check', (tester) async {
      final contacts = await offered(tester);

      await contacts.tap(find.text(t('contacts.review.unchecked')));

      final contact = contacts.contacts.single;
      expect(contact.publicKey, b64(keyBytes(graceOther)));
      expect((contact.id, contact.name, contact.note, contact.source), ('c1', 'Grace Hopper', 'From the conference', ContactSource.paste));
      expect((contact.checkedAt, contact.checkedFingerprint), (null, null));
      expect(contactStanding(contact, contactsNow).checked, isFalse);
    });

    testWidgets('"It matches" replaces the key and checks the new fingerprint now', (tester) async {
      final contacts = await offered(tester);

      await contacts.tap(find.text(t('contacts.review.checked')));

      final contact = contacts.contacts.single;
      expect(contact.publicKey, b64(keyBytes(graceOther)));
      expect((contact.checkedAt, contact.checkedFingerprint), (contactsNow.millisecondsSinceEpoch, graceOtherFingerprint));
      expect(contactStanding(contact, contactsNow).checked, isTrue);
    });

    testWidgets('closing the sheet changes nothing', (tester) async {
      final contacts = await offered(tester);

      await contacts.tap(find.bySemanticsLabel(t('contacts.review.close')));

      final contact = contacts.contacts.single;
      // As the vault opened it, with the addresses of its check written down
      expect(contact, withCheckedAddresses(contactOf(grace1, checkedAt: checkedAt, note: 'From the conference', source: ContactSource.qr)));
      expect(contactStanding(contact, contactsNow).checked, isTrue);
    });
  });

  testWidgets('a copy that names another address says so, and its check does not cover the address', (tester) async {
    final contacts = await open(tester, contactOf(grace1, checkedAt: checkedAt));
    // Grace's key as she might hand it over later, with an address she put in it since it was checked
    final later = (await tester.runAsync(() async {
      final secret = (await crypto.readPrivateKey(keyText('contacts/grace-1.secret.asc'))).private;
      final grown = await changePgpKey(
        secret,
        const crypto.AddPgpUserId(name: 'Alice', email: 'alice@corp.com'),
        now: contactsNow,
      );
      return crypto.writeArmor(crypto.pgpPublicKeyBlock, transferablePublicKey(readPackets(grown)));
    }))!;

    await paste(contacts, later);

    final words = wordsOf(tester, 'update-changes');
    expect(words, contains(t('contacts.update.addresses', {'addresses': 'alice@corp.com'})));
    expect(words, contains(t('contacts.update.keepsCheckNotFor', {'addresses': 'alice@corp.com'})));
    expect(words, isNot(contains(t('contacts.update.keepsCheck'))));
    // Every user ID of the key it becomes, the one it brings marked
    final userIds = find.byKey(const ValueKey('review-user-ids'));
    for (final userId in ['Grace Hopper <grace@example.org>', 'Alice <alice@corp.com>']) {
      expect(find.descendant(of: userIds, matching: find.text(userId)), findsOneWidget);
    }
    expect(find.descendant(of: userIds, matching: find.byType(StatusTag)), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(GroupRow, 'Alice <alice@corp.com>'), matching: find.byType(StatusTag)), findsOneWidget);
    await contacts.tap(find.text(t('contacts.update.confirm')));

    final contact = contacts.contacts.single;
    expect(contact.checkedAddresses, ['grace@example.org']);
    final standing = contactStanding(contact, contactsNow);
    expect(standing.checked, isTrue);
    expect(standing.confirmedAddresses, {'grace@example.org'});
    expect(standing.uncheckedAddresses, {'alice@corp.com'});
    // The sheet underneath says so, and offers to check it again
    expect(find.byKey(const ValueKey('contact-not-covered')), findsOneWidget);
    expect(find.text(t('contacts.sheet.uncheck')), findsOneWidget);
    await contacts.tap(find.text(t('contacts.sheet.checkNow')));
    expect(wordsOf(tester, 'check-covers'), t('contacts.sheet.check.covers', {'addresses': 'grace@example.org, alice@corp.com'}));
    await contacts.tap(find.text(t('contacts.sheet.check.confirm')));

    expect(contacts.contacts.single.checkedAddresses, ['alice@corp.com', 'grace@example.org']);
    expect(find.byKey(const ValueKey('contact-not-covered')), findsNothing);
    expect(find.text(t('contacts.sheet.checkNow')), findsNothing);
  });

  testWidgets('the merged key is what merging the two copies gives, whichever came first', (tester) async {
    final contacts = await open(tester, contactOf(grace2));

    await update(contacts, grace1);
    await contacts.tap(find.text(t('contacts.update.confirm')));

    final merged = await tester.runAsync(() => crypto.mergePublicKeys(keyBytes(grace1), keyBytes(grace2)));
    expect(contacts.contacts.single.publicKey, b64(merged!));
    // The older copy brought only older signatures: the expiry and the subkeys stay those of the newer one
    final standing = contactStanding(contacts.contacts.single, contactsNow);
    expect(standing.key.expires, DateTime.fromMillisecondsSinceEpoch(1893517200 * 1000, isUtc: true));
    expect(standing.info!.subkeys, hasLength(2));
  });
}
