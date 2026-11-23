// The Encrypt sheet: to people and with a passphrase, a message and a
// file, signed or not; what it shares, and that nothing of it is kept.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as openpgp;
import 'package:kemlock/features/pgp/add_someone_sheet.dart';
import 'package:kemlock/features/pgp/encrypt_sheet.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../contacts/contacts_kit.dart' show alan, alanFingerprint, contactOf, grace1, keyBytes;
import 'pgp_kit.dart';

const _edFingerprint = '1FCDA135EE42400EC2B77CE677249ABE661CF8DB';

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  Future<PgpApp> open(WidgetTester tester, {List<String> keys = const ['ed']}) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: keys);
    await pgp.open('encrypt');
    return pgp;
  }

  Future<void> addOwn(PgpApp pgp, String name) async {
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text(name)));
  }

  Future<void> addPasted(PgpApp pgp, String fixture) async {
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
    await pgp.enter(t('pgp.people.paste'), fixtureText(fixture));
    await pgp.tap(find.text(t('pgp.people.read')));
    await pgp.tap(find.text(t('pgp.people.use')));
  }

  FilledButton mainButton(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('pgp.encrypt.button')));

  Switch switchOf(WidgetTester tester, String label) => tester.widget<Switch>(
    find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(PgpSwitchRow)),
      matching: find.byType(Switch),
    ),
  );

  testWidgets('as Encrypt.dc.html draws it: the tabs, To, the message, the two switches, the button', (tester) async {
    final pgp = await open(tester);
    expect(find.text(t('pgp.encrypt.toPeople')), findsOneWidget);
    expect(find.text(t('pgp.encrypt.withPassphrase')), findsOneWidget);
    expect(find.text(t('pgp.encrypt.to').toUpperCase()), findsOneWidget);
    expect(find.text(t('pgp.encrypt.addSomeone')), findsOneWidget);
    expect(find.text(t('pgp.encrypt.chooseFile')), findsOneWidget);
    expect(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})), findsOneWidget);
    expect(find.text(t('pgp.encrypt.signAs.body')), findsOneWidget);
    expect(find.text(t('pgp.encrypt.alsoToMe')), findsOneWidget);
    // Both on by default when the vault holds a usable key
    expect(switchOf(tester, t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})).value, isTrue);
    expect(switchOf(tester, t('pgp.encrypt.alsoToMe')).value, isTrue);
    expect(pgp.requests, isEmpty);
  });

  testWidgets('two recipients, one of them unchecked: both fixture keys decrypt the message', (tester) async {
    final pgp = await open(tester, keys: ['kemlock-ed', 'ed']);
    await addOwn(pgp, 'Fixture Ed25519');
    await addPasted(pgp, 'keys/gnupg/rsa3072.public.asc');
    // The warning names the unchecked person, before encrypting
    expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Fixture RSA'})), findsOneWidget);

    await pgp.enter(t('pgp.encrypt.message'), 'The draft is attached.\nTell me what you think before Friday.');
    await pgp.tap(find.text(t('pgp.encrypt.button')));

    final shared = pgp.files.sharedTexts.single;
    expect(shared, startsWith('-----BEGIN PGP MESSAGE-----\n'));
    expect(shared.trimRight(), endsWith('-----END PGP MESSAGE-----'));
    // And at the time of encrypting the warning is still there
    expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Fixture RSA'})), findsOneWidget);

    for (final key in ['ed', 'rsa', 'kemlock-ed']) {
      final message = await decryptWith(tester, _utf8(shared), keys: [key], verifiers: ['kemlock-ed']);
      expect(utf8.decode(message.bytes!), 'The draft is attached.\nTell me what you think before Friday.', reason: key);
      expect(message.isText, isTrue);
      // Signed inside the encryption by the vault's first key, which also got a copy
      expect(message.signatures.single.verdict, openpgp.SignatureVerdict.good);
    }
    // Nobody else can open it
    final request = pgp.requests.single as EncryptRequest;
    expect(request.recipients, hasLength(3));
    expect(request.signer, isNotNull);
    expect(request.passphrase, isNull);
  });

  testWidgets('it stays there to share again until the sheet is closed', (tester) async {
    final pgp = await open(tester);
    await pgp.enter(t('pgp.encrypt.message'), 'again');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect(pgp.files.sharedTexts, hasLength(1));
    await pgp.tap(find.text(t('pgp.encrypt.shareAgain')));
    expect(pgp.files.sharedTexts, hasLength(2));
    expect(pgp.files.sharedTexts[1], pgp.files.sharedTexts[0]);
    // One encryption, shared twice
    expect(pgp.requests, hasLength(1));
  });

  testWidgets('no recipient disables the button, with its hint', (tester) async {
    final pgp = await open(tester);
    await pgp.enter(t('pgp.encrypt.message'), 'to nobody');
    // "Also encrypt to me" is a recipient: with it on, the button works
    expect(mainButton(tester).onPressed, isNotNull);
    expect(find.text(t('pgp.encrypt.noRecipient')), findsNothing);

    await pgp.tap(
      find.descendant(
        of: find.ancestor(of: find.text(t('pgp.encrypt.alsoToMe')), matching: find.byType(PgpSwitchRow)),
        matching: find.byType(Switch),
      ),
    );
    expect(mainButton(tester).onPressed, isNull);
    expect(find.text(t('pgp.encrypt.noRecipient')), findsOneWidget);
    await tester.tap(find.text(t('pgp.encrypt.button')));
    await pgp.settle(2);
    expect(pgp.requests, isEmpty);
    expect(pgp.files.sharedTexts, isEmpty);

    await addPasted(pgp, 'keys/gnupg/rsa3072.public.asc');
    expect(mainButton(tester).onPressed, isNotNull);
    expect(find.text(t('pgp.encrypt.noRecipient')), findsNothing);
  });

  testWidgets('"Sign as" off gives an unsigned message; "Also encrypt to me" on lets the sender read it', (tester) async {
    final pgp = await open(tester);
    await pgp.tap(
      find.descendant(
        of: find.ancestor(of: find.text(t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})), matching: find.byType(PgpSwitchRow)),
        matching: find.byType(Switch),
      ),
    );
    await pgp.enter(t('pgp.encrypt.message'), 'unsigned');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect((pgp.requests.single as EncryptRequest).signer, isNull);
    final message = await decryptWith(tester, _utf8(pgp.files.sharedTexts.single), keys: ['ed'], verifiers: ['ed']);
    expect(utf8.decode(message.bytes!), 'unsigned');
    expect(message.signatures, isEmpty);
    expect(message.openedWithFingerprint, _edFingerprint);
  });

  testWidgets('with several keys, the "Sign as" row chooses which, and "Also encrypt to me" follows', (tester) async {
    final pgp = await open(tester, keys: ['ed', 'rsa']);
    expect(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})), findsOneWidget);
    await pgp.tap(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})));
    expect(find.text(t('pgp.signer.title')), findsWidgets);
    await pgp.tap(find.text('rsa@example.org'));
    expect(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture RSA'})), findsOneWidget);

    await pgp.enter(t('pgp.encrypt.message'), 'from the other key');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    final shared = _utf8(pgp.files.sharedTexts.single);
    final message = await decryptWith(tester, shared, keys: ['rsa'], verifiers: ['rsa']);
    expect(message.signatures.single.signerFingerprint, 'EA29C79D1C6570277907BB485D49D28C8EFC2F98');
    // The other key of the vault got no copy
    await expectLater(decryptWith(tester, shared, keys: ['ed']), throwsA(isA<openpgp.PgpException>()));

    // The next sheet offers the same key again
    await pgp.closeSheet();
    await pgp.open('encrypt');
    expect(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture RSA'})), findsOneWidget);
  });

  testWidgets('a protected signer asks for its passphrase, and again after a wrong one', (tester) async {
    final pgp = await open(tester, keys: ['ed-protected']);
    await pgp.enter(t('pgp.encrypt.message'), 'signed with a locked key');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect(find.text(t('pgp.keyPassphrase.title', {'name': 'Fixture Ed25519 Protected'})), findsOneWidget);
    expect(pgp.files.sharedTexts, isEmpty, reason: 'nothing is encrypted before the passphrase');

    await pgp.answerPassphrase('not the passphrase');
    expect(find.text(t('pgp.error.wrongKeyPassphrase')), findsOneWidget);
    expect(pgp.files.sharedTexts, isEmpty);

    await pgp.answerPassphrase(fixturePassphrase);
    expect(find.byType(Dialog), findsNothing);
    final message = await decryptWith(tester, _utf8(pgp.files.sharedTexts.single), keys: ['ed-protected'], verifiers: ['ed-protected']);
    expect(message.signatures.single.verdict, openpgp.SignatureVerdict.good);

    // Asked again the next time: nothing was kept
    await pgp.enter(t('pgp.encrypt.message'), 'a second message');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect(find.text(t('pgp.keyPassphrase.title', {'name': 'Fixture Ed25519 Protected'})), findsOneWidget);
    // Cancelling the prompt encrypts nothing
    await pgp.tap(find.descendant(of: find.byType(Dialog), matching: find.text(t('pgp.cancel'))));
    expect(pgp.files.sharedTexts, hasLength(1));
  });

  testWidgets('a file gives <name>.gpg, shown by name and size in place of the message', (tester) async {
    final pgp = await open(tester);
    final content = Uint8List.fromList(List.generate(70000, (i) => i * 7 & 0xff));
    pgp.files.nextPath = FakeFiles.onDisk('report.pdf', content);
    final picked = File(pgp.files.nextPath!.path).parent;
    addTearDown(() {
      if (picked.existsSync()) picked.deleteSync(recursive: true);
    });
    await pgp.tap(find.text(t('pgp.encrypt.chooseFile')));
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('68.4 KB'), findsOneWidget);
    expect(find.widgetWithText(TextField, t('pgp.encrypt.message')), findsNothing);
    expect(find.text(t('pgp.encrypt.writeMessage')), findsOneWidget);

    await pgp.tap(find.text(t('pgp.encrypt.button')));
    final shared = pgp.files.saved.single;
    expect((shared.name, shared.shared), ('report.pdf.gpg', true));
    expect(pgp.files.sharedTexts, isEmpty);
    // Binary, not armored
    expect(shared.bytes[0] & 0x80, 0x80);
    final message = await decryptWith(tester, shared.bytes, keys: ['ed'], verifiers: ['ed']);
    expect(message.bytes, content);
    expect((message.fileName, message.isText), ('report.pdf', false));
    expect(message.signatures.single.verdict, openpgp.SignatureVerdict.good);
  });

  testWidgets('an expired recipient stops it, saying whose key has expired', (tester) async {
    final pgp = await open(tester, keys: ['ed', 'expired']);
    await addOwn(pgp, 'Fixture Expired');
    await pgp.enter(t('pgp.encrypt.message'), 'not sent');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect(find.text(t('pgp.standing.expired', {'name': 'Fixture Expired'})), findsOneWidget);
    expect(pgp.files.sharedTexts, isEmpty);
  });

  testWidgets('closing and reopening shows no earlier recipient, text or result', (tester) async {
    final pgp = await open(tester);
    await addPasted(pgp, 'keys/gnupg/rsa3072.public.asc');
    await pgp.enter(t('pgp.encrypt.message'), 'gone when the sheet closes');
    await pgp.tap(find.text(t('pgp.encrypt.button')));
    expect(find.text(t('pgp.encrypt.shareAgain')), findsOneWidget);

    await pgp.closeSheet();
    expect(find.byType(EncryptSheet), findsNothing);
    await pgp.open('encrypt');
    expect(find.byType(InputChip), findsNothing);
    expect(find.text('gone when the sheet closes'), findsNothing);
    expect(find.text(t('pgp.encrypt.shareAgain')), findsNothing);
    // And the key given earlier is not offered
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    expect(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Fixture RSA')), findsNothing);
  });

  group('with a passphrase', () {
    Future<void> choosePassphrase(PgpApp pgp) => pgp.tap(find.text(t('pgp.encrypt.withPassphrase')));

    testWidgets('matching passphrases give a message that opens with it', (tester) async {
      final pgp = await open(tester);
      await choosePassphrase(pgp);
      // "Also encrypt to me" is for people; "Sign as" stays
      expect(find.text(t('pgp.encrypt.alsoToMe')), findsNothing);
      expect(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})), findsOneWidget);
      expect(find.text(t('pgp.encrypt.to').toUpperCase()), findsNothing);

      await pgp.enter(t('pgp.encrypt.passphrase'), 'correct horse');
      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'correct horse');
      await pgp.enter(t('pgp.encrypt.message'), 'for whoever knows the words');
      await pgp.tap(find.text(t('pgp.encrypt.button')));

      final shared = _utf8(pgp.files.sharedTexts.single);
      expect(utf8.decode(shared), startsWith('-----BEGIN PGP MESSAGE-----'));
      final request = pgp.requests.single as EncryptRequest;
      expect(request.recipients, isEmpty);
      expect(request.passphrase, 'correct horse');
      final message = await decryptWith(tester, shared, passphrase: 'correct horse', verifiers: ['ed']);
      expect(utf8.decode(message.bytes!), 'for whoever knows the words');
      expect(message.openedWithPassphrase, isTrue);
      // "Sign as" works there too
      expect(message.signatures.single.signerFingerprint, _edFingerprint);
      await expectLater(decryptWith(tester, shared, passphrase: 'correct horses'), throwsA(isA<openpgp.PgpException>()));
    });

    testWidgets('differing or empty passphrases encrypt nothing, and say they don\'t match', (tester) async {
      final pgp = await open(tester);
      await choosePassphrase(pgp);
      await pgp.enter(t('pgp.encrypt.message'), 'not yet');
      expect(mainButton(tester).onPressed, isNull, reason: 'no passphrase');

      await pgp.enter(t('pgp.encrypt.passphrase'), 'correct horse');
      expect(mainButton(tester).onPressed, isNull, reason: 'typed once');
      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'correct hoarse');
      expect(find.text(t('pgp.encrypt.passphraseMismatch')), findsOneWidget);
      expect(mainButton(tester).onPressed, isNull);
      await tester.tap(find.text(t('pgp.encrypt.button')));
      await pgp.settle(2);
      expect(pgp.requests, isEmpty);

      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'correct horse');
      expect(find.text(t('pgp.encrypt.passphraseMismatch')), findsNothing);
      expect(mainButton(tester).onPressed, isNotNull);
    });

    testWidgets('the fields hide what is typed unless asked to show it', (tester) async {
      final pgp = await open(tester);
      await choosePassphrase(pgp);
      bool hidden(String label) => tester.widget<TextField>(find.widgetWithText(TextField, label)).obscureText;
      expect((hidden(t('pgp.encrypt.passphrase')), hidden(t('pgp.encrypt.passphraseAgain'))), (true, true));
      await pgp.tap(find.byTooltip(t('pgp.passphrase.show')).first);
      expect((hidden(t('pgp.encrypt.passphrase')), hidden(t('pgp.encrypt.passphraseAgain'))), (false, false));
      await pgp.tap(find.byTooltip(t('pgp.passphrase.hide')).first);
      expect(hidden(t('pgp.encrypt.passphrase')), isTrue);
    });

    testWidgets('a file under a passphrase is <name>.gpg too', (tester) async {
      final pgp = await open(tester, keys: const []);
      pgp.files.nextPath = FakeFiles.onDisk('notes.txt', utf8.encode('some notes'));
      final picked = File(pgp.files.nextPath!.path).parent;
      addTearDown(() {
        if (picked.existsSync()) picked.deleteSync(recursive: true);
      });
      await pgp.tap(find.text(t('pgp.encrypt.chooseFile')));
      await pgp.enter(t('pgp.encrypt.passphrase'), 'words');
      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'words');
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      expect(pgp.files.saved.single.name, 'notes.txt.gpg');
      final message = await decryptWith(tester, pgp.files.saved.single.bytes, passphrase: 'words');
      expect(utf8.decode(message.bytes!), 'some notes');
    });

    testWidgets('in a vault without a PGP key it is the tab chosen, and "To people" explains', (tester) async {
      final pgp = await open(tester, keys: const []);
      // Opened from the empty vault's own row of buttons
      expect(find.widgetWithText(TextField, t('pgp.encrypt.passphrase')), findsOneWidget);
      // No key: nothing to sign with or to keep a copy for
      expect(find.byType(PgpSwitchRow), findsNothing);

      await pgp.enter(t('pgp.encrypt.passphrase'), 'no key needed');
      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'no key needed');
      await pgp.enter(t('pgp.encrypt.message'), 'from an empty vault');
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      final message = await decryptWith(tester, _utf8(pgp.files.sharedTexts.single), passphrase: 'no key needed');
      expect(utf8.decode(message.bytes!), 'from an empty vault');
      expect(message.signatures, isEmpty);

      await pgp.tap(find.text(t('pgp.encrypt.toPeople')));
      expect(find.text(t('pgp.encrypt.noKey')), findsOneWidget);
      expect(mainButton(tester).onPressed, isNull);
    });

    testWidgets('two messages with one passphrase differ', (tester) async {
      final pgp = await open(tester, keys: const []);
      await pgp.enter(t('pgp.encrypt.passphrase'), 'same');
      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'same');
      await pgp.enter(t('pgp.encrypt.message'), 'the same text');
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      await pgp.enter(t('pgp.encrypt.message'), 'the same text ');
      await pgp.enter(t('pgp.encrypt.message'), 'the same text');
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      expect(pgp.files.sharedTexts, hasLength(2));
      expect(pgp.files.sharedTexts[0], isNot(pgp.files.sharedTexts[1]));
    });
  });

  // The other people's keys the vault keeps as recipients, and the warning
  // about those never checked (openspec: add-pgp-contacts, task 9.2)
  group('to other people\'s keys', () {
    final checkedAt = DateTime(2026, 10, 3, 9).millisecondsSinceEpoch;

    /// Opens Encrypt in a vault holding the Ed25519 key, Alan Turing's key
    /// unchecked and Grace Hopper's checked.
    Future<PgpApp> openWithContacts(WidgetTester tester) async {
      final pgp = PgpApp(tester);
      await pgp.start(keys: ['ed']);
      await pgp.addContact(contactOf(alan, id: 'c-alan', name: 'Alan Turing'));
      await pgp.addContact(contactOf(grace1, id: 'c-grace', checkedAt: checkedAt));
      await pgp.open('encrypt');
      return pgp;
    }

    Future<void> addContact(PgpApp pgp, String name) async {
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text(name)));
    }

    Finder warning() => find.byKey(const ValueKey('unchecked-recipients'));

    List<String> encryptedTo(PgpApp pgp) => [for (final key in (pgp.requests.last as EncryptRequest).recipients) base64.encode(key)];

    testWidgets('an unchecked contact warns with "Check now" each time it is encrypted to, and only once', (tester) async {
      final pgp = await openWithContacts(tester);
      for (var time = 0; time < 2; time++) {
        await addContact(pgp, 'Alan Turing');
        expect(find.text(t('contacts.warning.one', {'name': 'Alan Turing'})), findsOneWidget, reason: 'time $time');
        expect(find.descendant(of: warning(), matching: find.text(t('contacts.warning.check'))), findsOneWidget);
        // The sheet's own line is for keys given for one message: nobody is warned twice
        expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Alan Turing'})), findsNothing);
        // Above the button
        expect(tester.getTopLeft(warning()).dy, lessThan(tester.getTopLeft(find.text(t('pgp.encrypt.button'))).dy));

        await pgp.enter(t('pgp.encrypt.message'), 'to Alan, time $time');
        await pgp.tap(find.text(t('pgp.encrypt.button')));
        expect(pgp.files.sharedTexts, hasLength(time + 1));
        expect(encryptedTo(pgp), contains(base64.encode(keyBytes(alan))));
        // And at the time of encrypting it is still there
        expect(warning(), findsOneWidget);

        await pgp.closeSheet();
        await pgp.open('encrypt');
      }

      // Checked from the warning, it warns no more
      await addContact(pgp, 'Alan Turing');
      await pgp.tap(find.descendant(of: warning(), matching: find.text(t('contacts.warning.check'))));
      expect(find.byKey(const ValueKey('check-fingerprint')), findsOneWidget);
      await pgp.tap(find.text(t('contacts.sheet.check.confirm')));
      pgp.hideToast();
      await tester.pumpAndSettle();
      expect(warning(), findsNothing);
      expect(pgp.app.state.contacts.firstWhere((c) => c.id == 'c-alan').checkedFingerprint, alanFingerprint);
      expect(find.byType(InputChip), findsOneWidget);
    });

    testWidgets('a checked contact warns of nothing; a key pasted for one message keeps the sheet\'s own line', (tester) async {
      final pgp = await openWithContacts(tester);
      await addContact(pgp, 'Grace Hopper');
      expect(warning(), findsNothing);
      expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Grace Hopper'})), findsNothing);

      await addPasted(pgp, 'keys/gnupg/rsa3072.public.asc');
      expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Fixture RSA'})), findsOneWidget);
      expect(warning(), findsNothing);

      // With an unchecked contact as well, each is warned about in its own place, once
      await addContact(pgp, 'Alan Turing');
      expect(find.text(t('contacts.warning.one', {'name': 'Alan Turing'})), findsOneWidget);
      expect(find.text(t('pgp.encrypt.unchecked', {'name': 'Fixture RSA'})), findsOneWidget);
      expect(find.text(t('pgp.encrypt.uncheckedMany', {'count': 2})), findsNothing);

      await pgp.enter(t('pgp.encrypt.message'), 'to the three of them');
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      // The three, in the order they were added, then the sender's own copy
      expect(encryptedTo(pgp), hasLength(4));
      expect(encryptedTo(pgp).take(3), [
        base64.encode(keyBytes(grace1)),
        base64.encode(fixtureBytes('keys/gnupg/rsa3072.public.gpg')),
        base64.encode(keyBytes(alan)),
      ]);
    });
  });

  // openspec: add-post-quantum-pgp, task 8.3
  group('the post-quantum line', () {
    Finder line() => find.byKey(const ValueKey('post-quantum-line'));

    testWidgets('every key post-quantum, the own one included: protected', (tester) async {
      final pgp = await open(tester, keys: ['pq-standard', 'kyber-protected']);
      await addOwn(pgp, 'Fixture Kyber Protected');
      expect(find.descendant(of: line(), matching: find.text(t('pgp.encrypt.postQuantum'))), findsOneWidget);
    });

    testWidgets('one classical recipient: not protected, and named', (tester) async {
      final pgp = await open(tester, keys: ['pq-standard', 'kyber-protected']);
      await addOwn(pgp, 'Fixture Kyber Protected');
      await addPasted(pgp, 'keys/gnupg/rsa3072.public.asc');
      expect(find.descendant(of: line(), matching: find.text(t('pgp.encrypt.notPostQuantum', {'name': 'Fixture RSA'}))), findsOneWidget);
    });

    testWidgets('the own classical key, also encrypted to: not protected', (tester) async {
      final pgp = await open(tester, keys: ['ed', 'pq-standard']);
      await addOwn(pgp, 'Ada Lovelace');
      expect(
        find.descendant(of: line(), matching: find.text(t('pgp.encrypt.notPostQuantum', {'name': 'Fixture Ed25519'}))),
        findsOneWidget,
      );
    });

    testWidgets('with a passphrase alone, nothing is said', (tester) async {
      final pgp = await open(tester, keys: ['pq-standard']);
      await pgp.tap(find.text(t('pgp.encrypt.withPassphrase')));
      expect(line(), findsNothing);
    });

    testWidgets("a contact's post-quantum key is encrypted to", (tester) async {
      final pgp = PgpApp(tester);
      await pgp.start(keys: ['pq-standard']);
      await pgp.addContact(contactOf('kemlock/pgp-pq-gnupg.public.asc', id: 'c-pq', name: 'Grace, post-quantum'));
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Grace, post-quantum')));
      expect(find.descendant(of: line(), matching: find.text(t('pgp.encrypt.postQuantum'))), findsOneWidget);
      await pgp.enter(t('pgp.encrypt.message'), 'To a contact, post-quantum.');
      await pgp.tap(find.text(t('pgp.encrypt.button')));
      final request = pgp.requests.last as EncryptRequest;
      expect(request.recipients.map(base64.encode), contains(base64.encode(keyBytes('kemlock/pgp-pq-gnupg.public.asc'))));
    });

    testWidgets('a key Kemlock cannot sign with is not offered to sign as', (tester) async {
      await open(tester, keys: ['mldsa87', 'ed']);
      // RFC 9980's A.4 key, first in the vault, goes by its user ID's name
      expect(find.text(t('pgp.encrypt.signAs', {'name': 'Fixture Ed25519'})), findsOneWidget);
      expect(find.descendant(of: find.byType(EncryptSheet), matching: find.textContaining('PQC user')), findsNothing);
    });
  });
}
