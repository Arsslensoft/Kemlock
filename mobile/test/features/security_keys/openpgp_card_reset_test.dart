import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../security_key/hex.dart';
import 'key_sheet_harness.dart';
import 'openpgp_card_harness.dart';

final _resetButton = find.byKey(const ValueKey('openpgp-reset'));
final _confirm = find.byKey(const ValueKey('openpgp-reset-confirm'));

Future<FakeOpenPgpCard> _cardWithKeys() async {
  final card = FakeOpenPgpCard()
    ..pin = '654321'
    ..adminPin = '87654321'
    ..forbidden.addAll([FakeOpenPgpCard.factoryPin, FakeOpenPgpCard.factoryAdminPin]);
  for (final place in [CardPlace.signature, CardPlace.decryption]) {
    card.load(place, await FakeCardKey.generate(fake25519(place)), fingerprint: unhex('${place.index + 1}' * 40));
  }
  return card;
}

void main() {
  Future<void> startReset(WidgetTester tester) async {
    await tester.ensureVisible(_resetButton);
    await tester.pumpAndSettle();
    await tester.tap(_resetButton);
    await tester.pumpAndSettle();
  }

  bool confirmable(WidgetTester tester) => tester.widget<FilledButton>(_confirm).onPressed != null;

  testWidgets('cannot start without the whole word typed', (tester) async {
    final card = (await tester.runAsync(_cardWithKeys))!;
    final (rig, _) = await openWithCard(tester, card: card);
    await openPgpKeys(rig);
    card.log.clear();
    await startReset(tester);

    expect(confirmable(tester), isFalse);
    await tester.enterText(find.byKey(const ValueKey('openpgp-reset-word')), 'RESE');
    await tester.pump();
    expect(confirmable(tester), isFalse);
    await tester.tap(find.text(tr('export.cancel')).last);
    await tester.pumpAndSettle();

    expect(card.log, isEmpty);
    expect(card.keys, hasLength(2));
  });

  testWidgets('empties the places and gives back the factory PINs', (tester) async {
    final card = (await tester.runAsync(_cardWithKeys))!;
    final (rig, _) = await openWithCard(tester, card: card);
    await openPgpKeys(rig);
    await startReset(tester);
    await tester.enterText(find.byKey(const ValueKey('openpgp-reset-word')), tr('securityKeys.openpgp.reset.word'));
    await tester.pump();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(card.keys, isEmpty);
    expect(card.pin, FakeOpenPgpCard.factoryPin);
    expect(card.adminPin, FakeOpenPgpCard.factoryAdminPin);
    expect((card.pinTries, card.adminPinTries), (3, 3));
    expect(card.log, containsAllInOrder(['terminate', 'activate']));
    for (final place in CardPlace.values) {
      expect(rowValue(tester, 'openpgp-place-${place.name}'), contains(tr('securityKeys.openpgp.place.empty')));
    }
    // Blocking the PINs used values nobody typed, never the factory ones
    expect(card.forbiddenSeen, isEmpty);
  });

  testWidgets('another key held to the phone after the warning is left as it is', (tester) async {
    final shown = (await tester.runAsync(_cardWithKeys))!;
    final other = FakeOpenPgpCard(serial: 0x87654321)
      ..pin = '654321'
      ..adminPin = '87654321';
    other.load(
      CardPlace.signature,
      (await tester.runAsync(() => FakeCardKey.generate(fake25519(CardPlace.signature))))!,
      fingerprint: unhex('9' * 40),
    );
    final (rig, _) = await openWithCard(tester);
    final first = await rig.present(cardKey(shown), nfc);
    await openPgpKeys(rig);
    await startReset(tester);
    // The warning is up for the first key: it is taken away and a second one held in its place
    await rig.remove(first);
    await rig.present(cardKey(other), nfc);
    other.log.clear();
    await tester.enterText(find.byKey(const ValueKey('openpgp-reset-word')), tr('securityKeys.openpgp.reset.word'));
    await tester.pump();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(find.text(tr('securityKeys.openpgp.error.otherCard')), findsOneWidget);
    expect(other.keys, hasLength(1));
    expect((other.pinTries, other.adminPinTries), (3, 3));
    expect(other.pinsSent, isEmpty);
    expect(other.log.where((entry) => entry.startsWith('verify') || entry == 'terminate'), isEmpty);
    expect(shown.keys, hasLength(2));
  });

  testWidgets('a card left terminated is offered to finish on the next connection', (tester) async {
    final card = (await tester.runAsync(_cardWithKeys))!;
    final (rig, _) = await openWithCard(tester, card: card);
    rig.phone.removeWhen = (frame) => frame.length > 1 && frame[1] == 0xe6;
    rig.phone.removeAfterProcessing = true;
    await openPgpKeys(rig);
    await startReset(tester);
    await tester.enterText(find.byKey(const ValueKey('openpgp-reset-word')), tr('securityKeys.openpgp.reset.word'));
    await tester.pump();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(card.terminated, isTrue, reason: 'the key left once terminated');

    rig.phone.removeWhen = null;
    await rig.close();
    await rig.close();
    await rig.reopen();
    await rig.present(cardKey(card), nfc);
    expect(
      find.descendant(of: find.byKey(const ValueKey('openpgp-row')), matching: find.text(tr('securityKeys.openpgp.summary.terminated'))),
      findsOneWidget,
    );
    await openPgpKeys(rig);
    final finish = find.byKey(const ValueKey('openpgp-finish-reset'));
    expect(finish, findsOneWidget);
    await tester.tap(finish);
    await tester.pumpAndSettle();

    expect(card.terminated, isFalse);
    expect(card.keys, isEmpty);
    expect(card.pin, FakeOpenPgpCard.factoryPin);
  });

  testWidgets('a card that reports no life cycle support is not offered the reset', (tester) async {
    final (rig, _) = await openWithCard(tester, card: FakeOpenPgpCard(lifeCycle: false));
    await openPgpKeys(rig);

    expect(_resetButton, findsNothing);
  });
}
