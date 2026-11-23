import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/contacts/contact_review_sheet.dart';
import 'package:kemlock/features/keys/import_key_sheet.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/files.dart';

import '../../helpers/test_app.dart';
import 'keys_kit.dart';

const _passphrase = 'fixture passphrase';

void main() {
  Future<KeysApp> openImport(WidgetTester tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    await keys.openAdd('vault.add.importKey');
    return keys;
  }

  Future<void> pick(KeysApp keys, String path) async {
    final file = keyFixture(path);
    keys.files.nextPick = PickedFile(name: file.uri.pathSegments.last, bytes: file.readAsBytesSync());
    await keys.tap(find.text(t('keys.import.file')));
  }

  Future<void> add(KeysApp keys) => keys.tap(find.text(t('keys.import.add')));

  group('reads', () {
    testWidgets('an OpenSSH key file, named by its comment, with ssh-keygen’s fingerprint', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'openssh/ed25519');

      expect(find.text('SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4'), findsOneWidget);
      expect(find.text(t('keys.kind.ssh')), findsOneWidget);
      expect(find.widgetWithText(TextField, 'fixture ed25519'), findsOneWidget);
      await add(keys);
      final key = keys.keys.single;
      expect((key.name, key.kind, key.algorithm, key.origin), ('fixture ed25519', KeyKind.ssh, 'ed25519', KeyOrigin.imported));
    });

    testWidgets('pasted PKCS#8 PEM text of an ECDSA P-256 key, as a signing key', (tester) async {
      final keys = await openImport(tester);

      await keys.paste(keyFixture('openssl/p256.pkcs8.pem').readAsStringSync());

      expect(find.text(t('keys.kind.signing')), findsOneWidget);
      expect(find.text('ECDSA P-256'), findsOneWidget);
      await add(keys);
      expect((keys.keys.single.kind, keys.keys.single.algorithm), (KeyKind.signing, 'ecdsa-p256'));
    });

    testWidgets('PKCS#8 DER, PKCS#1 and SEC1 keys', (tester) async {
      for (final (path, algorithm) in [('openssl/p256.pkcs8.der', 'ECDSA P-256'), ('openssl/p256.traditional.pem', 'ECDSA P-256')]) {
        final keys = await openImport(tester);
        await pick(keys, path);
        expect(find.text(algorithm), findsOneWidget, reason: path);
      }
    });

    testWidgets('a PGP secret key, with the fingerprint, user IDs and subkeys GnuPG lists', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'gnupg/ed25519.secret.asc');

      final listed = keyFixture('gnupg/ed25519.list.txt').readAsStringSync();
      final fingerprint = RegExp(r'^\s+([0-9A-F]{40})$', multiLine: true).firstMatch(listed)!.group(1)!;
      final grouped = [for (var i = 0; i < 40; i += 4) fingerprint.substring(i, i + 4)].join(' ');
      expect(find.text(grouped), findsOneWidget);
      final uid = RegExp(r'^uid\s+\[[^\]]*\]\s+(.+)$', multiLine: true).firstMatch(listed)!.group(1)!.trim();
      // In the facts and as the name the key is given
      expect(find.text(uid), findsWidgets);
      expect(find.textContaining(t('keys.pgp.encrypt')), findsWidgets);
      await add(keys);
      expect(keys.keys.single.kind, KeyKind.pgp);
    });

    testWidgets('a protected OpenSSH key with its passphrase, kept without it', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'openssh/ed25519.protected');
      expect(find.widgetWithText(TextField, t('keys.import.passphrase')), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, t('keys.import.passphrase')), _passphrase);
      await keys.tap(find.text(t('keys.import.open')));

      expect(find.text('SHA256:vsbOCtY7PSc1SWvXM/w1Rl36BGXbwJkyXbU6ZJaLT+0'), findsOneWidget);
      await add(keys);
      // In the vault without the passphrase: the private half opens on its own
      final parsed = await tester.runAsync(() => crypto.readPrivateKey(unb64(keys.keys.single.privateKey)));
      expect(parsed!.algorithm, 'ed25519');
    });

    testWidgets('a wrong passphrase says so, saves nothing, and can be tried again', (tester) async {
      final keys = await openImport(tester);
      await pick(keys, 'openssh/ed25519.protected');

      await tester.enterText(find.widgetWithText(TextField, t('keys.import.passphrase')), 'not it');
      await keys.tap(find.text(t('keys.import.open')));

      expect(find.text(t('keys.import.error.wrongPassphrase')), findsOneWidget);
      expect(keys.keys, isEmpty);
      await tester.enterText(find.widgetWithText(TextField, t('keys.import.passphrase')), _passphrase);
      await keys.tap(find.text(t('keys.import.open')));
      expect(find.text(t('keys.import.add')), findsOneWidget);
    });

    testWidgets('a PKCS#8 key with an SSH form can be kept as an SSH key', (tester) async {
      final keys = await openImport(tester);
      await keys.paste(keyFixture('openssl/ed25519.pkcs8.pem').readAsStringSync());

      await keys.tap(find.byType(Switch));
      await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'server');
      await add(keys);

      expect(keys.keys.single.kind, KeyKind.ssh);
    });
  });

  group('keeps as given', () {
    testWidgets('a key of an algorithm Kemlock doesn’t know, showing its identifier, and exports it back the same', (tester) async {
      final keys = await openImport(tester);
      final pem = keyFixture('openssl/ed448.pkcs8.pem').readAsStringSync();

      await keys.paste(pem);

      expect(find.text(t('keys.kind.other')), findsOneWidget);
      expect(find.text(t('keys.other.noPublic', {'identifier': '1.3.101.113'})), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'ed448');
      await add(keys);
      final key = keys.keys.single;
      expect((key.kind, key.algorithm, key.publicKey), (KeyKind.other, '1.3.101.113', null));
      final exported = await tester.runAsync(() => crypto.exportPrivateKey(parsedKeyOf(key)));
      final again = await tester.runAsync(() => crypto.readPrivateKey(exported!));
      expect(again!.private, keyFixture('openssl/ed448.pkcs8.der').readAsBytesSync());
    });

    testWidgets('a protected PGP key, without asking for its passphrase, and exports it back byte for byte', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'gnupg/ed25519-protected.secret.asc');

      expect(find.widgetWithText(TextField, t('keys.import.passphrase')), findsNothing);
      expect(find.text(t('keys.pgp.protected')), findsOneWidget);
      await add(keys);
      final key = keys.keys.single;
      expect(key.protected, isTrue);
      // The secret key exactly as the armored file holds it (GnuPG protects a key afresh on each
      // export, so the binary fixture, exported separately, has another salt)
      final asGiven = await tester.runAsync(
        () => crypto.readPrivateKey(keyFixture('gnupg/ed25519-protected.secret.asc').readAsStringSync()),
      );
      expect(unb64(key.privateKey), asGiven!.private);
      final exported = crypto.exportPgpSecretKey(parsedKeyOf(key));
      final again = await tester.runAsync(() => crypto.readPrivateKey(exported));
      expect(again!.private, unb64(key.privateKey));
    });
  });

  group('refuses, saying why, and adds nothing', () {
    for (final (name, input, problem, detail) in [
      ('a public key', 'openssh/ed25519.pub', crypto.KeyProblem.publicKeyOnly, ''),
      ('a legacy encrypted PEM', 'openssl/rsa2048.legacy-aes128.pem', crypto.KeyProblem.legacyPemEncryption, ''),
    ]) {
      testWidgets(name, (tester) async {
        final keys = await openImport(tester);

        await pick(keys, input);

        expect(find.text(t('keys.import.error.${problem.name}', {'detail': detail})), findsOneWidget);
        expect(find.text(t('keys.import.add')), findsNothing);
        expect(keys.keys, isEmpty);
      });
    }

    testWidgets('a PuTTY key', (tester) async {
      final keys = await openImport(tester);

      await keys.paste('PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: x\nPublic-Lines: 2\nAAAA\nAAAA\n');

      expect(find.text(t('keys.import.error.puttyKey', {'detail': ''})), findsOneWidget);
    });

    testWidgets('a cipher Kemlock doesn’t read, by name', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'openssh/ed25519.chacha20-poly1305@openssh.com');
      if (find.widgetWithText(TextField, t('keys.import.passphrase')).evaluate().isNotEmpty) {
        await tester.enterText(find.widgetWithText(TextField, t('keys.import.passphrase')), _passphrase);
        await keys.tap(find.text(t('keys.import.open')));
      }

      expect(find.text(t('keys.import.error.unsupportedCipher', {'detail': 'chacha20-poly1305@openssh.com'})), findsOneWidget);
      expect(keys.keys, isEmpty);
    });

    testWidgets('a file over 1 MB', (tester) async {
      final keys = await openImport(tester);

      keys.files.nextPick = PickedFile(name: 'huge.pem', bytes: Uint8List(crypto.maxKeyInputLength + 1));
      await keys.tap(find.text(t('keys.import.file')));

      expect(find.text(t('keys.import.error.tooLarge', {'detail': ''})), findsOneWidget);
    });

    testWidgets('half a PEM block', (tester) async {
      final keys = await openImport(tester);
      final pem = keyFixture('openssl/p256.pkcs8.pem').readAsStringSync();

      await keys.paste(pem.substring(0, pem.length ~/ 2));

      expect(find.textContaining(RegExp('damaged|isn’t a private key')), findsOneWidget);
      expect(keys.keys, isEmpty);
    });
  });

  testWidgets('the same key twice says which key holds it, and adds one', (tester) async {
    final keys = await openImport(tester);
    await pick(keys, 'openssh/ed25519');
    await add(keys);

    await keys.openAdd('vault.add.importKey');
    await pick(keys, 'openssh/ed25519');
    await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'again');
    await add(keys);

    expect(keys.keys, hasLength(1));
    expect(find.text(t('vault.snack.keyExists', {'name': 'fixture ed25519'})), findsOneWidget);
  });

  // openspec: add-post-quantum-pgp, task 3.5
  group('a post-quantum PGP key', () {
    for (final path in ['sequoia/pqc/standard.secret.asc', 'rfc9980/a2-secret.asc', 'gnupg/pqc/ky768-cv25519.secret.asc']) {
      testWidgets('$path imports once, kept as given, and not twice', (tester) async {
        final keys = await openImport(tester);
        await pick(keys, path);
        await add(keys);
        expect(keys.keys, hasLength(1));
        final kept = keys.keys.single;
        expect(kept.kind, KeyKind.pgp);
        expect(unb64(kept.privateKey), (await crypto.readPrivateKey(keyFixture(path).readAsStringSync())).private);

        // The snack bar of the first, with a long user ID, would cover the sheet
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        await keys.openAdd('vault.add.importKey');
        await pick(keys, path);
        await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'again');
        await add(keys);
        expect(keys.keys, hasLength(1));
        expect(find.text(t('vault.snack.keyExists', {'name': kept.name})), findsOneWidget);
      });
    }

    testWidgets('a public key alone is refused, as for any key', (tester) async {
      final keys = await openImport(tester);
      await keys.paste(keyFixture('sequoia/pqc/standard.public.asc').readAsStringSync());
      expect(find.text(t('keys.import.error.publicKeyOnly', {'detail': ''})), findsOneWidget);
      expect(find.text(t('keys.import.add')), findsNothing);
      expect(keys.keys, isEmpty);
    });
  });

  // openspec: add-pgp-key-editing, design decision 9
  group('a PGP key the vault holds', () {
    Finder update() => find.text(t('keys.change.import.update'));
    Finder additions() => find.byKey(const ValueKey('import-update'));

    Future<KeysApp> holding(WidgetTester tester, String path) async {
      final keys = await openImport(tester);
      await pick(keys, path);
      await add(keys);
      await tester.pump(const Duration(seconds: 10));
      await keys.openAdd('vault.add.importKey');
      return keys;
    }

    testWidgets("GnuPG's newer copy lists what it adds, and updates the held key on confirm", (tester) async {
      final keys = await holding(tester, 'gnupg/editing/signing-subkey.secret.asc');
      final held = keys.keys.single;

      await pick(keys, 'gnupg/editing/signing-subkey.after.secret.asc');

      expect(find.descendant(of: additions(), matching: find.text(t('keys.change.import.held', {'name': held.name}))), findsOneWidget);
      final lines = [
        for (final text in tester.widgetList<Text>(find.descendant(of: additions(), matching: find.byType(Text)))) text.data ?? '',
      ];
      expect(
        lines.where((line) => line.contains(t('keys.change.import.subkey', {'algorithm': 'cv25519', 'purposes': ''}).split(':').first)),
        hasLength(1),
      );
      expect(lines, contains('•  ${t('keys.change.import.userId', {'userId': 'Fixture Signing <signing@work.example.org>'})}'));
      expect(lines.where((line) => line.contains(t('keys.change.import.expiry', {'date': ''}).split(':').first)), hasLength(1));
      expect(find.text(t('keys.import.add')), findsNothing);

      await keys.tap(update());

      expect(keys.keys, hasLength(1));
      final updated = keys.keys.single;
      expect((updated.id, updated.name), (held.id, held.name));
      final info = crypto.readPgpKeyInfo(unb64(updated.publicKey!));
      expect((info.userIds.length, info.subkeys.length), (2, 3));
      expect(find.text(t('keys.change.import.updated', {'name': held.name})), findsOneWidget);
    });

    testWidgets("the same key again shows today's message and adds nothing", (tester) async {
      final keys = await holding(tester, 'gnupg/editing/signing-subkey.secret.asc');

      await pick(keys, 'gnupg/editing/signing-subkey.secret.asc');
      expect(additions(), findsNothing);
      await add(keys);

      expect(keys.keys, hasLength(1));
      expect(find.text(t('vault.snack.keyExists', {'name': keys.keys.single.name})), findsOneWidget);
    });

    testWidgets('a copy carrying a revocation says so before updating', (tester) async {
      final keys = await holding(tester, 'gnupg/editing/protected.secret.asc');
      final held = keys.keys.single;
      final revoked = (await tester.runAsync(
        () => crypto.makeKey(
          crypto.PgpChangeRequest(
            unb64(held.privateKey),
            crypto.ApplyPgpRevocation(keyFixture('gnupg/editing/protected.rev').readAsBytesSync()),
            now: testNow,
          ),
        ),
      ))!;

      keys.files.nextPick = PickedFile(name: 'revoked.gpg', bytes: Uint8List.fromList(revoked.private));
      await keys.tap(find.text(t('keys.import.file')));

      expect(find.descendant(of: additions(), matching: find.text('•  ${t('keys.change.import.revocation')}')), findsOneWidget);
      await keys.tap(update());
      expect(crypto.readPgpKeyInfo(unb64(keys.keys.single.publicKey!)).primary.revoked, isTrue);
      expect(keys.keys.single.protected, isTrue);
    });
  });

  // openspec: add-pgp-contacts, task 4.3
  group('a public key alone', () {
    Finder offer() => find.text(t('keys.import.toContacts'));

    /// Picks another file once one was picked, when the button carries the first file's name.
    Future<void> pickAgain(KeysApp keys, String path) async {
      final file = keyFixture(path);
      keys.files.nextPick = PickedFile(name: file.uri.pathSegments.last, bytes: file.readAsBytesSync());
      await keys.tap(find.byIcon(Icons.folder_open_rounded));
    }

    testWidgets('that is an OpenPGP key is still refused here, with an offer to keep it with other people’s keys', (tester) async {
      final keys = await openImport(tester);

      await keys.paste(keyFixture('contacts/grace-1.public.asc').readAsStringSync());

      expect(find.text(t('keys.import.error.publicKeyOnly', {'detail': ''})), findsOneWidget);
      expect(find.text(t('keys.import.add')), findsNothing);
      expect(offer(), findsOneWidget);

      await keys.tap(offer());

      expect(find.byType(ImportKeySheet), findsNothing);
      expect(find.byType(ContactReviewSheet), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text(t('contacts.source.paste')), findsOneWidget);
      expect(keys.keys, isEmpty);
      expect(keys.app.state.contacts, isEmpty, reason: 'nothing is kept until the review is answered');
    });

    testWidgets('chosen as a binary file reaches the review as a file', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'gnupg/ed25519.public.gpg');
      await keys.tap(offer());

      expect(find.byType(ContactReviewSheet), findsOneWidget);
      expect(find.text(t('contacts.source.file')), findsOneWidget);
    });

    testWidgets('that is an SSH key gets the message and no offer', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'openssh/ed25519.pub');

      expect(find.text(t('keys.import.error.publicKeyOnly', {'detail': ''})), findsOneWidget);
      expect(offer(), findsNothing);
    });

    testWidgets('that is a certificate, or an OpenPGP key that fails its own checks, gets no offer either', (tester) async {
      final keys = await openImport(tester);

      await pick(keys, 'openssl/p256.cert.pem');
      expect(find.text(t('keys.import.error.publicKeyOnly', {'detail': ''})), findsOneWidget);
      expect(offer(), findsNothing);

      await pickAgain(keys, 'contacts/grace-1.foreign-subkey.public.asc');
      expect(find.text(t('keys.import.error.publicKeyOnly', {'detail': ''})), findsOneWidget);
      expect(offer(), findsNothing);
    });

    testWidgets('the offer goes when a private key is read next', (tester) async {
      final keys = await openImport(tester);
      await pick(keys, 'gnupg/ed25519.public.gpg');
      expect(offer(), findsOneWidget);

      await pickAgain(keys, 'openssh/ed25519');

      expect(offer(), findsNothing);
      expect(find.text(t('keys.import.add')), findsOneWidget);
    });
  });
}
