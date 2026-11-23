import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/pgp/add_someone_sheet.dart';

import '../fakes/fake_files.dart';
import '../features/pgp/pgp_kit.dart';
import '../flows/flow_kit.dart' show tapOn;
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// The four PGP actions and their sheets, in dark and light, to hold
/// against `Main.dc.html`, `Encrypt.dc.html` and `Decrypt.dc.html`:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/pgp_test.dart
void main() {
  /// The app on a phone screen with the fixture [keys] in its vault, on the
  /// Vault tab.
  Future<PgpApp> vault(WidgetTester tester, Brightness brightness, {List<String> keys = const ['kemlock-ed']}) async {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final pgp = PgpApp(tester);
    await pgp.start(keys: keys);
    usePhoneScreen(tester);
    await tester.pumpAndSettle();
    return pgp;
  }

  Future<void> pasteKey(PgpApp pgp, String fixture) async {
    await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
    await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
    await pgp.enter(t('pgp.people.paste'), fixtureText(fixture));
    await pgp.tap(find.text(t('pgp.people.read')));
    await pgp.tap(find.text(t('pgp.people.use')));
  }

  Future<void> pick(PgpApp pgp, String label, String name, List<int> bytes) async {
    pgp.files.nextPath = FakeFiles.onDisk(name, bytes);
    final directory = File(pgp.files.nextPath!.path).parent;
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    await pgp.tap(find.text(label));
  }

  Future<void> decrypt(PgpApp pgp, String text) async {
    await pgp.open('decrypt');
    await pgp.enter(t('pgp.decrypt.field'), text);
    await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    // Main.dc.html
    testScreenshot('pgp: the Vault tab under Keys, with the four buttons, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['kemlock-ed', 'revoked']);
      await tapOn(tester, find.text(t('vault.filter.keys')));
      expect(pgp.requests, isEmpty);
      await takeScreenshot(tester, 'pgp_main_keys_$name');
    });

    testScreenshot('pgp: an empty vault, with the four buttons under its empty state, $name', (tester) async {
      await vault(tester, brightness, keys: const []);
      await takeScreenshot(tester, 'pgp_main_empty_$name');
    });

    // Encrypt.dc.html
    testScreenshot('pgp: Encrypt with two recipients, one unchecked, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['kemlock-ed', 'ed']);
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Fixture Ed25519')));
      await pasteKey(pgp, 'keys/gnupg/rsa3072.public.asc');
      await pgp.enter(t('pgp.encrypt.message'), 'The draft is attached. Tell me what you think before Friday.');
      await takeScreenshot(tester, 'pgp_encrypt_$name');
    });

    // openspec: add-post-quantum-pgp, task 8.5: the post-quantum line
    testScreenshot('pgp: Encrypt to post-quantum keys, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['pq-standard', 'kyber-protected']);
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      await pgp.tap(find.descendant(of: find.byType(AddSomeoneSheet), matching: find.text('Fixture Kyber Protected')));
      await pgp.enter(t('pgp.encrypt.message'), 'Safe from tomorrow’s computers too.');
      await takeScreenshot(tester, 'pgp_encrypt_pq_$name');
    });

    testScreenshot('pgp: Encrypt with a passphrase, $name', (tester) async {
      final pgp = await vault(tester, brightness);
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.withPassphrase')));
      await pgp.enter(t('pgp.encrypt.passphrase'), 'correct horse');
      await pgp.enter(t('pgp.encrypt.passphraseAgain'), 'correct hoarse');
      await pgp.enter(t('pgp.encrypt.message'), 'For whoever knows the words.');
      await takeScreenshot(tester, 'pgp_encrypt_passphrase_$name');
    });

    testScreenshot('pgp: Encrypt a file, $name', (tester) async {
      final pgp = await vault(tester, brightness);
      await pgp.open('encrypt');
      await pick(pgp, t('pgp.encrypt.chooseFile'), 'report.pdf', List.filled(482113, 0));
      await takeScreenshot(tester, 'pgp_encrypt_file_$name');
    });

    testScreenshot('pgp: Add someone, a pasted key to confirm, $name', (tester) async {
      final pgp = await vault(tester, brightness);
      await pgp.open('encrypt');
      await pgp.tap(find.text(t('pgp.encrypt.addSomeone')));
      await pgp.tap(find.widgetWithText(OutlinedButton, t('pgp.people.paste')));
      await pgp.enter(t('pgp.people.paste'), fixtureText('keys/gnupg/rsa3072.public.asc'));
      await pgp.tap(find.text(t('pgp.people.read')));
      await takeScreenshot(tester, 'pgp_add_someone_$name');
    });

    // Decrypt.dc.html
    testScreenshot('pgp: Decrypt, the input step, $name', (tester) async {
      final pgp = await vault(tester, brightness);
      await pgp.open('decrypt');
      await pgp.enter(t('pgp.decrypt.field'), fixtureText('pgp/gnupg/armored.asc'));
      await takeScreenshot(tester, 'pgp_decrypt_input_$name');
    });

    testScreenshot('pgp: Decrypted, signed by one of the vault\'s keys, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['ed']);
      await decrypt(pgp, fixtureText('pgp/kemlock/to-two.signed.asc'));
      await takeScreenshot(tester, 'pgp_decrypted_good_$name');
    });

    // openspec: add-post-quantum-pgp, task 8.5: Decrypt.dc.html's Encryption row
    testScreenshot('pgp: Decrypted, post-quantum, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['sq']);
      await decrypt(pgp, fixtureText('keys/sequoia/pqc/message.pgp'));
      await takeScreenshot(tester, 'pgp_decrypted_pq_$name');
    });

    testScreenshot('pgp: Decrypted, the signer unknown, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['rsa']);
      await decrypt(pgp, fixtureText('pgp/kemlock/to-two.signed.asc'));
      await takeScreenshot(tester, 'pgp_decrypted_unknown_$name');
    });

    testScreenshot('pgp: a bad signature, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['ed']);
      await decrypt(pgp, fixtureText('pgp/gnupg/clearsigned.asc').replaceFirst('A message', 'A massage'));
      await takeScreenshot(tester, 'pgp_decrypted_bad_$name');
    });

    testScreenshot('pgp: Decrypted, a file, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['ed']);
      await pgp.open('decrypt');
      await pick(pgp, t('pgp.decrypt.chooseFile'), 'report.txt.gpg', fixtureBytes('pgp/gnupg/zlib.gpg'));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      await takeScreenshot(tester, 'pgp_decrypted_file_$name');
    });

    testScreenshot('pgp: a key\'s passphrase is asked for by name, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['ed-protected']);
      await pgp.open('decrypt');
      await pgp.enter(t('pgp.decrypt.field'), fixtureText('pgp/gnupg/armored.asc'));
      // Encrypted to another key: use the message this key opens
      await pick(pgp, t('pgp.decrypt.chooseFile'), 'letter.gpg', fixtureBytes('pgp/gnupg/to-protected-ed25519.gpg'));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      await takeScreenshot(tester, 'pgp_key_passphrase_$name');
    });

    // Sign and Verify
    testScreenshot('pgp: Sign, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['kemlock-ed', 'ed']);
      await pgp.open('sign');
      await pgp.enter(t('pgp.sign.message'), 'I agree to the terms of 3 November.');
      await takeScreenshot(tester, 'pgp_sign_$name');
    });

    testScreenshot('pgp: Verify, good from one of the vault\'s keys, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['ed']);
      await pgp.open('verify');
      await pgp.enter(t('pgp.verify.field'), fixtureText('pgp/gnupg/clearsigned.asc'));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.verify.button')));
      await takeScreenshot(tester, 'pgp_verify_good_$name');
    });

    testScreenshot('pgp: Verify, the signer unknown, $name', (tester) async {
      final pgp = await vault(tester, brightness, keys: ['ed']);
      await pgp.open('verify');
      await pgp.enter(t('pgp.verify.field'), fixtureText('pgp/gnupg/clearsigned-rsa.asc'));
      await pgp.tap(find.widgetWithText(FilledButton, t('pgp.verify.button')));
      await takeScreenshot(tester, 'pgp_verify_unknown_$name');
    });
  }
}
