// The Decrypt sheet with messages GnuPG made: finding the key, asking for
// a passphrase only when one is needed, naming what cannot be opened, and
// what the sheet shows of an opened message.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/armor.dart';
import 'package:kemlock/crypto/keys/openpgp/message.dart';
import 'package:kemlock/crypto/keys/openpgp/stream.dart';
import 'package:kemlock/crypto/keys/openpgp/usable_keys.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as openpgp;
import 'package:kemlock/features/keys/key_bridge.dart' show vaultKeyOf;
import 'package:kemlock/features/pgp/add_someone_sheet.dart';
import 'package:kemlock/features/pgp/decrypt_sheet.dart';
import 'package:kemlock/features/pgp/encrypt_sheet.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_files.dart';
import '../../helpers/test_app.dart';
import '../contacts/contacts_kit.dart' show contactOf, keyBytes;
import 'pgp_kit.dart';

const _edFingerprint = '1FCD A135 EE42 400E C2B7 7CE6 7724 9ABE 661C F8DB';

/// The fixture as it would be pasted: armored. A binary one is armored
/// here, with the CRC line left out, which a reader must accept.
String _pasted(String fixture) {
  final bytes = fixtureBytes('pgp/$fixture');
  if (fixture.endsWith('.asc')) return utf8.decode(bytes);
  final body = base64.encode(bytes).replaceAllMapped(RegExp('.{1,64}'), (m) => '${m[0]}\n');
  return '-----BEGIN PGP MESSAGE-----\n\n$body-----END PGP MESSAGE-----\n';
}

final _message = utf8.decode(fixtureBytes('pgp/gnupg/message.txt'));

