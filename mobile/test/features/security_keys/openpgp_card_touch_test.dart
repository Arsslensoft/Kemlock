import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/keys/card_key_use.dart';
import 'package:kemlock/features/security_keys/card_pin_forms.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_openpgp_card.dart';
import 'key_sheet_harness.dart';
import 'openpgp_card_harness.dart';

void main() {
  late FakeOpenPgpCard card;
  late KeySheetRig rig;

  Future<void> open(WidgetTester tester) async {
    card = FakeOpenPgpCard();
    (rig, _) = await openWithCard(tester, card: card);
    await openPgpKeys(rig);
  }

  Future<void> choose(WidgetTester tester, CardPlace place, TouchPolicy policy) async {
    final row = find.byKey(ValueKey('openpgp-touch-${place.name}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('touch-choice-${policy.name}')));
    await tester.pumpAndSettle();
  }

  Future<void> typeAdminPin(WidgetTester tester) async {
    await tester.enterText(
      find.descendant(of: find.byType(CardPinPrompt), matching: find.byType(TextField)),
      FakeOpenPgpCard.factoryAdminPin,
    );
    await tester.pump();
    await tester.tap(find.text(tr('securityKeys.pin.continue')));
    await tester.pumpAndSettle();
  }

  testWidgets('turns touch on and off with the admin PIN', (tester) async {
    await open(tester);

    await choose(tester, CardPlace.signature, TouchPolicy.on);
    expect(find.byType(CardPinPrompt), findsOneWidget);
    await typeAdminPin(tester);
    expect(card.touch[CardPlace.signature], TouchPolicy.on);
    expect(rowValue(tester, 'openpgp-touch-signature'), contains(tr('securityKeys.openpgp.touch.on')));

    // The admin PIN is kept for the connection: it is not asked again
    await choose(tester, CardPlace.signature, TouchPolicy.off);
    expect(find.byType(CardPinPrompt), findsNothing);
    expect(card.touch[CardPlace.signature], TouchPolicy.off);
  });

  testWidgets('a setting the card will not undo changes nothing until it is confirmed', (tester) async {
    await open(tester);
    card.log.clear();

    await choose(tester, CardPlace.decryption, TouchPolicy.fixed);
    expect(find.text(tr('securityKeys.openpgp.touch.permanent.title')), findsOneWidget);
    await tester.tap(find.text(tr('export.cancel')).last);
    await tester.pumpAndSettle();
    expect(card.touch[CardPlace.decryption], TouchPolicy.off);
    expect(card.log, isEmpty);

    await choose(tester, CardPlace.decryption, TouchPolicy.fixed);
    await tester.tap(find.text(tr('securityKeys.openpgp.touch.permanent.confirm')));
    await tester.pumpAndSettle();
    await typeAdminPin(tester);

    expect(card.touch[CardPlace.decryption], TouchPolicy.fixed);
    expect(tappable(tester, find.byKey(const ValueKey('openpgp-touch-decryption'))), isFalse, reason: 'it cannot be changed back');
  });

  testWidgets('a signature after touch was turned on waits for the touch and shows the prompt', (tester) async {
    card = FakeOpenPgpCard();
    await tester.runAsync(() async => card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature))));
    card.setTouch(CardPlace.signature, TouchPolicy.on);
    (rig, _) = await openWithCard(tester);
    // The Security key sheet's own search for keys is ended first
    await rig.close();
    final touched = Completer<void>();
    var promptWhileWaiting = false;
    card.onTouch = (place) async {
      await tester.pump();
      promptWhileWaiting = find.text(tr('securityKeys.activity.touch')).evaluate().isNotEmpty;
      await touched.future;
    };

    unawaited(
      showAppBottomSheet<Object>(
        tester.element(find.byType(Scaffold).first),
        label: 'card',
        builder: (_) => CardUseSheet(name: 'Card key', serial: '1234 5678', signs: true, action: (session) => session.sign(Uint8List(64))),
      ),
    );
    await tester.pumpAndSettle();
    await rig.present(cardKey(card), nfc);
    await tester.enterText(find.descendant(of: find.byType(CardPinPrompt), matching: find.byType(TextField)), FakeOpenPgpCard.factoryPin);
    await tester.pump();
    await tester.tap(find.text(tr('securityKeys.pin.continue')));
    await tester.pump();
    await tester.pump();

    expect(card.touches, 1);
    expect(promptWhileWaiting, isTrue);
    touched.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CardUseSheet), findsNothing);
    expect(card.signatures, 1);
  });
}
