import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/algorithms.dart' show EcCurve;
import 'package:kemlock/crypto/keys/keys.dart' show readPgpKeyInfo, verifyPgpSelfSignatures;
import 'package:kemlock/features/security_keys/openpgp_card_keys_sheets.dart';
import 'package:kemlock/features/security_keys/openpgp_card_sheet.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../security_key/hex.dart';
import 'key_sheet_harness.dart';
import 'openpgp_card_harness.dart';

Finder _place(CardPlace place) => find.byKey(ValueKey('openpgp-place-${place.name}'));

bool _hasText(Finder row, String text) => find.descendant(of: row, matching: find.textContaining(text)).evaluate().isNotEmpty;

/// The GnuPG Ed25519 fixture key as the vault holds it, from its files.
VaultKey _vaultKey() => VaultKey(
  id: 'k1',
  name: 'Fixture',
  kind: KeyKind.pgp,
  algorithm: 'pgp',
  privateKey: b64(File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync()),
  publicKey: b64(File('test/fixtures/keys/gnupg/ed25519.public.gpg').readAsBytesSync()),
  origin: KeyOrigin.imported,
  addedAt: 0,
);

void main() {
  testWidgets('shows two keys and an empty place, and opening sends no PIN', (tester) async {
    final card = FakeOpenPgpCard();
    await tester.runAsync(() async {
      card
        ..load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)), fingerprint: unhex('11' * 20))
        ..load(CardPlace.decryption, await FakeCardKey.generate(fake25519(CardPlace.decryption)), fingerprint: unhex('22' * 20));
    });
    final (rig, _) = await openWithCard(tester, card: card);
    card.log.clear();

    await openPgpKeys(rig);

    expect(find.byType(OpenPgpCardSheet), findsOneWidget);
    expect(_hasText(_place(CardPlace.signature), 'Ed25519 · 1111 1111 1111 1111'), isTrue);
    expect(_hasText(_place(CardPlace.decryption), 'Curve25519 · 2222 2222 2222 2222'), isTrue);
    expect(_hasText(_place(CardPlace.authentication), tr('securityKeys.openpgp.place.empty')), isTrue);
    expect(_hasText(_place(CardPlace.signature), tr('securityKeys.openpgp.addToVault')), isTrue);
    expect(_hasText(_place(CardPlace.authentication), tr('securityKeys.openpgp.addToVault')), isFalse);
    expect(rowValue(tester, 'openpgp-pin'), contains(tr('securityKeys.pin.triesLeft', {'count': 3})));
    expect(rowValue(tester, 'openpgp-reset-code'), contains(tr('securityKeys.openpgp.notSet')));
    expect(find.text('1234 5678'), findsOneWidget);
    expect(find.text('3.4'), findsOneWidget);
    expect(card.log.where((entry) => entry.startsWith('verify')), isEmpty);
    expect(card.pinsSent, isEmpty);
  });

  testWidgets('names a Brainpool key and says Kemlock cannot use it', (tester) async {
    final card = FakeOpenPgpCard();
    card.load(
      CardPlace.signature,
      FakeEcKey.random(EcCurve.p256),
      fingerprint: unhex('33' * 20),
      algorithm: CardAlgorithm.parse(unhex('132b2403030208010107')),
    );
    final (rig, _) = await openWithCard(tester, card: card);

    await openPgpKeys(rig);

    expect(_hasText(_place(CardPlace.signature), 'brainpoolP256r1 · 3333 3333 3333 3333'), isTrue);
    expect(_hasText(_place(CardPlace.signature), tr('securityKeys.openpgp.unusable')), isTrue);
    expect(_hasText(_place(CardPlace.signature), tr('securityKeys.openpgp.addToVault')), isFalse);
  });

  testWidgets('has no touch group for a card without touch settings, and one for a card with them', (tester) async {
    final (rig, _) = await openWithCard(tester, card: FakeOpenPgpCard(touchSettings: false));
    await openPgpKeys(rig);
    expect(find.byKey(const ValueKey('openpgp-touch-signature')), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is Group && widget.label == tr('securityKeys.openpgp.section.touch')), findsNothing);
  });

  testWidgets('shows the touch settings a card reports', (tester) async {
    final card = FakeOpenPgpCard()..setTouch(CardPlace.signature, TouchPolicy.fixed);
    final (rig, _) = await openWithCard(tester, card: card);
    await openPgpKeys(rig);
    expect(rowValue(tester, 'openpgp-touch-signature'), contains(tr('securityKeys.openpgp.touch.fixed')));
    expect(rowValue(tester, 'openpgp-touch-decryption'), contains(tr('securityKeys.openpgp.touch.off')));
  });

  testWidgets('says "In this vault" for a key the vault holds', (tester) async {
    final card = FakeOpenPgpCard();
    await tester.runAsync(() => card.loadPgpKey(File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync()));
    final (rig, _) = await openWithCard(tester, card: card, vault: CardVault([_vaultKey()]));

    await openPgpKeys(rig);

    expect(_hasText(_place(CardPlace.signature), tr('securityKeys.openpgp.inVault')), isTrue);
    expect(_hasText(_place(CardPlace.decryption), tr('securityKeys.openpgp.inVault')), isTrue);
    expect(_hasText(_place(CardPlace.signature), tr('securityKeys.openpgp.addToVault')), isFalse);
  });
  group("adding the card's keys to the vault", () {
    Future<void> openAdd(WidgetTester tester, KeySheetRig rig) async {
      await openPgpKeys(rig);
      final link = find.descendant(of: _place(CardPlace.signature), matching: find.text(tr('securityKeys.openpgp.addToVault')));
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
    }

    Future<void> paste(WidgetTester tester, String path) async {
      await tester.tap(find.byKey(const ValueKey('card-add-import')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('card-add-pasted')), File(path).readAsStringSync());
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(CardAddToVaultSheet),
          matching: find.widgetWithText(FilledButton, tr('securityKeys.openpgp.addToVault')),
        ),
      );
      await settleReal(tester);
    }

    testWidgets("adds a public key whose keys are the card's as a card key", (tester) async {
      final card = FakeOpenPgpCard();
      await tester.runAsync(() => card.loadPgpKey(File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync()));
      final (rig, vault) = await openWithCard(tester, card: card);
      await openAdd(tester, rig);
      await paste(tester, 'test/fixtures/keys/gnupg/ed25519.public.asc');

      final key = vault.keys.single;
      expect(key.isOnCard, isTrue);
      expect(key.card!['aid'], cardHex(card.fullAid));
      expect(key.card!['slots'], {'sig': '1FCDA135EE42400EC2B77CE677249ABE661CF8DB', 'dec': '4BA83174FC8CE762A23BF0A4841A40E3B199EA67'});
      expect(key.name, 'Fixture Ed25519');
      expect(card.pinsSent, isEmpty);
    });

    testWidgets("refuses a public key that is not the card's", (tester) async {
      final card = FakeOpenPgpCard();
      await tester.runAsync(() => card.loadPgpKey(File('test/fixtures/keys/gnupg/ed25519.secret.gpg').readAsBytesSync()));
      final (rig, vault) = await openWithCard(tester, card: card);
      await openAdd(tester, rig);
      await paste(tester, 'test/fixtures/keys/gnupg/rsa3072.public.asc');

      expect(find.text(tr('securityKeys.openpgp.add.notThisCard')), findsOneWidget);
      expect(vault.keys, isEmpty);
    });

    testWidgets("makes one with a name, an email and the card's PINs, whose fingerprint is the card's", (tester) async {
      final card = FakeOpenPgpCard();
      await tester.runAsync(() async {
        // As GnuPG leaves a card it generated on, but with no fingerprint written: both PINs are needed
        card
          ..load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)))
          ..load(CardPlace.decryption, await FakeCardKey.generate(fake25519(CardPlace.decryption)));
      });
      final (rig, vault) = await openWithCard(tester, card: card);
      await openAdd(tester, rig);
      await tester.tap(find.byKey(const ValueKey('card-add-make')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('card-add-name')), 'Ada Lovelace');
      await tester.enterText(find.byKey(const ValueKey('card-add-email')), 'ada@example.org');
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(CardAddToVaultSheet),
          matching: find.widgetWithText(FilledButton, tr('securityKeys.openpgp.addToVault')),
        ),
      );
      await settleReal(tester);
      // The admin PIN writes the missing fingerprints and times, the PIN signs
      await typeCardPin(tester, FakeOpenPgpCard.factoryAdminPin);
      await typeCardPin(tester, FakeOpenPgpCard.factoryPin);

      final key = vault.keys.single;
      final public = unb64(key.publicKey!);
      final info = readPgpKeyInfo(public);
      expect(info.userIds, ['Ada Lovelace <ada@example.org>']);
      expect(info.primary.fingerprint, card.fingerprints[CardPlace.signature]);
      expect(info.subkeys.single.fingerprint, card.fingerprints[CardPlace.decryption]);
      expect(await tester.runAsync(() => verifyPgpSelfSignatures(public)), isTrue);
      expect(key.isOnCard, isTrue);
    });
  });
}
