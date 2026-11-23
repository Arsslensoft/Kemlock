import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/features/keys/card_keys.dart';
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/keys/key_sheet.dart';
import 'package:kemlock/features/keys/key_widgets.dart';
import 'package:kemlock/features/keys/sign_sheet.dart';
import 'package:kemlock/features/keys/verify_sheet.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/vault/owner_check.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../fakes/fake_clipboard.dart';
import '../../flows/flow_kit.dart' show confirmOwner;
import '../../helpers/old_biometric_entry.dart';
import '../../helpers/test_app.dart';
import '../spaces/chain_kit.dart';
import '../spaces/policy_kit.dart';
import 'expiry_kit.dart';
import 'keys_kit.dart';

void main() {
  late List<String> clipboard;

  /// The vault with the ed25519 fixture key in it, its sheet open.
  Future<KeysApp> openKey(WidgetTester tester, {String path = 'openssh/ed25519', String name = 'laptop', String? space}) async {
    clipboard = [];
    answerSensitiveCopies(clipboard.add);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add('${(call.arguments as Map)['text']}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final keys = KeysApp(tester);
    await keys.start();
    final parsed = await tester.runAsync(() => crypto.readPrivateKey(keyFixture(path).readAsBytesSync()));
    await keys.app.container
        .read(vaultControllerProvider.notifier)
        .addKey(vaultKeyOf(parsed!, id: 'k1', name: name, origin: KeyOrigin.imported).inSpace(space));
    // The add's toast would sit over the sheet until it times out
    await tester.pump(const Duration(seconds: 10));
    await keys.settle();
    await keys.tap(find.text(name));
    return keys;
  }

  testWidgets('shows the ssh line and the fingerprint ssh-keygen gives, and copies the line', (tester) async {
    final keys = await openKey(tester);

    final pub = keyFixture('openssh/ed25519.pub').readAsStringSync().trim().split(' ');
    final line = '${pub[0]} ${pub[1]} laptop';
    expect(find.text(line), findsOneWidget);
    expect(find.text('SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4'), findsOneWidget);
    final sheet = find.byType(KeySheet);
    expect(find.descendant(of: sheet, matching: find.text(t('keys.kind.ssh'))), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Ed25519')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text(t('keys.origin.imported'))), findsOneWidget);

    await keys.tap(find.text(t('keys.public.copy')).first);
    expect(clipboard, [line]);
  });

  testWidgets('cancelling the warning shows, copies and writes nothing', (tester) async {
    final keys = await openKey(tester);

    for (final action in ['keys.private.show', 'keys.private.copy', 'keys.private.export']) {
      await keys.tap(find.text(t(action)));
      expect(find.text(t('keys.private.warning.title')), findsOneWidget, reason: action);
      await keys.tap(keys.dialogButton('export.cancel'));
    }

    expect(clipboard, isEmpty);
    expect(keys.files.saved, isEmpty);
    expect(find.textContaining('BEGIN OPENSSH'), findsNothing);
  });

  testWidgets('a vault with biometric unlock asks for them, and refusing them exposes nothing', (tester) async {
    final keys = await openKey(tester);
    await writeOldBiometricEntry(keys.app.store, keys.app.vaults, keys.app.container.read(vaultControllerProvider).session!);
    keys.app.biometrics.passes = false;

    await keys.tap(find.text(t('keys.private.copy')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));

    expect(keys.app.biometrics.prompts, [t('keys.private.biometric')]);
    expect(clipboard, isEmpty);

    keys.app.biometrics.passes = true;
    await keys.tap(find.text(t('keys.private.copy')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));
    expect(clipboard.single, contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(find.text(t('keys.private.copied')), findsOneWidget);
  });

  testWidgets('a vault without biometric unlock asks for its master password, and refusing it exposes nothing', (tester) async {
    final keys = await openKey(tester);
    final dialog = find.byType(OwnerPasswordDialog);

    await keys.tap(find.text(t('keys.private.copy')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));
    expect(dialog, findsOneWidget);
    expect(find.text(t('keys.private.biometric')), findsOneWidget);
    expect(keys.app.biometrics.prompts, isEmpty);
    await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), 'not the password');
    await tester.pump();
    await keys.tap(keys.dialogButton('confirmOwner.continue'));
    expect(find.text(t('confirmOwner.wrong')), findsOneWidget);
    await keys.tap(keys.dialogButton('export.cancel'));
    expect(dialog, findsNothing);
    expect(clipboard, isEmpty);

    await keys.tap(find.text(t('keys.private.copy')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));
    await confirmOwner(tester);
    await keys.settle();
    expect(clipboard.single, contains('BEGIN OPENSSH PRIVATE KEY'));
  });

  testWidgets('exports with a passphrase by default, and the file reads back as the same key', (tester) async {
    final keys = await openKey(tester);

    await keys.tap(find.text(t('keys.private.export')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));
    await confirmOwner(tester);
    await keys.settle();
    await tester.enterText(find.widgetWithText(TextField, t('keys.export.passphrase')), 'export pass');
    await tester.enterText(find.widgetWithText(TextField, t('keys.export.again')), 'export pass');
    await tester.pump();
    await keys.tap(keys.dialogButton('keys.export.button'));

    final saved = keys.files.saved.single;
    expect(saved.name, 'laptop');
    final text = utf8.decode(saved.bytes);
    expect(text, contains('BEGIN OPENSSH PRIVATE KEY'));
    await tester.runAsync(() async {
      await expectLater(crypto.readPrivateKey(text), throwsA(isA<crypto.KeyFormatException>()));
      final again = await crypto.readPrivateKey(text, passphrase: 'export pass');
      expect(again.private, unb64(keys.keys.single.privateKey));
    });
  });

  group('a key of a space', () {
    final space = uuid(0x5a);
    final member = Person(2);

    /// Reports the policies of the space the key is in: no export, or none.
    void report(KeysApp keys, {required bool noExport}) {
      keys.app.container.read(spacePoliciesProvider.notifier)
        ..report(space, member.id, spaceWithPolicies(0x5a, member, {if (noExport) 'disableExport': true}))
        ..name(space, 'Example Co');
    }

    testWidgets('is not saved to a file where its space forbids exporting, and says which space', (tester) async {
      final keys = await openKey(tester, space: space);
      report(keys, noExport: true);

      await keys.tap(find.text(t('keys.private.export')));
      await keys.settle();

      expect(find.text(t('keys.export.space', {'reason': 'blocked', 'space': 'Example Co'})), findsOneWidget);
      expect(find.text(t('keys.private.warning.title')), findsNothing, reason: 'nothing was asked: the key goes nowhere');
      expect(find.text(t('keys.export.passphrase')), findsNothing);
      expect(keys.files.saved, isEmpty);
    });

    testWidgets('is not saved to a file while its space’s rules are unread, as the file exports fail closed', (tester) async {
      final keys = await openKey(tester, space: space);

      await keys.tap(find.text(t('keys.private.export')));
      await keys.settle();

      expect(find.text(t('keys.export.space', {'reason': 'unknown', 'space': space})), findsOneWidget);
      expect(keys.files.saved, isEmpty);
    });

    testWidgets('asks as before where its space allows exporting, and Copy stays as it is where it forbids', (tester) async {
      final keys = await openKey(tester, space: space);
      report(keys, noExport: false);

      await keys.tap(find.text(t('keys.private.export')));
      expect(find.text(t('keys.private.warning.title')), findsOneWidget);
      await keys.tap(keys.dialogButton('export.cancel'));

      report(keys, noExport: true);
      await keys.tap(find.text(t('keys.private.copy')));
      expect(find.text(t('keys.private.warning.title')), findsOneWidget, reason: 'Copy asks as before');
    });
  });

  testWidgets('"No passphrase" needs its own confirmation', (tester) async {
    final keys = await openKey(tester);

    await keys.tap(find.text(t('keys.private.export')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));
    await confirmOwner(tester);
    await keys.settle();
    await keys.tap(find.text(t('keys.export.none')));
    await keys.tap(keys.dialogButton('keys.export.button'));
    expect(find.text(t('keys.export.none.title')), findsOneWidget);
    await keys.tap(keys.dialogButton('export.cancel'));
    expect(keys.files.saved, isEmpty);

    await keys.tap(find.text(t('keys.private.export')));
    await keys.tap(keys.dialogButton('keys.private.warning.confirm'));
    await confirmOwner(tester);
    await keys.settle();
    await keys.tap(find.text(t('keys.export.none')));
    await keys.tap(keys.dialogButton('keys.export.button'));
    await keys.tap(keys.dialogButton('keys.export.none.confirm'));
    final text = utf8.decode(keys.files.saved.single.bytes);
    final again = await tester.runAsync(() => crypto.readPrivateKey(text));
    expect(again!.private, unb64(keys.keys.single.privateKey));
  });

  testWidgets('a renamed key keeps its fingerprint, and its line ends with the new name', (tester) async {
    final keys = await openKey(tester);

    await tester.enterText(find.widgetWithText(TextField, t('keys.field.name')), 'work laptop');
    await keys.tap(find.widgetWithText(FilledButton, t('passkeys.save')));
    await keys.tap(find.text('work laptop'));

    expect(keys.keys.single.name, 'work laptop');
    expect(find.text('SHA256:41s5PBHoZEOR0cJ/tvgDufVKulMqGbNyELiLyECUAW4'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^ssh-ed25519 \S+ work laptop$')), findsOneWidget);
  });

  testWidgets('a deleted key comes back with Undo, unchanged', (tester) async {
    final keys = await openKey(tester);
    final before = keys.keys.single;

    await keys.tap(find.text(t('keys.delete')));
    expect(keys.keys, isEmpty);
    await keys.tap(find.text(t('app.undo')));

    expect(keys.keys.single.privateKey, before.privateKey);
    expect(keys.keys.single.name, before.name);
  });

  testWidgets('keys are listed on the Vault tab and found by name or algorithm', (tester) async {
    final keys = KeysApp(tester);
    await keys.start();
    final parsed = await tester.runAsync(() => crypto.readPrivateKey(keyFixture('openssh/ed25519').readAsBytesSync()));
    await keys.app.container
        .read(vaultControllerProvider.notifier)
        .addKey(vaultKeyOf(parsed!, id: 'k1', name: 'laptop', origin: KeyOrigin.imported));
    await keys.settle();
    final search = find.descendant(of: find.byType(SearchField), matching: find.byType(TextField));
    final row = find.descendant(of: find.byType(GroupRow), matching: find.text('laptop'));

    expect(row, findsOneWidget);
    // An SSH key's row shows its fingerprint; its algorithm is still searched
    expect(find.descendant(of: find.byType(GroupRow), matching: find.text('SHA256:41s5…UAW4')), findsOneWidget);
    await tester.enterText(search, 'ed25519');
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    await tester.enterText(search, 'rsa');
    await tester.pumpAndSettle();
    expect(row, findsNothing);
  });

  group('a PGP key that expires or was revoked', () {
    final standingAlert = find.byKey(const ValueKey('key-standing'));
    final subkeyAlert = find.byKey(const ValueKey('subkey-standing'));
    final expiryRow = find.byKey(const ValueKey('key-expiry'));
    String date(DateTime when) => DateFormat.yMMMd('en').format(when.toLocal());
    String subkeyLine(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('subkey-0'))).textSpan!.toPlainText();
    AlertSeverity severity(WidgetTester tester, Finder alert) => tester.widget<AppAlert>(alert).severity;

    /// The sheet of the fixture key [name], opened at [now] (today's test clock unless given).
    Future<KeysApp> openPgp(WidgetTester tester, String name, {DateTime? now}) async {
      final keys = KeysApp(tester);
      if (now != null) keys.app.now = () => now;
      await keys.start();
      final key = await tester.runAsync(() => expiryFixtureKey(name));
      await keys.app.container.read(vaultControllerProvider.notifier).addKey(key!);
      await tester.pump(const Duration(seconds: 10));
      await keys.settle();
      await keys.tap(find.text(name));
      return keys;
    }

    testWidgets('a key that never expires says so, and warns of nothing', (tester) async {
      await openPgp(tester, 'never');

      expect(find.descendant(of: expiryRow, matching: find.text(t('keys.field.expiry'))), findsOneWidget);
      expect(find.descendant(of: expiryRow, matching: find.text(t('keys.expiry.never'))), findsOneWidget);
      expect(standingAlert, findsNothing);
      expect(subkeyAlert, findsNothing);
      expect(subkeyLine(tester), 'Subkey, cv25519: encrypt');
    });

    testWidgets('a key a week from its expiry shows the date and a warning', (tester) async {
      await openPgp(tester, 'future', now: futureExpiry.subtract(const Duration(days: 7)));

      expect(find.descendant(of: expiryRow, matching: find.text(date(futureExpiry))), findsOneWidget);
      expect(severity(tester, standingAlert), AlertSeverity.warning);
      expect(find.descendant(of: standingAlert, matching: find.text(t('keys.expiry.soon', {'days': 7}))), findsOneWidget);
      expect(t('keys.expiry.soon', {'days': 7}), startsWith('This key expires in 7 days.'));
      expect(subkeyAlert, findsNothing);
      // Its subkey expires with it, which is no fault yet
      expect(subkeyLine(tester), 'Subkey, cv25519: encrypt · expires on ${date(futureExpiry)}');
    });

    testWidgets('a key that is far from its expiry shows the date and no warning', (tester) async {
      await openPgp(tester, 'future');

      expect(find.descendant(of: expiryRow, matching: find.text(date(futureExpiry))), findsOneWidget);
      expect(standingAlert, findsNothing);
    });

    testWidgets('an expired key shows the date it expired and what that means, in red', (tester) async {
      await openPgp(tester, 'expired');

      expect(find.descendant(of: expiryRow, matching: find.text(date(pastExpiry))), findsOneWidget);
      expect(severity(tester, standingAlert), AlertSeverity.error);
      final message = t('keys.expiry.expired', {'date': date(pastExpiry)});
      expect(find.descendant(of: standingAlert, matching: find.text(message)), findsOneWidget);
      expect(message, contains('can no longer encrypt to it or trust its new signatures'));
      expect(subkeyLine(tester), startsWith('Subkey, cv25519: encrypt · expired on '));
      // The key itself is over: the subkey needs no warning of its own
      expect(subkeyAlert, findsNothing);
    });

    testWidgets('a revoked key says it was revoked and should not be used, also when it expired too', (tester) async {
      await openPgp(tester, 'revoked');

      expect(severity(tester, standingAlert), AlertSeverity.error);
      expect(find.descendant(of: standingAlert, matching: find.text(t('keys.expiry.revoked'))), findsOneWidget);
      expect(t('keys.expiry.revoked'), startsWith('This key was revoked and should not be used.'));
      expect(find.descendant(of: expiryRow, matching: find.text(t('keys.expiry.never'))), findsOneWidget);
    });

    testWidgets('a revoked key that also expired is said to be revoked', (tester) async {
      await openPgp(tester, 'revoked-expired');

      expect(find.descendant(of: standingAlert, matching: find.text(t('keys.expiry.revoked'))), findsOneWidget);
      expect(find.descendant(of: expiryRow, matching: find.text(date(pastExpiry))), findsOneWidget);
    });

    testWidgets('a key whose encryption subkey alone expired says so on its line and above the lines', (tester) async {
      await openPgp(tester, 'subkey-expired');

      expect(standingAlert, findsNothing);
      expect(find.descendant(of: expiryRow, matching: find.text(t('keys.expiry.never'))), findsOneWidget);
      expect(severity(tester, subkeyAlert), AlertSeverity.warning);
      expect(find.descendant(of: subkeyAlert, matching: find.text(t('keys.expiry.subkeyExpired'))), findsOneWidget);
      expect(subkeyLine(tester), 'Subkey, cv25519: encrypt · expired on ${date(pastExpiry)}');
      // Above the lines of the primary key and the subkey
      expect(tester.getTopLeft(subkeyAlert).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('subkey-0'))).dy));
      expect(tester.getTopLeft(subkeyAlert).dy, lessThan(tester.getTopLeft(find.textContaining('Primary key, ed25519')).dy));
    });

    testWidgets("an SSH key's sheet says nothing of expiry", (tester) async {
      await openKey(tester);

      expect(expiryRow, findsNothing);
      expect(find.text(t('keys.field.expiry')), findsNothing);
      expect(standingAlert, findsNothing);
      expect(subkeyAlert, findsNothing);
      expect(find.descendant(of: find.byType(KeySheet), matching: find.byType(AppAlert)), findsNothing);
    });
  });

  group('SSH signatures', () {
    final actions = find.byKey(const ValueKey('ssh-signatures'));

    testWidgets("an SSH key's sheet offers to sign a file or text, and opens the sign sheet for that key", (tester) async {
      final keys = await openKey(tester);

      expect(find.descendant(of: actions, matching: find.text(t('keys.sign.action'))), findsOneWidget);
      await keys.tap(find.text(t('keys.sign.action')));

      expect(find.byType(SignSheet), findsOneWidget);
      expect(tester.widget<SignSheet>(find.byType(SignSheet)).keyId, 'k1');
      expect(find.text(t('keys.sign.title', {'name': 'laptop'})), findsOneWidget);
      // No warning and no biometrics: the private half goes nowhere
      expect(find.text(t('keys.private.warning.title')), findsNothing);
      expect(keys.app.biometrics.prompts, isEmpty);
    });

    testWidgets("an SSH key's sheet offers to verify a signature, and opens the verify sheet", (tester) async {
      final keys = await openKey(tester);

      expect(find.descendant(of: actions, matching: find.text(t('keys.verify.action'))), findsOneWidget);
      await keys.tap(find.text(t('keys.verify.action')));

      expect(find.byType(VerifySheet), findsOneWidget);
      expect(find.text(t('keys.verify.submit')), findsOneWidget);
    });

    for (final (kind, path) in [
      ('PGP', 'gnupg/ed25519.secret.asc'),
      ('signing', 'openssl/ed25519.pkcs8.pem'),
      ('exchange', 'openssl/x25519.pkcs8.pem'),
    ]) {
      testWidgets("a $kind key's sheet does not offer SSH signing", (tester) async {
        await openKey(tester, path: path, name: 'other');

        expect(find.byType(KeySheet), findsOneWidget);
        expect(actions, findsNothing);
        expect(find.text(t('keys.sign.action')), findsNothing);
        expect(find.text(t('keys.verify.action')), findsNothing);
      });
    }
  });
  group('a PGP key on a security key', () {
    final cardAlert = find.byKey(const ValueKey('key-on-card'));
    final privateLabel = find.byWidgetPredicate((widget) => widget is SectionLabel && widget.text == t('keys.private.title'));

    /// The sheet of the GnuPG Ed25519 fixture key, kept as a card key: its
    /// private half the hand-made stub, and the card that holds it.
    Future<KeysApp> openCardKey(WidgetTester tester) async {
      clipboard = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add('${(call.arguments as Map)['text']}');
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final keys = KeysApp(tester);
      await keys.start();
      await keys.app.container
          .read(vaultControllerProvider.notifier)
          .addKey(
            VaultKey(
              id: 'k1',
              name: 'On the card',
              kind: KeyKind.pgp,
              algorithm: 'pgp',
              privateKey: b64(keyFixture('gnupg/card/stub-ed25519.gpg').readAsBytesSync()),
              publicKey: b64(keyFixture('gnupg/ed25519.public.gpg').readAsBytesSync()),
              origin: KeyOrigin.imported,
              protected: true,
              addedAt: 0,
              card: cardObject('D276000124010304FFFF123456780000', {
                CardPlace.signature: '1FCDA135EE42400EC2B77CE677249ABE661CF8DB',
                CardPlace.decryption: '4BA83174FC8CE762A23BF0A4841A40E3B199EA67',
              }),
            ),
          );
      await tester.pump(const Duration(seconds: 10));
      await keys.settle();
      await keys.tap(find.text('On the card'));
      return keys;
    }

    testWidgets('names the card by its serial in place of the private-key actions', (tester) async {
      await openCardKey(tester);

      expect(cardAlert, findsOneWidget);
      expect(find.descendant(of: cardAlert, matching: find.text(t('keys.card.info', {'serial': '1234 5678'}))), findsOneWidget);
      expect(privateLabel, findsNothing);
      for (final id in ['keys.private.show', 'keys.private.copy', 'keys.private.export', 'keys.pgp.protected']) {
        expect(find.text(t(id)), findsNothing, reason: id);
      }
    });

    // Joined with add-pgp-key-editing: a card signs no change
    testWidgets('offers no change, and says its secret is on the security key', (tester) async {
      await openCardKey(tester);
      final refused = find.byKey(const ValueKey('key-change-refused'));
      await tester.scrollUntilVisible(
        refused,
        200,
        scrollable: find.descendant(of: find.byType(KeySheet), matching: find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();

      expect(find.text(t('keys.change.title').toUpperCase()), findsOneWidget);
      expect(find.descendant(of: refused, matching: find.text(t('keys.card.change'))), findsOneWidget);
      expect(find.text(t('keys.change.blocked.noPrimarySecret')), findsNothing);
      expect(find.byKey(const ValueKey('key-change')), findsNothing);
      for (final id in [
        'keys.change.addSubkey',
        'keys.change.addUserId',
        'keys.change.expiry',
        'keys.change.revoke',
        'keys.change.subkeyHint',
      ]) {
        expect(find.text(t(id)), findsNothing, reason: id);
      }
      expect(find.byKey(const ValueKey('subkey-0')), findsOneWidget);
      expect(find.ancestor(of: find.byKey(const ValueKey('subkey-0')), matching: find.byType(InkWell)), findsNothing);
    });

    testWidgets('still copies and shares the public key', (tester) async {
      final keys = await openCardKey(tester);

      expect(find.text(t('notes.copy.share')), findsOneWidget);
      await keys.tap(find.text(t('keys.public.copy')).first);
      expect(clipboard.single, contains('BEGIN PGP PUBLIC KEY BLOCK'));
    });

    testWidgets('says the card no longer holds the key once it was read without it', (tester) async {
      final keys = await openCardKey(tester);
      final gone = find.byKey(const ValueKey('key-card-gone'));
      expect(gone, findsNothing);

      // The card was read holding the key: nothing to say
      keys.app.container.read(cardsSeenProvider.notifier).note('D276000124010304FFFF123456780000', {
        '1FCDA135EE42400EC2B77CE677249ABE661CF8DB',
        '4BA83174FC8CE762A23BF0A4841A40E3B199EA67',
      });
      await tester.pumpAndSettle();
      expect(gone, findsNothing);

      // Read again after a factory reset: empty
      keys.app.container.read(cardsSeenProvider.notifier).note('D276000124010304FFFF123456780000', {});
      await tester.pumpAndSettle();
      expect(find.descendant(of: gone, matching: find.text(t('keys.card.gone', {'serial': '1234 5678'}))), findsOneWidget);
      expect(cardAlert, findsOneWidget, reason: 'the key is still listed, its public half kept');
    });

    testWidgets("an ordinary PGP key's sheet is as it was", (tester) async {
      await openKey(tester, path: 'gnupg/ed25519.secret.asc', name: 'ordinary');

      expect(cardAlert, findsNothing);
      expect(privateLabel, findsOneWidget);
      for (final id in ['keys.private.show', 'keys.private.copy', 'keys.private.export']) {
        expect(find.text(t(id)), findsOneWidget, reason: id);
      }
    });
  });

  // openspec: add-pgp-key-editing, design decision 10
  group('changing a PGP key', () {
    final section = find.byKey(const ValueKey('key-change'));
    final refused = find.byKey(const ValueKey('key-change-refused'));

    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.descendant(of: find.byType(KeySheet), matching: find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a key Kemlock generated offers the four changes', (tester) async {
      final keys = KeysApp(tester);
      await keys.openPgpKey('kemlock/pgp-ed25519.unprotected.asc');

      await scrollTo(tester, section);
      expect(find.text(t('keys.change.title').toUpperCase()), findsOneWidget);
      for (final id in ['keys.change.addSubkey', 'keys.change.addUserId', 'keys.change.expiry', 'keys.change.revoke']) {
        expect(
          find.descendant(of: section, matching: find.text(t(id))),
          findsOneWidget,
          reason: id,
        );
      }
      expect(find.descendant(of: section, matching: find.text(t('keys.change.expiryNever'))), findsOneWidget);
      expect(refused, findsNothing);
      expect(find.text(t('keys.change.subkeyHint')), findsOneWidget);

      await keys.tap(find.text(t('keys.change.expiry')));
      expect(find.text(t('keys.change.expiry.title')), findsWidgets);
    });

    for (final (what, path, id) in [
      ('a revoked key', 'gnupg/expiry/revoked.secret.asc', 'keys.change.blocked.revoked'),
      ('a copy without its primary secret', 'gnupg/editing/protected.stub.secret.asc', 'keys.change.blocked.noPrimarySecret'),
    ]) {
      testWidgets('$what says why it cannot be changed, and offers nothing', (tester) async {
        final keys = KeysApp(tester);
        await keys.openPgpKey(path);

        await scrollTo(tester, refused);
        expect(find.descendant(of: refused, matching: find.text(t(id))), findsOneWidget);
        expect(section, findsNothing);
        expect(find.text(t('keys.change.addSubkey')), findsNothing);
        expect(find.text(t('keys.change.subkeyHint')), findsNothing);
      });
    }

    // openspec: add-post-quantum-pgp, task 9.1: a version 6 key is changed too
    for (final path in ['kemlock/pgp-pq-standard.unprotected.asc', 'rfc9580/v6-secret.asc']) {
      testWidgets('$path offers the four changes', (tester) async {
        final keys = KeysApp(tester);
        await keys.openPgpKey(path);

        await scrollTo(tester, section);
        for (final id in ['keys.change.addSubkey', 'keys.change.addUserId', 'keys.change.expiry', 'keys.change.revoke']) {
          expect(
            find.descendant(of: section, matching: find.text(t(id))),
            findsOneWidget,
            reason: id,
          );
        }
        expect(refused, findsNothing);
      });
    }

    testWidgets('an algorithm Kemlock cannot sign with is named', (tester) async {
      final keys = KeysApp(tester);
      await keys.openPgpKey('../pgp/gnupg/nistp256.secret.asc');

      await scrollTo(tester, refused);
      expect(find.text(t('keys.change.blocked.algorithm', {'algorithm': 'nistp256'})), findsOneWidget);
    });

    testWidgets('an SSH key offers none of it', (tester) async {
      await openKey(tester);

      expect(find.text(t('keys.change.title').toUpperCase()), findsNothing);
      expect(section, findsNothing);
      expect(refused, findsNothing);
    });
  });

  // openspec: add-pgp-contacts, task 4.4
  group('the QR code of a public key', () {
    Future<PublicKeyQr> showQr(KeysApp keys, {int row = 0}) async {
      await keys.tap(find.text(t('keys.public.qr')).at(row));
      return keys.tester.widget<PublicKeyQr>(find.byType(PublicKeyQr));
    }

    testWidgets('of an Ed25519 PGP key holds its armored key, which another Kemlock reads', (tester) async {
      final keys = await openKey(tester, path: 'gnupg/ed25519.secret.asc', name: 'mine');

      final qr = await showQr(keys);

      expect(qr.data, startsWith('-----BEGIN PGP PUBLIC KEY BLOCK-----'));
      expect(qr.data.length, lessThan(publicKeyQrLimit));
      expect(qr.caption, isNull);
      final read = await tester.runAsync(() => crypto.readPublicKeys(qr.data));
      expect(read!.single.info.primary.fingerprintHex, '1FCDA135EE42400EC2B77CE677249ABE661CF8DB');
      expect(read.single.bytes, keyFixture('gnupg/ed25519.public.gpg').readAsBytesSync());
    });

    testWidgets('of an RSA 3072 PGP key holds OPENPGP4FPR: and its fingerprint, and says the code carries no key', (tester) async {
      final keys = await openKey(tester, path: 'gnupg/rsa3072.secret.asc', name: 'mine');

      final qr = await showQr(keys);

      final listed = keyFixture('gnupg/rsa3072.colons.txt').readAsLinesSync().firstWhere((line) => line.startsWith('fpr:')).split(':')[9];
      expect(qr.data, 'OPENPGP4FPR:$listed');
      expect(qr.caption, t('keys.public.qr.fingerprintOnly'));
      expect(find.text(t('keys.public.qr.fingerprintOnly')), findsOneWidget);
    });

    testWidgets('of an SSH key is unchanged: its line, then its PEM, whatever their length', (tester) async {
      final keys = await openKey(tester, path: 'openssh/rsa3072', name: 'server');
      final key = parsedKeyOf(keys.keys.single);

      final line = await showQr(keys);
      expect(line.data, crypto.sshPublicKeyLine(key, comment: 'server'));
      expect(line.caption, isNull);
      await keys.tap(keys.dialogButton('notes.file.close'));

      final pem = await showQr(keys, row: 1);
      expect(pem.data, crypto.publicKeyPem(key));
      expect(pem.caption, isNull);
    });

    test('only a PGP key over the limit falls back to its fingerprint', () {
      final long = 'x' * (publicKeyQrLimit + 1);

      expect(publicKeyQrData(long), (data: long, fingerprintOnly: false));
      expect(publicKeyQrData('x' * publicKeyQrLimit, fingerprint: 'AB12'), (data: 'x' * publicKeyQrLimit, fingerprintOnly: false));
      expect(publicKeyQrData(long, fingerprint: 'AB12'), (data: 'OPENPGP4FPR:AB12', fingerprintOnly: true));
    });
  });

  // openspec: add-post-quantum-pgp, task 8.1
  group('a post-quantum PGP key', () {
    testWidgets('the standard key: a 64-character fingerprint, both algorithms, and who reads it', (tester) async {
      final keys = await openKey(tester, path: 'kemlock/pgp-pq-standard.unprotected.asc', name: 'Ada, post-quantum');
      final fingerprint = tester.widget<SelectableText>(find.byKey(const ValueKey('fingerprint'))).data!;
      expect(fingerprint, matches(RegExp(r'^([0-9A-F]{4} ){15}[0-9A-F]{4}$')));
      expect(find.textContaining('ML-DSA-65 + Ed25519'), findsOneWidget);
      expect(find.textContaining('ML-KEM-768 + X25519'), findsOneWidget);
      expect(find.text(t('keys.pgp.readers.standard')), findsOneWidget);
      expect(t('keys.pgp.readers.standard'), contains('RFC 9980'));
      expect(find.byKey(const ValueKey('keys.pgp.cannotSign')), findsNothing);
      expect(keys.keys.single.kind, KeyKind.pgp);
    });

    testWidgets('the GnuPG key: its Kyber subkey with its own fingerprint, and signatures that stay Ed25519', (tester) async {
      await openKey(tester, path: 'gnupg/pqc/ky768-cv25519.secret.asc', name: 'Kyber');
      expect(find.textContaining('Kyber-768 + X25519'), findsOneWidget);
      final listed = keyFixture('gnupg/pqc/ky768-cv25519.colons.txt')
          .readAsLinesSync()
          .where((line) => line.startsWith('fpr:'))
          .last
          .split(':')[9];
      final grouped = [for (var i = 0; i < listed.length; i += 4) listed.substring(i, i + 4)].join(' ');
      expect(tester.widget<SelectableText>(find.byKey(const ValueKey('subkey-fingerprint-0'))).data, grouped);
      expect(find.text(t('keys.pgp.readers.gnupg')), findsOneWidget);
      expect(t('keys.pgp.readers.gnupg'), contains('signatures stay Ed25519'));
    });

    testWidgets("RFC 9980's A.4 key is named, and the sheet says Kemlock cannot sign with it", (tester) async {
      await openKey(tester, path: 'rfc9980/a4-secret.asc', name: 'A.4');
      expect(find.textContaining('ML-DSA-87 + Ed448'), findsWidgets);
      expect(find.text(t('keys.pgp.cannotSign', {'algorithm': 'ML-DSA-87 + Ed448'})), findsOneWidget);
      expect(find.text(t('keys.pgp.cannotEncrypt', {'algorithm': 'ML-KEM-1024 + X448'})), findsOneWidget);
    });

    testWidgets("an Ed25519 key's sheet is as it was: no line about who reads it", (tester) async {
      await openKey(tester, path: 'gnupg/ed25519.secret.asc', name: 'mine');
      expect(find.byKey(const ValueKey('pgp-readers')), findsNothing);
      expect(find.byKey(const ValueKey('subkey-fingerprint-0')), findsNothing);
      expect(find.textContaining('ed25519'), findsWidgets);
    });
  });
}
