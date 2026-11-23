import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/contacts/lookup/key_search_sheet.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/models/contact.dart';

import '../../../helpers/test_app.dart';
import '../contacts_kit.dart';
import 'lookup_app.dart';
import 'lookup_kit.dart';

/// "Look for a newer copy" on a contact's sheet (openspec: add-key-lookup, task 4.1): the same search, filled in
/// and waiting, whose key goes through the contact's update.
void main() {
  final checkedAt = DateTime(2026, 11, 3, 9).millisecondsSinceEpoch;

  Future<LookupApp> open(WidgetTester tester, Contact contact) async {
    final lookup = LookupApp(tester);
    await lookup.start();
    await lookup.hold(contact);
    await lookup.tap(find.text(contact.name));
    return lookup;
  }

  /// Looks the open contact's key up again, the domain answering [answer].
  Future<void> refresh(LookupApp lookup, List<int> answer) async {
    lookup.services.directory('grace@example.org', answer);
    await lookup.tap(find.text(t('contacts.sheet.lookup')));
    await lookup.tap(find.text(t('contacts.lookup.search')));
  }

  testWidgets('is offered for a key that names an address, under that address', (tester) async {
    await open(tester, contactOf(grace1));

    final row = find.byKey(const ValueKey('contact-lookup'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('grace@example.org')), findsOneWidget);
  });

  testWidgets('searches the address the key was found for, when it was', (tester) async {
    await open(tester, contactOf(grace1, source: ContactSource.wkd).copyWith(sourceEmail: 'Grace@example.org'));

    expect(find.descendant(of: find.byKey(const ValueKey('contact-lookup')), matching: find.text('Grace@example.org')), findsOneWidget);
  });

  testWidgets('is not offered for a key that names no address', (tester) async {
    await open(tester, contactOf(v6, name: 'Version 6'));

    expect(find.byKey(const ValueKey('contact-lookup')), findsNothing);
    expect(find.text(t('contacts.sheet.lookup')), findsNothing);
  });

  testWidgets('opens the search filled in, and sends nothing before "Search"', (tester) async {
    final lookup = await open(tester, contactOf(grace1));

    await lookup.tap(find.text(t('contacts.sheet.lookup')));

    expect(find.byType(KeySearchSheet), findsOneWidget);
    expect(tester.widget<TextField>(lookup.addressField).controller!.text, 'grace@example.org');
    expect(find.text(t('contacts.lookup.info.domain', {'domain': 'example.org'})), findsOneWidget);
    expect(lookup.services.resolved, isEmpty);
    expect(lookup.services.requests, isEmpty);
  });

  testWidgets('a copy found with a revocation leaves the contact revoked and still checked', (tester) async {
    final lookup = await open(tester, contactOf(grace1, checkedAt: checkedAt));

    await refresh(lookup, keyBytes(grace3));
    expect(find.text(t('contacts.update.title')), findsOneWidget);
    expect(find.textContaining(t('contacts.update.revoked')), findsOneWidget);
    await lookup.tap(find.text(t('contacts.update.confirm')));

    final contact = lookup.contacts.single;
    final standing = contactStanding(contact, contactsNow, info: lookup.app.container.read(contactKeyInfoProvider(contact.id)));
    expect(standing.key.standing, Standing.revoked);
    expect((standing.checked, contact.checkedAt, contact.source), (true, checkedAt, ContactSource.qr));
  });

  testWidgets('an identical copy says the key is already there', (tester) async {
    final lookup = await open(tester, contactOf(grace1, checkedAt: checkedAt));
    final before = lookup.contacts.single;

    await refresh(lookup, lookupAnswer(wkdGrace));

    expect(find.byKey(const ValueKey('update-same')), findsOneWidget);
    expect(find.text(t('contacts.update.same', {'name': 'Grace Hopper'})), findsOneWidget);
    expect(lookup.contacts.single, before);
  });

  testWidgets('a key with another fingerprint opens the replacement and changes nothing until answered', (tester) async {
    final lookup = await open(tester, contactOf(grace1, checkedAt: checkedAt));
    final before = lookup.contacts.single;

    await refresh(lookup, keyBytes(graceOther));

    expect(find.text(t('contacts.replace.title')), findsOneWidget);
    expect(find.byKey(const ValueKey('replace-current')), findsOneWidget);
    expect(find.byKey(const ValueKey('replace-next')), findsOneWidget);
    expect(lookup.contacts.single, before);

    Navigator.of(tester.element(find.byType(ContactReviewSheet))).pop();
    await tester.pumpAndSettle();
    expect(lookup.contacts.single, before);
  });
}
