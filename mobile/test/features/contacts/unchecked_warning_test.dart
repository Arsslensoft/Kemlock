import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/add_contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/contacts/recipients.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';
import 'contacts_app.dart';
import 'contacts_kit.dart';

// The warning about recipients that were never checked, and the contacts that can be recipients (openspec:
// add-pgp-contacts, task 9.1). The Encrypt sheet that shows it belongs to add-pgp-messages; here it is shown
// in a sheet of its own, as that sheet will place it.
void main() {
  final checkedAt = DateTime(2026, 11, 3, 9).millisecondsSinceEpoch;
  final grace = contactOf(grace1, checkedAt: checkedAt);
  final alanTuring = contactOf(alan, id: 'c2', name: 'Alan Turing');
  final rsa = contactOf(rsa3072, id: 'c3', name: 'Fixture Certified', checkedAt: checkedAt);

  Future<ContactsApp> open(WidgetTester tester, List<Contact> held) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    for (final contact in held) {
      await contacts.hold(contact);
    }
    return contacts;
  }

  /// Shows the warning for the chosen contacts, as the sheet that encrypts would.
  Future<void> choose(ContactsApp contacts, List<String> ids) async {
    unawaited(
      showAppBottomSheet<void>(
        contacts.root,
        label: 'Encrypt',
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Encrypt'),
              UncheckedRecipientsWarning(contactIds: ids),
            ],
          ),
        ),
      ),
    );
    await contacts.tester.pumpAndSettle();
  }

  Future<void> close(ContactsApp contacts) async {
    Navigator.of(contacts.tester.element(find.text('Encrypt'))).pop();
    await contacts.tester.pumpAndSettle();
  }

  Finder warning() => find.byKey(const ValueKey('unchecked-recipients'));

  testWidgets('shows nothing when every chosen contact is checked', (tester) async {
    final contacts = await open(tester, [grace, rsa, alanTuring]);

    await choose(contacts, ['c1', 'c3']);

    expect(find.text('Encrypt'), findsOneWidget);
    expect(warning(), findsNothing);
    expect(find.byType(AppAlert), findsNothing);
  });

  testWidgets('names the one unchecked contact among three, and no other', (tester) async {
    final contacts = await open(tester, [grace, rsa, alanTuring]);

    await choose(contacts, ['c1', 'c2', 'c3']);

    expect(find.text(t('contacts.warning.one', {'name': 'Alan Turing'})), findsOneWidget);
    expect(find.descendant(of: warning(), matching: find.textContaining('Grace')), findsNothing);
    expect(find.text(t('contacts.warning.check')), findsOneWidget);
    // It cannot be put away
    expect(find.descendant(of: warning(), matching: find.byIcon(Icons.close_rounded)), findsNothing);
  });

  testWidgets('names each of several unchecked contacts, with a way to check each', (tester) async {
    final contacts = await open(tester, [grace.unchecked(), alanTuring]);

    await choose(contacts, ['c1', 'c2']);

    expect(find.text(t('contacts.warning.many', {'names': 'Grace Hopper, Alan Turing'})), findsOneWidget);
    expect(find.text(t('contacts.warning.checkOne', {'name': 'Grace Hopper'})), findsOneWidget);
    expect(find.text(t('contacts.warning.checkOne', {'name': 'Alan Turing'})), findsOneWidget);
  });

  testWidgets('"Check now" then "It matches" checks the contact, and the warning is gone', (tester) async {
    final contacts = await open(tester, [grace, alanTuring]);
    await choose(contacts, ['c1', 'c2']);

    await contacts.tap(find.text(t('contacts.warning.check')));
    expect(find.byKey(const ValueKey('check-fingerprint')), findsOneWidget);
    await contacts.tap(find.text(t('contacts.sheet.check.confirm')));

    expect(warning(), findsNothing);
    final checked = contacts.contacts.firstWhere((c) => c.id == 'c2');
    expect((checked.checkedAt, checked.checkedFingerprint), (contactsNow.millisecondsSinceEpoch, alanFingerprint));
  });

  testWidgets('it shows again the next time the same unchecked contact is chosen', (tester) async {
    final contacts = await open(tester, [alanTuring]);

    for (var time = 0; time < 3; time++) {
      await choose(contacts, ['c2']);
      expect(find.text(t('contacts.warning.one', {'name': 'Alan Turing'})), findsOneWidget, reason: 'time $time');
      // Declining to check leaves it there, and going on leaves the contact as it was
      await contacts.tap(find.text(t('contacts.warning.check')));
      await contacts.tap(find.descendant(of: find.byType(Dialog), matching: find.text(t('export.cancel'))));
      expect(warning(), findsOneWidget);
      await close(contacts);
    }
    expect(contacts.contacts.single.checkedAt, isNull);
  });

  testWidgets('a contact marked as not checked warns again', (tester) async {
    final contacts = await open(tester, [grace]);
    await choose(contacts, ['c1']);
    expect(warning(), findsNothing);
    await close(contacts);

    await tester.runAsync(() => contacts.app.controller.updateContact(contacts.contacts.single.unchecked()));
    await tester.pumpAndSettle();
    await choose(contacts, ['c1']);

    expect(find.text(t('contacts.warning.one', {'name': 'Grace Hopper'})), findsOneWidget);
  });

  testWidgets('the recipients are the contacts that can be encrypted to, checked or not, by name', (tester) async {
    final contacts = await open(tester, [
      grace,
      alanTuring,
      rsa,
      contactOf(expired, id: 'c4', name: 'Expired', checkedAt: checkedAt),
      contactOf(revoked, id: 'c5', name: 'Revoked', checkedAt: checkedAt),
      contactOf(grace3, id: 'c6', name: 'Revoked later'),
      contactOf(signOnly, id: 'c7', name: 'Sign only', checkedAt: checkedAt),
      contactOf(alan, id: 'c8', name: 'Unreadable').copyWith(publicKey: 'AAAA'),
    ]);

    final recipients = contacts.app.container.read(contactRecipientsProvider);

    // c6 holds the same key as c1 with its revocation: the two are separate contacts here, and only c1 can be used
    expect([for (final r in recipients) r.contact.name], ['Alan Turing', 'Fixture Certified', 'Grace Hopper']);
    expect([for (final r in recipients) r.standing.checked], [false, true, true]);
    expect(recipients.every((r) => r.standing.canEncrypt), isTrue);
  });

  testWidgets('adds, checks, updates and is warned', (tester) async {
    final contacts = await open(tester, const []);

    // Add by pasting, without checking
    unawaited(showAddContactSheet(contacts.root));
    await tester.pumpAndSettle();
    await contacts.tap(find.text(t('contacts.add.paste')));
    await tester.enterText(find.widgetWithText(TextField, t('contacts.add.pasteField')), keyText(grace1));
    await tester.pump();
    await contacts.tap(find.text(t('contacts.add.read')));
    await contacts.tap(find.text(t('contacts.review.unchecked')));
    expect(contacts.contacts.single.name, 'Grace Hopper');
    await contacts.clearToast();

    // Open it, update its key, then check it
    await contacts.tap(find.text('Grace Hopper'));
    await contacts.tap(find.text(t('contacts.sheet.update')));
    await contacts.tap(find.text(t('contacts.add.paste')));
    await tester.enterText(find.widgetWithText(TextField, t('contacts.add.pasteField')), keyText(grace2));
    await tester.pump();
    await contacts.tap(find.text(t('contacts.add.read')));
    await contacts.tap(find.text(t('contacts.update.confirm')));
    await contacts.clearToast();
    await contacts.tap(find.text(t('contacts.sheet.checkNow')));
    await contacts.tap(find.text(t('contacts.sheet.check.confirm')));

    expect(contactStanding(contacts.contacts.single, contactsNow).checked, isTrue);
    expect(contactStanding(contacts.contacts.single, contactsNow).info!.subkeys, hasLength(2));
    expect(contacts.app.container.read(contactRecipientsProvider).single.contact.name, 'Grace Hopper');
  });
}