void main() {
  Future<PgpApp> open(WidgetTester tester, {List<String> keys = const ['ed']}) async {
    final pgp = PgpApp(tester);
    await pgp.start(keys: keys);
    await pgp.open('decrypt');
    return pgp;
  }

  Future<void> decrypt(PgpApp pgp, String fixture) async {
    await pgp.enter(t('pgp.decrypt.field'), _pasted(fixture));
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
  }

  /// The severity of the signer banner on screen.
  AlertSeverity banner(WidgetTester tester) => tester.widget<AppAlert>(find.byType(AppAlert)).severity;

  group('finding the key', () {
    testWidgets('a message to the second of three vault keys opens unasked', (tester) async {
      final pgp = await open(tester, keys: ['kemlock-ed', 'rsa', 'ed']);
      await decrypt(pgp, 'gnupg/to-rsa3072.seipd.gpg');
      expect(find.byType(Dialog), findsNothing);
      expect(find.text(t('pgp.decrypted.title')), findsOneWidget);
      expect(find.text(_message), findsOneWidget);
      // In this order: who signed it, the message, what opened it, how it was encrypted
      final ys = [
        tester.getTopLeft(find.text(t('pgp.decrypted.notSigned'))).dy,
        tester.getTopLeft(find.text(_message)).dy,
        tester.getTopLeft(find.text(t('pgp.decrypted.openedWith'))).dy,
        tester.getTopLeft(find.text(t('pgp.decrypted.encryption'))).dy,
        tester.getTopLeft(find.text(t('pgp.decrypted.copy'))).dy,
        tester.getTopLeft(find.text(t('pgp.decrypted.nothingSaved'))).dy,
      ];
      expect(ys, [...ys]..sort());
      expect(inSheet<DecryptSheet>(find.text('Fixture RSA')), findsOneWidget);
      expect(find.text('RSA 3072, AES-256'), findsOneWidget);
      // One job, given every key of the vault
      expect((pgp.requests.single as DecryptRequest).keys, hasLength(3));
    });

    testWidgets('GnuPG\'s OCB form, and a hidden recipient, open the same way', (tester) async {
      final pgp = await open(tester, keys: ['rsa', 'ed']);
      await decrypt(pgp, 'gnupg/to-ed25519.ocb.gpg');
      expect(find.text(_message), findsOneWidget);
      expect(find.text('X25519, AES-256, OCB'), findsOneWidget);
      await pgp.closeSheet();

      await pgp.open('decrypt');
      await decrypt(pgp, 'gnupg/hidden.gpg');
      expect(find.text(_message), findsOneWidget);
      expect(inSheet<DecryptSheet>(find.text('Fixture Ed25519')), findsOneWidget);
      expect(find.text('X25519, AES-256'), findsOneWidget);
    });

    testWidgets('a protected key asks by name, and again for a second message', (tester) async {
      final pgp = await open(tester, keys: ['ed', 'ed-protected']);
      await decrypt(pgp, 'gnupg/to-protected-ed25519.gpg');
      expect(find.text(t('pgp.keyPassphrase.title', {'name': 'Fixture Ed25519 Protected'})), findsOneWidget);
      expect(find.text(t('pgp.keyPassphrase.body')), findsOneWidget);
      // A first run found the key the message names locked: it asked for nothing else
      await pgp.answerPassphrase(fixturePassphrase);
      expect(find.text(_message), findsOneWidget);
      expect(inSheet<DecryptSheet>(find.text('Fixture Ed25519 Protected')), findsOneWidget);

      await pgp.closeSheet();
      await pgp.open('decrypt');
      await decrypt(pgp, 'gnupg/to-protected-ed25519.gpg');
      expect(find.text(t('pgp.keyPassphrase.title', {'name': 'Fixture Ed25519 Protected'})), findsOneWidget);
      expect(find.text(_message), findsNothing);
    });

    testWidgets('a wrong passphrase says so and asks again; nothing is decrypted meanwhile', (tester) async {
      final pgp = await open(tester, keys: ['rsa-protected']);
      await decrypt(pgp, 'gnupg/to-protected-rsa3072.gpg');
      await pgp.answerPassphrase('wrong');
      expect(find.text(t('pgp.error.wrongKeyPassphrase')), findsOneWidget);
      expect(find.text(t('pgp.keyPassphrase.title', {'name': 'Fixture RSA Protected'})), findsOneWidget);
      expect(find.text(_message), findsNothing);
      await pgp.answerPassphrase(fixturePassphrase);
      expect(find.text(_message), findsOneWidget);
    });

    // openspec: add-post-quantum-pgp, task 6.6
    for (final (key, name, file, armored) in [
      ('sq-protected', 'Fixture Sequoia', 'keys/sequoia/pqc/message.pgp', true),
      ('kyber-protected', 'Fixture Kyber Protected', 'keys/gnupg/pqc/ky768-cv25519-protected.message.gpg', false),
    ]) {
      testWidgets('a protected post-quantum key, $key, asks, refuses a wrong passphrase and decrypts with the right one', (tester) async {
        final pgp = await open(tester, keys: [key]);
        final plain = utf8.decode(
          fixtureBytes(file.startsWith('keys/sequoia') ? 'keys/sequoia/pqc/message.txt' : 'keys/gnupg/pqc/message.txt'),
        );
        if (armored) {
          await pgp.enter(t('pgp.decrypt.field'), fixtureText(file));
          await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
        } else {
          await decrypt(pgp, '../$file');
        }
        expect(find.text(t('pgp.keyPassphrase.title', {'name': name})), findsOneWidget);
        await pgp.answerPassphrase('wrong');
        expect(find.text(t('pgp.error.wrongKeyPassphrase')), findsOneWidget);
        expect(find.text(plain), findsNothing);
        await pgp.answerPassphrase(fixturePassphrase);
        expect(find.text(plain), findsOneWidget);
      });
    }

    testWidgets('cancelling the prompt leaves the message where it was pasted', (tester) async {
      final pgp = await open(tester, keys: ['rsa-protected']);
      await decrypt(pgp, 'gnupg/to-protected-rsa3072.gpg');
      await pgp.tap(find.descendant(of: find.byType(Dialog), matching: find.text(t('pgp.cancel'))));
      expect(find.text(t('pgp.decrypt.title')), findsWidgets);
      expect(
        tester.widget<TextField>(find.widgetWithText(TextField, t('pgp.decrypt.field'))).controller!.text,
        contains('BEGIN PGP MESSAGE'),
      );
      expect(pgp.requests, hasLength(1));
    });
  });

  group('with a passphrase', () {
    testWidgets('a gpg -c message asks for its passphrase; a wrong one is retried without pasting again', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/sym-default.gpg');
      expect(find.text(t('pgp.messagePassphrase.title')), findsOneWidget);
      await pgp.answerPassphrase('a typing mistake');
      expect(find.text(t('pgp.error.wrongPassphrase')), findsOneWidget);
      expect(find.text(_message), findsNothing);

      await pgp.answerPassphrase(fixturePassphrase);
      expect(find.text(_message), findsOneWidget);
      // Opened with a passphrase, in place of a key's name
      expect(find.text(t('pgp.decrypted.aPassphrase')), findsOneWidget);
      expect(find.text('AES-256'), findsOneWidget);

      // A second message with the same passphrase is asked for again
      await pgp.closeSheet();
      await pgp.open('decrypt');
      await decrypt(pgp, 'gnupg/sym-ocb.gpg');
      expect(find.text(t('pgp.messagePassphrase.title')), findsOneWidget);
      await pgp.answerPassphrase(fixturePassphrase);
      expect(find.text('AES-256, OCB'), findsOneWidget);
    });

    testWidgets('it needs no key: a vault that holds nothing opens it', (tester) async {
      final pgp = await open(tester, keys: const []);
      await decrypt(pgp, 'gnupg/sym-default.gpg');
      await pgp.answerPassphrase(fixturePassphrase);
      expect(find.text(_message), findsOneWidget);
    });

    testWidgets('a -c -e message opens with the key, and asks for the passphrase only without it', (tester) async {
      final withKey = await open(tester);
      await decrypt(withKey, 'gnupg/sym-and-key.gpg');
      expect(find.byType(Dialog), findsNothing);
      expect(find.text(_message), findsOneWidget);
      expect(inSheet<DecryptSheet>(find.text('Fixture Ed25519')), findsOneWidget);
    });

    testWidgets('the same message in a vault without that key asks for the passphrase', (tester) async {
      final pgp = await open(tester, keys: ['rsa']);
      await decrypt(pgp, 'gnupg/sym-and-key.gpg');
      expect(find.text(t('pgp.messagePassphrase.title')), findsOneWidget);
      await pgp.answerPassphrase(fixturePassphrase);
      expect(find.text(_message), findsOneWidget);
      expect(find.text(t('pgp.decrypted.aPassphrase')), findsOneWidget);
    });
  });

  group('what is not opened says why', () {
    testWidgets('ordinary text, a message for someone else, CAST5, Argon2, no integrity, a damaged one', (tester) async {
      final pgp = await open(tester);
      Future<void> expectError(String input, String message, {bool armor = true}) async {
        await pgp.enter(t('pgp.decrypt.field'), armor ? _pasted(input) : input);
        await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
        expect(find.text(message), findsOneWidget, reason: input);
        expect(find.byType(Dialog), findsNothing, reason: 'no passphrase is asked for');
        expect(find.text(t('pgp.decrypted.title')), findsNothing);
      }

      await expectError('Dear Ada,\nsee you on Monday.', t('pgp.error.notAMessage'), armor: false);
      await expectError('gnupg/to-rsa3072.seipd.gpg', t('pgp.error.noKeyOpensIt', {'ids': 'B8A3CCC781F74F29'}));
      await expectError('gnupg/sym-cast5.gpg', t('pgp.error.unsupported', {'name': 'CAST5'}));
      await expectError('gnupg/cast5.gpg', t('pgp.error.unsupported', {'name': 'CAST5'}));
      await expectError('gnupg/no-mdc.gpg', t('pgp.error.noIntegrity'));
      await expectError('gnupg/message.txt.ed25519.asc', t('pgp.error.isSignature'));
      await expectError(fixtureText('keys/gnupg/rsa3072.public.asc'), t('pgp.error.isKey'), armor: false);

      // An SKESK with Argon2, then encrypted data: named before any passphrase
      final argon2 = Uint8List.fromList([0xc3, 22, 4, 7, 4, ...List.filled(16, 1), 1, 4, 21, 0xd2, 3, 1, 2, 3]);
      final armored = '-----BEGIN PGP MESSAGE-----\n\n${base64.encode(argon2)}\n-----END PGP MESSAGE-----\n';
      await expectError(armored, t('pgp.error.unsupported', {'name': 'Argon2'}), armor: false);

      // One character of the encrypted data changed
      final damaged = _pasted('gnupg/armored.asc').split('\n');
      damaged[5] = damaged[5].replaceRange(10, 11, damaged[5][10] == 'A' ? 'B' : 'A');
      await expectError(damaged.join('\n'), t('pgp.error.damaged'), armor: false);
      expect(find.text(_message), findsNothing);
    });

    testWidgets('a key the vault cannot use is named: NIST P-256, and a stub with no secret', (tester) async {
      final pgp = await open(tester, keys: ['nistp256']);
      await decrypt(pgp, 'gnupg/to-nistp256.gpg');
      expect(find.text(t('pgp.error.unsupportedKey', {'name': 'nistp256'})), findsOneWidget);
      expect(find.text(_message), findsNothing);
    });
  });

  group('the decrypted sheet', () {
    testWidgets('signed by one of the vault\'s keys: the success banner, with name and fingerprint above the text', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/signed-encrypted.gpg');
      expect(banner(tester), AlertSeverity.success);
      expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Fixture Ed25519'})), findsOneWidget);
      expect(find.text(t('pgp.decrypted.matchesYours')), findsOneWidget);
      expect(find.text(_edFingerprint), findsOneWidget);
      expect(tester.getTopLeft(find.text(_edFingerprint)).dy, lessThan(tester.getTopLeft(find.text(_message)).dy));
      expect(find.textContaining(RegExp('^Signed on ')), findsOneWidget);
    });

    testWidgets('an unsigned message says anyone could have written it', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/to-ed25519.seipd.gpg');
      expect(find.text(t('pgp.decrypted.notSigned')), findsOneWidget);
      expect(find.byType(AppAlert), findsNothing);
    });

    testWidgets('an unknown signer: a warning with the fingerprint; giving their key makes it good, not checked', (tester) async {
      final pgp = await open(tester);
      // Signed by the RSA key, which this vault does not hold
      await decrypt(pgp, 'gnupg/signed-bzip2.ocb.gpg');
      expect(banner(tester), AlertSeverity.warning);
      expect(find.text(t('pgp.signature.unknown')), findsOneWidget);
      expect(find.text('EA29 C79D 1C65 7027 7907 BB48 5D49 D28C 8EFC 2F98'), findsOneWidget);

      await pgp.tap(find.text(t('pgp.signature.giveKey')));
      expect(find.byType(AddSomeoneSheet), findsOneWidget);
      await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
      await pgp.enter(t('pgp.people.paste'), fixtureText('keys/gnupg/rsa3072.public.asc'));
      await pgp.tap(find.text(t('pgp.people.read')));
      expect(find.text(t('pgp.people.confirm.bodyForCheck')), findsOneWidget);
      await pgp.tap(find.text(t('pgp.people.useForCheck')));

      expect(banner(tester), AlertSeverity.info);
      expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Fixture RSA'})), findsOneWidget);
      expect(find.text(t('pgp.decrypted.matchesGiven')), findsOneWidget);
    });

    testWidgets('signed by one of the other people\'s keys: named as that contact, and a reply warns it isn\'t checked', (tester) async {
      final pgp = PgpApp(tester);
      await pgp.start(keys: ['ed']);
      await pgp.addContact(contactOf('gnupg/rsa3072.public.asc', id: 'c-rsa', name: 'Rosalind Franklin'));
      await pgp.open('decrypt');
      // Signed by the RSA key, which the vault keeps as a contact, not as its own
      await decrypt(pgp, 'gnupg/signed-bzip2.ocb.gpg');
      expect(banner(tester), AlertSeverity.info);
      expect(find.text(t('pgp.decrypted.signedBy', {'name': 'Rosalind Franklin'})), findsOneWidget);
      expect(find.text(t('pgp.signature.matchesUnchecked')), findsOneWidget);
      expect(find.text(t('pgp.signature.giveKey')), findsNothing);
      // Every contact's key was there to check against, without being given
      expect(
        (pgp.requests.single as DecryptRequest).verifiers.map(base64.encode),
        contains(base64.encode(keyBytes('gnupg/rsa3072.public.asc'))),
      );

      await pgp.tap(find.text(t('pgp.decrypted.reply')));
      expect(find.byType(EncryptSheet), findsOneWidget);
      expect(tester.widgetList<InputChip>(find.byType(InputChip)).map((c) => (c.label as Text).data), ['Rosalind Franklin']);
      expect(find.text(t('contacts.warning.one', {'name': 'Rosalind Franklin'})), findsOneWidget);
    });

    testWidgets('a bad signature is an error, and the text is still shown as what it is', (tester) async {
      final pgp = await open(tester);
      // The clear-signed fixture with one word changed, pasted into Decrypt
      final changed = fixtureText('pgp/gnupg/clearsigned.asc').replaceFirst('A message', 'A massage');
      await pgp.enter(t('pgp.decrypt.field'), changed);
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(banner(tester), AlertSeverity.error);
      expect(find.text(t('pgp.signature.bad')), findsOneWidget);
      // Not encrypted: no "Opened with", and the title says what it is
      expect(find.text(t('pgp.decrypted.titleSigned')), findsOneWidget);
      expect(find.text(t('pgp.decrypted.openedWith')), findsNothing);
    });

    testWidgets('a message to a since-revoked key opens, with a note that the key is revoked', (tester) async {
      final pgp = await open(tester, keys: ['revoked']);
      // Neither GnuPG nor Kemlock's own entry point encrypts to a revoked
      // key, so the message is written a layer down, to its subkey's packet
      final revoked = base64.decode(pgp.app.state.keys.single.publicKey!);
      final armored = (await tester.runAsync(() async {
        final subkey = (await PgpCertificate.read(revoked)).subkeys.single.packet;
        final out = BytesSink();
        await writeEncryptedMessage(
          data: BytesSource(Uint8List.fromList(utf8.encode('old mail, from before the key was revoked'))),
          out: out,
          recipients: [subkey],
          format: 0x75,
          definite: true,
          random: openpgp.MessageRandom.secure([subkey]),
          time: DateTime.utc(2026, 1, 1),
        );
        return writeArmor(pgpMessageBlock, out.takeBytes());
      }))!;

      await pgp.enter(t('pgp.decrypt.field'), armored);
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      // It still opens: old mail stays readable
      expect(find.text('old mail, from before the key was revoked'), findsOneWidget);
      expect(inSheet<DecryptSheet>(find.text('Fixture Revoked')), findsOneWidget);
      expect(find.text(t('pgp.decrypted.keyRevoked')), findsOneWidget);
    });

    testWidgets('Copy puts the text on the clipboard that clears itself', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/to-ed25519.seipd.gpg');
      await pgp.tap(find.text(t('pgp.decrypted.copy')));
      expect(pgp.copies, [_message]);
      expect(find.text(t('pgp.decrypted.copied')), findsOneWidget);
    });

    testWidgets('Reply encrypted opens Encrypt with the signer as recipient and an empty message', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/signed-encrypted.gpg');
      await pgp.tap(find.text(t('pgp.decrypted.reply')));
      expect(find.byType(DecryptSheet), findsNothing);
      expect(find.byType(EncryptSheet), findsOneWidget);
      expect(tester.widgetList<InputChip>(find.byType(InputChip)).map((c) => (c.label as Text).data), ['Fixture Ed25519']);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, t('pgp.encrypt.message'))).controller!.text, isEmpty);
    });

    testWidgets('Reply encrypted to an unknown signer opens Encrypt with no recipient', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/signed-bzip2.ocb.gpg');
      // A file result has its reply button too
      await pgp.tap(find.text(t('pgp.decrypted.reply')));
      expect(find.byType(EncryptSheet), findsOneWidget);
      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('closing and reopening shows an empty sheet', (tester) async {
      final pgp = await open(tester);
      await decrypt(pgp, 'gnupg/to-ed25519.seipd.gpg');
      expect(find.text(_message), findsOneWidget);
      await pgp.closeSheet();
      expect(find.text(_message), findsNothing);
      await pgp.open('decrypt');
      expect(find.text(t('pgp.decrypt.title')), findsWidgets);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, t('pgp.decrypt.field'))).controller!.text, isEmpty);
      expect(find.text(_message), findsNothing);
    });

    testWidgets('Paste takes the clipboard\'s text', (tester) async {
      final pgp = await open(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': _pasted('gnupg/armored.asc')};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pgp.tap(find.text(t('pgp.decrypt.paste')));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(find.text(_message), findsOneWidget);
    });
  });

  group('files', () {
    Future<Directory> pick(PgpApp pgp, String fixture, {String? name}) async {
      pgp.files.nextPath = FakeFiles.onDisk(name ?? fixture.split('/').last, fixtureBytes('pgp/$fixture'));
      final directory = File(pgp.files.nextPath!.path).parent;
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      await pgp.tap(find.text(t('pgp.decrypt.chooseFile')));
      return directory;
    }

    testWidgets('a decrypted file shows its name and size, with Save and Share in place of the text and Copy', (tester) async {
      final pgp = await open(tester);
      await pick(pgp, 'gnupg/zlib.gpg');
      expect(find.text('zlib.gpg'), findsOneWidget);
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));

      expect(find.text('report.txt'), findsOneWidget);
      expect(find.text('210.9 KB'), findsOneWidget);
      expect(find.text(t('pgp.decrypted.copy')), findsNothing);
      expect(find.text(t('pgp.decrypted.nothingSavedFile')), findsOneWidget);

      await pgp.tap(find.text(t('pgp.decrypted.save')));
      await pgp.tap(find.text(t('pgp.decrypted.share')));
      expect(pgp.files.saved.map((f) => (f.name, f.shared)), [('report.txt', false), ('report.txt', true)]);
      expect(pgp.files.saved.first.bytes, fixtureBytes('pgp/gnupg/report.txt'));
    });

    testWidgets('a file with no name inside takes the input\'s, without .gpg', (tester) async {
      final pgp = await open(tester);
      // 1 MB from a pipe: GnuPG gave it no name
      await pick(pgp, 'gnupg/chunks.ocb.gpg', name: 'holiday.jpg.gpg');
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(find.text('holiday.jpg'), findsOneWidget);
      expect(find.text('1 MB'), findsOneWidget);
    });

    testWidgets('an armored message chosen as a file, typed as text by its sender, is read on screen', (tester) async {
      final pgp = await open(tester);
      await pick(pgp, 'kemlock/to-ed25519.asc');
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(find.text(_message), findsOneWidget);
      expect(find.text(t('pgp.decrypted.copy')), findsOneWidget);
    });

    testWidgets('a file cut short offers nothing and leaves nothing', (tester) async {
      final pgp = await open(tester);
      final whole = fixtureBytes('pgp/gnupg/uncompressed.gpg');
      pgp.files.nextPath = FakeFiles.onDisk('cut.gpg', whole.sublist(0, whole.length - 5000));
      final directory = File(pgp.files.nextPath!.path).parent;
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      await pgp.tap(find.text(t('pgp.decrypt.chooseFile')));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(find.text(t('pgp.error.damaged')), findsOneWidget);
      expect(find.text(t('pgp.decrypted.save')), findsNothing);
      expect(pgp.tempEntries, isEmpty);
    });
  });

  // openspec: add-post-quantum-pgp, task 8.3
  testWidgets("the Encryption row names ML-KEM-768 + X25519 for RFC 9980's sample", (tester) async {
    final pgp = PgpApp(tester);
    await pgp.start();
    final parsed = (await tester.runAsync(() => crypto.readPrivateKey(fixtureBytes('keys/rfc9980/a1-secret.asc'))))!;
    await tester.runAsync(
      () => pgp.app.container
          .read(vaultControllerProvider.notifier)
          .addKey(vaultKeyOf(parsed, id: 'pgp-a1', name: 'RFC 9980 A.1', origin: KeyOrigin.imported)),
    );
    await tester.pump(const Duration(seconds: 10));
    await pgp.open('decrypt');
    await pgp.enter(t('pgp.decrypt.field'), fixtureText('keys/rfc9980/a1-message.asc'));
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
    expect(find.text('Testing\n'), findsOneWidget);
    expect(find.text('ML-KEM-768 + X25519, AES-256, OCB'), findsOneWidget);
  });
}
