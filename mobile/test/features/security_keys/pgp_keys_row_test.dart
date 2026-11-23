import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/openpgp_card_controller.dart';
import 'package:kemlock/features/security_keys/openpgp_card_sheet.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_piv_card.dart';
import '../../fakes/fake_security_keys.dart';
import 'openpgp_card_harness.dart';
import 'piv_harness.dart';

final _row = find.byKey(const ValueKey('openpgp-row'));

/// A card with a signature and a decryption key.
Future<FakeOpenPgpCard> _twoKeys() async {
  final card = FakeOpenPgpCard();
  for (final place in [CardPlace.signature, CardPlace.decryption]) {
    card.load(place, await FakeCardKey.generate(fake25519(place)), fingerprint: Uint8List(20)..[0] = place.index + 1);
  }
  return card;
}

void main() {
  testWidgets('says what the card\'s keys do: "Sign, decrypt"', (tester) async {
    final card = (await tester.runAsync(_twoKeys))!;
    await openWithCard(tester, card: card);

    expect(_row, findsOneWidget);
    expect(find.descendant(of: _row, matching: find.text(tr('securityKeys.openpgp.row'))), findsOneWidget);
    expect(find.descendant(of: _row, matching: find.text('Sign, decrypt')), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Group && widget.label == tr('securityKeys.section.also')), findsOneWidget);
    expect(card.log.where((entry) => entry.startsWith('verify')), isEmpty, reason: 'reading needs no PIN');
  });

  // Joined with add-piv-management and add-security-key-codes: one group, in the mockup's order
  testWidgets('sits in the one "Also on this key" group, between Codes and Certificates', (tester) async {
    final card = (await tester.runAsync(_twoKeys))!;
    final (rig, _) = await openWithCard(tester, overrides: [FakePivNotes().asOverride]);
    await rig.present(FakeKey(productName: 'Example Key', ctap: FakeFidoKey(), applets: [card, FakePivCard()]), nfc);

    final also = find.byWidgetPredicate((widget) => widget is Group && widget.label == tr('securityKeys.section.also'));
    expect(also, findsOneWidget);
    final rows = [keyRow('keyCodes.row'), _row, keyRow('piv.title')];
    for (final row in rows) {
      expect(find.descendant(of: also, matching: row), findsOneWidget);
    }
    final tops = [for (final row in rows) tester.getTopLeft(row).dy];
    expect(tops[0], lessThan(tops[1]));
    expect(tops[1], lessThan(tops[2]));
    expect(tester.widget<GroupRow>(_row).first, isFalse, reason: 'a hairline under Codes');
  });

  testWidgets('says "Empty" for a card with no key', (tester) async {
    await openWithCard(tester, card: FakeOpenPgpCard());

    expect(find.descendant(of: _row, matching: find.text(tr('securityKeys.openpgp.summary.empty'))), findsOneWidget);
  });

  testWidgets('is not there for a key without the application', (tester) async {
    final (rig, _) = await openWithCard(tester);
    await rig.present(FakeKey(productName: 'Example Key', fido: false), nfc);

    expect(find.text('Example Key'), findsNothing, reason: 'over NFC a key gives no name');
    expect(_row, findsNothing);
    expect(find.text(tr('securityKeys.openpgp.row')), findsNothing);
  });

  // Joined with add-piv-management: the card is one of the sheet's readers, and its actions open no FIDO2
  testWidgets("is read by one of the sheet's readers, and acts on the card without opening FIDO2", (tester) async {
    final card = (await tester.runAsync(_twoKeys))!;
    final (rig, _) = await openWithCard(tester);
    await rig.present(FakeKey(productName: 'Example Key', ctap: FakeFidoKey(), applets: [card]), nfc);

    expect(find.descendant(of: _row, matching: find.text('Sign, decrypt')), findsOneWidget);
    final keys = tester.widget<OpenPgpKeysRow>(find.byType(OpenPgpKeysRow)).keys;
    final controller = OpenPgpCardController.of(keys)!;
    expect(keys.readers, contains(controller.peek));
    bool fidoSelected() => rig.phone.sent.any((frame) => frame.hex.contains('a0000006472f0001'));
    expect(fidoSelected(), isTrue, reason: 'the read opens FIDO2 first');

    rig.phone.sent.clear();
    card.log.clear();
    final read = await tester.runAsync(() => controller.run((session) async => session.snapshot));

    expect(read, isNotNull);
    expect(card.log.first, 'select');
    expect(rig.phone.sent, isNotEmpty);
    expect(fidoSelected(), isFalse, reason: 'the action opens the card only');
  });
}
