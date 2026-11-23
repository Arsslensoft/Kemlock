import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' show PgpKeyFlag, readPgpKeyInfo, verifyPgpSelfSignatures;
import 'package:kemlock/features/security_keys/openpgp_card_keys_sheets.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';

import '../../fakes/fake_openpgp_card.dart';
import 'key_sheet_harness.dart';
import 'openpgp_card_harness.dart';

void main() {
  Future<void> openGenerate(WidgetTester tester, KeySheetRig rig) async {
    await openPgpKeys(rig);
    final button = find.byKey(const ValueKey('openpgp-generate'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  List<CardKeyKind> offered(WidgetTester tester) => [
    for (final item in tester.widgetList<DropdownMenuItem<CardKeyKind>>(
      // The menu's closed button holds every item, those not chosen offstage
      find.descendant(
        of: find.byKey(const ValueKey('card-generate-kind')),
        matching: find.byType(DropdownMenuItem<CardKeyKind>, skipOffstage: false),
        skipOffstage: false,
      ),
    ))
      item.value!,
  ];

  Future<void> choose(WidgetTester tester, CardKeyKind kind) async {
    await tester.tap(find.byKey(const ValueKey('card-generate-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kind.label).last);
    await tester.pumpAndSettle();
  }

  Future<void> fillAndGenerate(WidgetTester tester, {CardKeyKind? kind}) async {
    if (kind != null) await choose(tester, kind);
    await tester.enterText(find.byKey(const ValueKey('card-generate-name')), 'Ada Lovelace');
    await tester.enterText(find.byKey(const ValueKey('card-generate-email')), 'ada@example.org');
    await tester.pump();
    final button = find.byKey(const ValueKey('card-generate-button'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> givePins(WidgetTester tester) async {
    await typeCardPin(tester, FakeOpenPgpCard.factoryAdminPin);
    await typeCardPin(tester, FakeOpenPgpCard.factoryPin);
    await settleReal(tester, 20);
  }

  for (final kind in [CardKeyKind.ed25519, CardKeyKind.rsa2048]) {
    testWidgets('${kind.label}: the vault gains one card key, made by the card and checked', (tester) async {
      final card = FakeOpenPgpCard();
      final (rig, vault) = await openWithCard(tester, card: card);
      await openGenerate(tester, rig);
      await fillAndGenerate(tester, kind: kind);
      await givePins(tester);

      final key = vault.keys.single;
      expect(key.origin, KeyOrigin.generated);
      expect(key.isOnCard, isTrue);
      final public = unb64(key.publicKey!);
      expect(await tester.runAsync(() => verifyPgpSelfSignatures(public)), isTrue);
      final info = readPgpKeyInfo(public);
      expect(info.userIds, ['Ada Lovelace <ada@example.org>']);
      expect(info.primary.flags, PgpKeyFlag.certify | PgpKeyFlag.sign);
      expect(
        [for (final subkey in info.subkeys) subkey.flags],
        [PgpKeyFlag.encryptCommunications | PgpKeyFlag.encryptStorage, PgpKeyFlag.authenticate],
      );
      expect(info.primary.fingerprint, card.fingerprints[CardPlace.signature]);
      expect(
        [for (final subkey in info.subkeys) subkey.fingerprint],
        [card.fingerprints[CardPlace.decryption], card.fingerprints[CardPlace.authentication]],
      );
      expect(card.log.where((entry) => entry.startsWith('generate')), hasLength(3));
      // The certification, two bindings and the test signature
      expect(card.signatures, 4);
    });
  }

  testWidgets('offers only what both the card and Kemlock can use', (tester) async {
    final (rig, _) = await openWithCard(tester, card: FakeOpenPgpCard(algorithms: fakeCardAlgorithms(curves: false)));
    await openGenerate(tester, rig);

    expect(offered(tester), [CardKeyKind.rsa2048, CardKeyKind.rsa3072, CardKeyKind.rsa4096]);
  });

  testWidgets('a card without an algorithm list is offered the kind its places are set to', (tester) async {
    final (rig, _) = await openWithCard(tester, card: FakeOpenPgpCard(versionMinor: 3, defaultAlgorithm: RsaAttributes.ofBits(2048)));
    await openGenerate(tester, rig);

    expect(offered(tester), [CardKeyKind.rsa2048]);
  });

  testWidgets('RSA 4096 is not offered over NFC', (tester) async {
    final (rig, _) = await openWithCard(tester, card: FakeOpenPgpCard());
    await openGenerate(tester, rig);
    await choose(tester, CardKeyKind.rsa4096);

    expect(find.text(tr('securityKeys.openpgp.generate.usbOnly')), findsOneWidget);
  });

  testWidgets('a card that holds keys says they will be destroyed, and sends nothing before that is confirmed', (tester) async {
    final card = FakeOpenPgpCard();
    await tester.runAsync(() async => card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature))));
    final (rig, vault) = await openWithCard(tester, card: card);
    await openGenerate(tester, rig);
    card.log.clear();
    await fillAndGenerate(tester);

    expect(find.text(tr('securityKeys.openpgp.generate.replace.title')), findsOneWidget);
    await tester.tap(find.text(tr('export.cancel')).last);
    await tester.pumpAndSettle();
    expect(card.log, isEmpty);
    expect(card.pinsSent, isEmpty);
    expect(vault.keys, isEmpty);
  });

  testWidgets('another card held to the phone after the warning keeps its keys, though its PINs are the same', (tester) async {
    final shown = FakeOpenPgpCard();
    final other = FakeOpenPgpCard(serial: 0x87654321);
    for (final card in [shown, other]) {
      await tester.runAsync(() async => card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature))));
    }
    final (rig, vault) = await openWithCard(tester);
    final first = await rig.present(cardKey(shown), nfc);
    await openGenerate(tester, rig);
    await fillAndGenerate(tester);
    await tester.tap(find.text(tr('securityKeys.openpgp.generate.replace.confirm')).last);
    await tester.pumpAndSettle();
    // The PINs are asked for; the first card is taken away and another, with the factory PINs too, held in its place
    await rig.remove(first);
    await rig.present(cardKey(other), nfc);
    other.log.clear();
    await givePins(tester);

    expect(find.text(tr('securityKeys.openpgp.error.otherCard')), findsOneWidget);
    expect(other.keys, hasLength(1));
    expect(other.pinsSent, isEmpty);
    expect(other.log.where((entry) => entry.startsWith('generate') || entry.startsWith('put') || entry.startsWith('verify')), isEmpty);
    expect(vault.keys, isEmpty);
  });

  testWidgets('cut off after the first key, adds nothing and says so; finishing then adds the key', (tester) async {
    final card = FakeOpenPgpCard();
    final (rig, vault) = await openWithCard(tester, card: card);
    var generated = 0;
    rig.phone.removeWhen = (frame) => frame.length > 2 && frame[1] == 0x47 && frame[2] == 0x80 && ++generated == 2;
    await openGenerate(tester, rig);
    await fillAndGenerate(tester);
    await givePins(tester);

    expect(vault.keys, isEmpty);
    expect(find.byKey(const ValueKey('card-generate-incomplete')), findsOneWidget);
    expect(card.keys.length, 1, reason: 'the key left before it took the second');

    rig.phone.removeWhen = null;
    await rig.present(cardKey(card), nfc);
    await tester.tap(find.byKey(const ValueKey('card-generate-finish')));
    await settleReal(tester);
    await givePins(tester);

    final key = vault.keys.single;
    expect(await tester.runAsync(() => verifyPgpSelfSignatures(unb64(key.publicKey!))), isTrue);
    expect(readPgpKeyInfo(unb64(key.publicKey!)).primary.fingerprint, card.fingerprints[CardPlace.signature]);
  });
}
