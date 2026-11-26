import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/add_person_sheet.dart';
import 'package:kemlock/features/contacts/contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/contacts/recipients.dart';
import 'package:kemlock/features/pgp/pgp_people.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/platform/links.dart';

import '../../helpers/test_app.dart';
import 'contacts_app.dart';
import 'contacts_kit.dart';

// A contact is a person (company, email, phone, address) with an optional key: a person without one is saved, listed and shown, and
// everything that needs a key leaves them out.
class _Launcher implements LinkLauncher {
  final launched = <Uri>[];

  @override
  Future<bool> launch(Uri url) async {
    launched.add(url);
    return true;
  }
}

/// The contact tests' app with a launcher that records what the phone was asked to open.
class _PersonApp extends ContactsApp {
  _PersonApp(super.tester, this.launcher);

  final _Launcher launcher;

  @override
  List<Override> get overrides => [...super.overrides, linkLauncherProvider.overrideWithValue(launcher)];
}

void main() {
  const ada = Contact(
    id: 'p1',
    name: 'Ada Lovelace',
    source: ContactSource.manual,
    company: 'Analytical Engines',
    email: 'ada@example.org',
    phone: '+44 20 7946 0000',
    address: '12 St James Square\nLondon',
    addedAt: 1,
  );

  Future<ContactsApp> open(WidgetTester tester) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    return contacts;
  }

  testWidgets('a person is added with no key, from a name alone, and saved as typed in', (tester) async {
    final contacts = await open(tester);
    unawaited(showAddPersonSheet(contacts.root));
    await contacts.settle();

    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('contacts.person.save'))).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'Ada Lovelace');
    await tester.enterText(find.widgetWithText(TextField, t('contacts.person.company')), 'Analytical Engines');
    await tester.enterText(find.widgetWithText(TextField, t('contacts.person.email')), 'ada@example.org');
    await tester.enterText(find.widgetWithText(TextField, t('contacts.person.phone')), '+44 20 7946 0000');
    await tester.enterText(find.widgetWithText(TextField, t('contacts.person.address')), '12 St James Square\nLondon');
    await tester.pump();
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.person.save')));

    final saved = contacts.contacts.single;
    expect((saved.name, saved.source, saved.hasKey), ('Ada Lovelace', ContactSource.manual, false));
    expect(
      (saved.company, saved.email, saved.phone, saved.address),
      ('Analytical Engines', 'ada@example.org', '+44 20 7946 0000', '12 St James Square\nLondon'),
    );
    // No empty key is written, and the unset fields are left out
    expect(saved.toJson().containsKey('public'), isFalse);
    expect(find.byType(AddPersonSheet), findsNothing);
  });

  testWidgets('a person with no key is skipped as a recipient and as a signer, and counted', (tester) async {
    final contacts = await open(tester);
    await contacts.hold(ada);
    await contacts.hold(contactOf(alan, id: 'c2', name: 'Alan Turing'));
    final container = contacts.app.container;

    expect([for (final recipient in container.read(contactRecipientsProvider)) recipient.contact.name], ['Alan Turing']);
    expect([for (final person in container.read(pgpContactPeopleProvider)) person.name], ['Alan Turing']);
    expect(container.read(contactKeyInfoProvider('p1')), isNull);
    expect(contactStanding(ada, contactsNow).canEncrypt, isFalse);
    expect(container.read(keylessContactCountProvider), 1);
  });

  testWidgets('the sheet of a person shows the details and says there is no key', (tester) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    await contacts.hold(ada);
    await contacts.tap(find.text('Ada Lovelace'));

    expect(find.byType(ContactSheet), findsOneWidget);
    expect(find.text('Analytical Engines'), findsOneWidget);
    expect(find.text('ada@example.org'), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-no-key')), findsOneWidget);
    expect(find.text(t('contacts.person.addKey')), findsOneWidget);
    expect(find.text(t('contacts.person.removeKey')), findsNothing);
    // Nothing to check or encrypt to
    expect(find.text(t('contacts.sheet.checkNow')), findsNothing);
  });

  testWidgets('Mail and Call hand the address and the number to the phone', (tester) async {
    final launcher = _Launcher();
    final contacts = _PersonApp(tester, launcher);
    await contacts.start();
    await contacts.hold(ada);
    await contacts.tap(find.text('Ada Lovelace'));

    await contacts.tap(find.byKey(const ValueKey('person-mail')));
    await contacts.tap(find.byKey(const ValueKey('person-call')));

    expect(launcher.launched.map((uri) => uri.scheme), ['mailto', 'tel']);
    expect(launcher.launched.first.path, 'ada@example.org');
  });

  testWidgets('a key taken off a person leaves them with their details, no check, and nothing to encrypt to', (tester) async {
    final contacts = await open(tester);
    final checkedAt = DateTime(2026, 11, 3, 9).millisecondsSinceEpoch;
    await contacts.hold(contactOf(alan, name: 'Alan Turing', checkedAt: checkedAt).copyWith(company: 'Bletchley Park'));
    await contacts.tap(find.text('Alan Turing'));

    await contacts.tap(find.text(t('contacts.person.removeKey')));
    await contacts.tap(find.widgetWithText(FilledButton, t('contacts.person.removeKey.confirm')));

    final person = contacts.contacts.single;
    expect((person.hasKey, person.source, person.company), (false, ContactSource.manual, 'Bletchley Park'));
    expect((person.checkedAt, person.checkedFingerprint, person.checkedAddresses), (null, null, null));
    expect(contacts.app.container.read(contactRecipientsProvider), isEmpty);
  });
}
