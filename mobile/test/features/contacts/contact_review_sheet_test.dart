import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/contacts/contact_widgets.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/vault_key.dart';

import '../../helpers/test_app.dart';
import 'contacts_app.dart';
import 'contacts_kit.dart';

/// The groups the fingerprint card on screen shows, in reading order.
List<String> _groups(WidgetTester tester, [Finder? card]) => [
  for (final text in tester.widgetList<Text>(find.descendant(of: card ?? find.byType(FingerprintCard), matching: find.byType(Text))))
    if (text.data!.isNotEmpty) text.data!,
];

Finder get _checked => find.text(t('contacts.review.checked'));
Finder get _unchecked => find.text(t('contacts.review.unchecked'));

void main() {
  Future<ContactsApp> open(WidgetTester tester) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    return contacts;
  }

  testWidgets('shows whose key it is, where it came from, what it is and the advice, in the order of the mockup', (tester) async {
    final contacts = await open(tester);

    await contacts.review([grace1]);

    expect(find.text(t('contacts.review.title')), findsOneWidget);
    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(find.text('grace@example.org'), findsOneWidget);
    expect(find.text('GH'), findsOneWidget);
    expect(find.text(t('contacts.review.source')), findsOneWidget);
    expect(find.text(t('contacts.source.qr')), findsOneWidget);
    final expires = DateFormat('d MMM y', 'en').format(DateTime.fromMillisecondsSinceEpoch(1826420030 * 1000));
    expect(find.text('Ed25519 · ${t('contacts.review.expires', {'date': expires})}'), findsOneWidget);
    expect(find.text(t('contacts.review.fingerprint').toUpperCase()), findsOneWidget);
    expect(find.text(t('contacts.review.advice', {'name': 'Grace Hopper', 'count': 10})), findsOneWidget);
    expect(find.text(t('contacts.review.caption')), findsOneWidget);
    // Every user ID, in full: what a check covers
    expect(
      find.descendant(of: find.byKey(const ValueKey('review-user-ids')), matching: find.text('Grace Hopper <grace@example.org>')),
      findsOneWidget,
    );
    // From the top: the facts, the user IDs, the fingerprint, the advice, the two answers, the caption
    final tops = [
      for (final finder in [
        find.text('Grace Hopper'),
        find.byKey(const ValueKey('review-user-ids')),
        find.byType(FingerprintCard),
        find.text(t('contacts.review.advice', {'name': 'Grace Hopper', 'count': 10})),
        _checked,
        _unchecked,
        find.text(t('contacts.review.caption')),
      ])
        tester.getTopLeft(finder).dy,
    ];
    expect(tops, [...tops]..sort());
    expect(contacts.contacts, isEmpty);
  });

  testWidgets('a version 4 key shows ten groups of four, and a version 6 key sixteen', (tester) async {
    final contacts = await open(tester);

    await contacts.review([grace1]);
    expect(_groups(tester), ['894F', '6AAC', '8FCE', '0FAF', '7EE2', '1BB6', 'B405', 'E72A', 'FBA2', '3495']);
    await contacts.tap(find.bySemanticsLabel(t('contacts.review.close')));

    await contacts.review([v6]);
    final groups = _groups(tester);
    expect(groups, hasLength(16));
    expect(groups.join(), fingerprintOf(v6));
    expect(find.text(t('contacts.review.advice.unnamed', {'count': 16})), findsOneWidget);
  });

  testWidgets('the fingerprint card is read out as its groups, in order', (tester) async {
    final handle = tester.ensureSemantics();
    final contacts = await open(tester);

    await contacts.review([grace1]);

    const spoken = '8 9 4 F, 6 A A C, 8 F C E, 0 F A F, 7 E E 2, 1 B B 6, B 4 0 5, E 7 2 A, F B A 2, 3 4 9 5';
    expect(find.bySemanticsLabel(t('contacts.review.fingerprint.semantics', {'groups': spoken})), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the groups read left to right in a right-to-left layout too', (tester) async {
    await pumpOnPage(
      tester,
      const Directionality(
        textDirection: TextDirection.rtl,
        child: FingerprintCard(fingerprint: graceFingerprint),
      ),
    );

    final first = tester.getTopLeft(find.text('894F'));
    final second = tester.getTopLeft(find.text('6AAC'));
    expect(first.dx, lessThan(second.dx));
    expect(first.dy, second.dy);
    expect(tester.getTopLeft(find.text('1BB6')).dy, greaterThan(first.dy));
  });

  testWidgets('"It matches" adds the contact as checked now, with the fingerprint that was compared', (tester) async {
    final contacts = await open(tester);
    await contacts.review([grace1], source: ContactSource.file);

    await contacts.tap(_checked);

    final contact = contacts.contacts.single;
    expect((contact.name, contact.source), ('Grace Hopper', ContactSource.file));
    expect((contact.checkedAt, contact.checkedFingerprint), (contactsNow.millisecondsSinceEpoch, graceFingerprint));
    expect(contact.checkedAddresses, ['grace@example.org']);
    expect(contact.publicKey, b64(keyBytes(grace1)));
    expect(contactStanding(contact, contactsNow).checked, isTrue);
    expect(find.byType(ContactReviewSheet), findsNothing);
  });

  testWidgets('"Add without checking" adds it with neither the date nor the fingerprint', (tester) async {
    final contacts = await open(tester);
    await contacts.review([grace1]);

    await contacts.tap(_unchecked);

    final contact = contacts.contacts.single;
    expect((contact.checkedAt, contact.checkedFingerprint), (null, null));
    expect(contact.toJson().keys, isNot(contains('checkedAt')));
    expect(contactStanding(contact, contactsNow).checked, isFalse);
  });

  testWidgets('closing the sheet adds nothing', (tester) async {
    final contacts = await open(tester);
    await contacts.review([grace1]);

    await contacts.tap(find.bySemanticsLabel(t('contacts.review.close')));

    expect(find.byType(ContactReviewSheet), findsNothing);
    expect(contacts.contacts, isEmpty);
    expect(contacts.app.store.getItem('backmycodes_contact_data'), isNull);
  });

  testWidgets('a key that expired says so, when, and that it can no longer be encrypted to', (tester) async {
    final contacts = await open(tester);

    await contacts.review([expired]);

    final date = DateFormat('d MMMM y', 'en').format(DateTime.utc(2020, 12, 31, 12).toLocal());
    expect(find.text(t('contacts.review.expired', {'date': date})), findsOneWidget);
    final short = DateFormat('d MMM y', 'en').format(DateTime.utc(2020, 12, 31, 12).toLocal());
    expect(find.text('Ed25519 · ${t('contacts.review.expiredOn', {'date': short})}'), findsOneWidget);
  });

  testWidgets('a revoked key and a key that only signs each say what they cannot do', (tester) async {
    final contacts = await open(tester);

    await contacts.review([revoked]);
    expect(find.text(t('contacts.review.revokedBody')), findsOneWidget);
    await contacts.tap(find.bySemanticsLabel(t('contacts.review.close')));

    await contacts.review([signOnly]);
    expect(find.text(t('contacts.review.cannotEncrypt')), findsOneWidget);
    expect(find.text('Ed25519 · ${t('contacts.review.neverExpires')}'), findsOneWidget);
  });

  testWidgets('a key that is one of the person’s own is refused', (tester) async {
    final contacts = await open(tester);
    await contacts.holdOwnKey('contacts/grace-1.secret.asc', name: 'Me at work');

    await contacts.review([grace1]);

    expect(find.text(t('contacts.review.own', {'name': 'Me at work'})), findsOneWidget);
    expect(_checked, findsNothing);
    expect(_unchecked, findsNothing);
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.review.close')));
    expect(contacts.contacts, isEmpty);
  });

  // Joined with add-openpgp-card: a key whose private half is on a security key is one of the person's own too
  testWidgets('a key of the person’s kept on a security key is refused as their own', (tester) async {
    final contacts = await open(tester);
    final card = VaultKey(
      id: 'own-card',
      name: 'On my key',
      kind: KeyKind.pgp,
      algorithm: 'pgp',
      privateKey: b64(keyFixtureFile('gnupg/card/stub-ed25519.gpg').readAsBytesSync()),
      publicKey: b64(keyFixtureFile('gnupg/ed25519.public.gpg').readAsBytesSync()),
      origin: KeyOrigin.imported,
      protected: true,
      addedAt: 0,
      card: const {
        'aid': 'D276000124010304FFFF123456780000',
        'slots': {'sig': '1FCDA135EE42400EC2B77CE677249ABE661CF8DB', 'dec': '4BA83174FC8CE762A23BF0A4841A40E3B199EA67'},
      },
    );
    await tester.runAsync(() => contacts.app.controller.addKey(card));
    await tester.pumpAndSettle();

    await contacts.review(['gnupg/ed25519.public.asc']);

    expect(find.text(t('contacts.review.own', {'name': 'On my key'})), findsOneWidget);
    expect(_checked, findsNothing);
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.review.close')));
    expect(contacts.contacts, isEmpty);
  });

  testWidgets('a key for an address a contact already has says one is kept, and whether it is checked', (tester) async {
    final contacts = await open(tester);
    await contacts.hold(contactOf(grace1, name: 'Grace', checkedAt: 1));

    await contacts.review([graceOther]);

    expect(find.text(t('contacts.review.sameEmail.checked', {'email': 'grace@example.org', 'name': 'Grace'})), findsOneWidget);
    expect(_groups(tester).join(), graceOtherFingerprint);
    // It is still a key of its own: added beside the first, and not checked
    await contacts.tap(_unchecked);
    expect(contacts.contacts, hasLength(2));
    expect(contactStanding(contacts.contacts.first, contactsNow).checked, isTrue);
    expect(contactStanding(contacts.contacts.last, contactsNow).checked, isFalse);
  });

  testWidgets('and says so when the one kept was never checked', (tester) async {
    final contacts = await open(tester);
    await contacts.hold(contactOf(grace1, name: 'Grace'));

    await contacts.review([graceOther]);

    expect(find.text(t('contacts.review.sameEmail.unchecked', {'email': 'grace@example.org', 'name': 'Grace'})), findsOneWidget);
  });

  testWidgets('a key for the email of a person with no key says so', (tester) async {
    final contacts = await open(tester);
    await contacts.hold(const Contact(id: 'p1', name: 'Grace P', source: ContactSource.manual, email: ' Grace@Example.org ', addedAt: 1));

    await contacts.review([grace1]);

    expect(find.text(t('contacts.review.sameEmail.person', {'email': 'grace@example.org', 'name': 'Grace P'})), findsOneWidget);
  });

  testWidgets('a key given to a person with no key that another contact holds says so, and changes neither', (tester) async {
    final contacts = await open(tester);
    await contacts.hold(contactOf(grace1, name: 'Grace', checkedAt: 1));
    await contacts.hold(const Contact(id: 'p1', name: 'Grace P', source: ContactSource.manual, email: 'gp@example.org', addedAt: 1));
    final before = contacts.contacts.map((contact) => contact.toJson()).toList();

    await contacts.review([grace1], replacingId: 'p1');

    expect(find.text(t('contacts.person.addKey.heldElsewhere', {'holder': 'Grace', 'name': 'Grace P'})), findsOneWidget);
    expect(find.text(t('contacts.update.title')), findsNothing);
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.review.close')));
    expect(contacts.contacts.map((contact) => contact.toJson()).toList(), before);
  });

  testWidgets('of two keys, skipping one and confirming the other adds one', (tester) async {
    final contacts = await open(tester);
    await contacts.review([twoKeys], source: ContactSource.file);

    expect(find.text(t('contacts.review.step', {'index': 1, 'count': 2})), findsOneWidget);
    expect(find.text('Alan Turing'), findsOneWidget);
    await contacts.tap(find.text(t('contacts.review.skip')));

    expect(find.text(t('contacts.review.step', {'index': 2, 'count': 2})), findsOneWidget);
    expect(find.text('Fixture Sign Only'), findsOneWidget);
    await contacts.tap(_checked);

    expect(contacts.contacts.map((c) => c.name), ['Fixture Sign Only']);
    expect(find.byType(ContactReviewSheet), findsNothing);
  });

  testWidgets('of two keys, confirming the first and closing on the second adds one', (tester) async {
    final contacts = await open(tester);
    await contacts.review([twoKeys]);

    await contacts.tap(_unchecked);
    expect(find.text('Fixture Sign Only'), findsOneWidget);
    await contacts.tap(find.bySemanticsLabel(t('contacts.review.close')));

    expect(contacts.contacts.map((c) => c.name), ['Alan Turing']);
  });

  group('a key a contact already holds', () {
    testWidgets('updates that contact instead of adding one, keeps the check and says what changed', (tester) async {
      final contacts = await open(tester);
      await contacts.hold(contactOf(grace1, name: 'Grace', checkedAt: 1_793_700_000_000, note: 'From the conference'));

      await contacts.review([grace2], source: ContactSource.paste);

      expect(find.text(t('contacts.update.title')), findsOneWidget);
      expect(_checked, findsNothing);
      final date = DateFormat('d MMMM y', 'en').format(DateTime.fromMillisecondsSinceEpoch(1893517200 * 1000));
      final words = tester
          .widget<Text>(find.descendant(of: find.byKey(const ValueKey('update-changes')), matching: find.byType(Text)))
          .data!;
      expect(words, contains(t('contacts.update.intro', {'name': 'Grace'})));
      expect(words, contains(t('contacts.update.expiry', {'date': date})));
      expect(words, contains(t('contacts.update.subkeys', {'count': 1})));
      expect(words, contains(t('contacts.update.keepsCheck')));

      await contacts.tap(find.text(t('contacts.update.confirm')));

      final contact = contacts.contacts.single;
      final merged = await tester.runAsync(() => crypto.mergePublicKeys(keyBytes(grace1), keyBytes(grace2)));
      expect(contact.publicKey, b64(merged!));
      expect((contact.id, contact.name, contact.note, contact.source), ('c1', 'Grace', 'From the conference', ContactSource.qr));
      final standing = contactStanding(contact, contactsNow);
      expect(standing.checked, isTrue);
      expect(standing.key.expires, DateTime.fromMillisecondsSinceEpoch(1893517200 * 1000, isUtc: true));
      expect(standing.info!.subkeys, hasLength(2));
    });

    testWidgets('says the key is already there when the copy is the same, and saves nothing', (tester) async {
      final contacts = await open(tester);
      await contacts.hold(contactOf(grace1, name: 'Grace'));
      final stored = contacts.app.store.getItem('backmycodes_contact_data');

      await contacts.review([grace1]);

      expect(find.text(t('contacts.update.same', {'name': 'Grace'})), findsOneWidget);
      expect(find.text(t('contacts.update.confirm')), findsNothing);
      await contacts.tap(find.widgetWithText(FilledButton, t('contacts.review.close')));
      expect(contacts.contacts.single, contactOf(grace1, name: 'Grace'));
      expect(contacts.app.store.getItem('backmycodes_contact_data'), stored);
    });
  });
}
