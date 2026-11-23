import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/add_contact_sheet.dart';
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/keys/import_key_sheet.dart';
import 'package:kemlock/platform/files.dart';

import '../../helpers/test_app.dart';
import 'contacts_app.dart';
import 'contacts_kit.dart';

void main() {
  Future<ContactsApp> open(WidgetTester tester) async {
    final contacts = ContactsApp(tester);
    await contacts.start();
    unawaited(showAddContactSheet(contacts.root));
    await tester.pumpAndSettle();
    return contacts;
  }

  Future<void> paste(ContactsApp contacts, String text) async {
    if (find.widgetWithText(TextField, t('contacts.add.pasteField')).evaluate().isEmpty) {
      await contacts.tap(find.text(t('contacts.add.paste')));
    }
    await contacts.tester.enterText(find.widgetWithText(TextField, t('contacts.add.pasteField')), text);
    await contacts.tester.pump();
    await contacts.tap(find.text(t('contacts.add.read')));
  }

  Future<void> scan(ContactsApp contacts, String code) async {
    if (!contacts.scanner.isScanning) await contacts.tap(find.text(t('contacts.add.scan')));
    await contacts.scanner.emitScan(contacts.tester, code);
    await contacts.settle();
  }

  String errorOnScreen(WidgetTester tester) =>
      tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('add-contact-error')), matching: find.byType(Text))).data!;

  testWidgets('offers three ways in, and stores nothing by itself', (tester) async {
    final contacts = await open(tester);

    expect(find.text(t('contacts.add.title')), findsOneWidget);
    for (final id in ['contacts.add.scan', 'contacts.add.file', 'contacts.add.paste']) {
      expect(find.text(t(id)), findsOneWidget);
    }
    expect(contacts.scanner.sources, isEmpty, reason: 'the camera stays off until scanning is chosen');
    expect(contacts.contacts, isEmpty);
  });

  testWidgets('a pasted armored key reaches the review as pasted text', (tester) async {
    final contacts = await open(tester);

    await paste(contacts, keyText(grace1));

    expect(find.byType(AddContactSheet), findsNothing);
    expect(find.byType(ContactReviewSheet), findsOneWidget);
    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(find.text(t('contacts.source.paste')), findsOneWidget);
    expect(contacts.contacts, isEmpty);
  });

  testWidgets('a chosen binary file reaches the review as a file, with both of its keys', (tester) async {
    final contacts = await open(tester);
    contacts.pick('contacts/two-keys.public.gpg');

    await contacts.tap(find.text(t('contacts.add.file')));

    expect(find.byType(ContactReviewSheet), findsOneWidget);
    expect(find.text(t('contacts.source.file')), findsOneWidget);
    expect(find.text(t('contacts.review.step', {'index': 1, 'count': 2})), findsOneWidget);
    expect(find.text('Alan Turing'), findsOneWidget);
  });

  testWidgets('a scanned code holding an armored key reaches the review as a scanned QR code', (tester) async {
    final contacts = await open(tester);

    await scan(contacts, keyText(grace1));

    expect(find.byType(ContactReviewSheet), findsOneWidget);
    expect(find.text(t('contacts.source.qr')), findsOneWidget);
    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(contacts.scanner.isScanning, isFalse);
  });

  testWidgets('a code holding a fingerprint only adds nothing and says it carries no key', (tester) async {
    final contacts = await open(tester);

    await scan(contacts, 'OPENPGP4FPR:$graceFingerprint');

    expect(errorOnScreen(tester), t('contacts.add.fingerprintOnly'));
    expect(find.byType(ContactReviewSheet), findsNothing);
    expect(contacts.contacts, isEmpty);
    // The camera stays on for the right code
    await scan(contacts, keyText(grace1));
    expect(find.byType(ContactReviewSheet), findsOneWidget);
  });

  testWidgets('a code holding a web address adds nothing and says it is not a public key', (tester) async {
    final contacts = await open(tester);

    await scan(contacts, 'https://example.org/grace');

    expect(errorOnScreen(tester), t('contacts.add.notAKey'));
    expect(find.byType(ContactReviewSheet), findsNothing);
    expect(contacts.contacts, isEmpty);
  });

  group('says why, and adds nothing, for', () {
    final big = Uint8List(1024 * 1024 + 1)..setAll(0, utf8.encode('-----BEGIN PGP PUBLIC KEY BLOCK-----'));
    for (final (name, input, id, args) in <(String, Object, String, Map<String, Object?>)>[
      ('a block cut short', keyText('contacts/grace-1.cut.public.asc'), 'contacts.error.damaged', const {}),
      ('a subkey its owner never signed', keyText('contacts/grace-1.foreign-subkey.public.asc'), 'contacts.error.failsChecks', const {}),
      ('a flipped certification', keyText('contacts/grace-1.flipped-certification.public.asc'), 'contacts.error.failsChecks', const {}),
      (
        'an algorithm that cannot be checked',
        keyText('contacts/ecdsa-p256.public.asc'),
        'contacts.error.unsupportedKeyType',
        const {'detail': 'ECDSA (nistp256)'},
      ),
      ('an SSH public key', keyText('openssh/ed25519.pub'), 'contacts.error.unrecognized', const {}),
      ('a certificate', keyText('openssl/p256.cert.pem'), 'contacts.error.unrecognized', const {}),
      ('more than 1 MB', big, 'contacts.error.tooLarge', const {}),
    ]) {
      testWidgets(name, (tester) async {
        final contacts = await open(tester);

        if (input is String) {
          await paste(contacts, input);
        } else {
          contacts.files.nextPick = PickedFile(name: 'big.asc', bytes: input as Uint8List);
          await contacts.tap(find.text(t('contacts.add.file')));
        }

        expect(errorOnScreen(tester), t(id, args));
        expect(find.byType(ContactReviewSheet), findsNothing);
        expect(find.text(t('contacts.add.importOwn')), findsNothing);
        expect(contacts.contacts, isEmpty);
      });
    }
  });

  testWidgets('a private key is refused, with an offer to import it as the person’s own', (tester) async {
    final contacts = await open(tester);

    await paste(contacts, keyText('gnupg/ed25519.secret.asc'));

    expect(errorOnScreen(tester), t('contacts.error.privateKeyGiven'));
    expect(contacts.contacts, isEmpty);
    await contacts.tap(find.text(t('contacts.add.importOwn')));

    expect(find.byType(AddContactSheet), findsNothing);
    expect(find.byType(ImportKeySheet), findsOneWidget);
    expect(contacts.app.state.keys, isEmpty);
  });

  testWidgets('a mistake is cleared by the next try', (tester) async {
    final contacts = await open(tester);
    await paste(contacts, 'not a key');
    expect(errorOnScreen(tester), t('contacts.error.unrecognized'));

    await paste(contacts, keyText(alan));

    expect(find.byType(ContactReviewSheet), findsOneWidget);
    expect(find.text('Alan Turing'), findsOneWidget);
  });
}
