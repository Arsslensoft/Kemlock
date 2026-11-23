import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/card_pin_change.dart';
import 'package:kemlock/features/security_keys/card_pin_forms.dart';
import 'package:kemlock/features/security_keys/openpgp_card_controller.dart';
import 'package:kemlock/features/security_keys/openpgp_card_sheet.dart';
import 'package:kemlock/features/security_keys/security_key_controller.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_openpgp_card.dart';
import '../../fakes/fake_security_keys.dart';
import 'key_sheet_harness.dart';
import 'openpgp_card_harness.dart';

void main() {
  late FakeOpenPgpCard card;
  late KeySheetRig rig;

  Future<void> open(WidgetTester tester, {void Function(FakeOpenPgpCard card)? setUp}) async {
    card = FakeOpenPgpCard();
    setUp?.call(card);
    (rig, _) = await openWithCard(tester, card: card);
    await openPgpKeys(rig);
  }

  Future<void> tapRow(WidgetTester tester, String key) async {
    final row = find.byKey(ValueKey(key));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextField, label).last, text);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester, String id) async {
    final button = find.descendant(of: find.byType(CardPinChangeForm), matching: find.widgetWithText(FilledButton, tr(id)));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  String? formError(WidgetTester tester) {
    final alert = find.byKey(const ValueKey('card-pin-error'));
    if (alert.evaluate().isEmpty) return null;
    return tester.widget<Text>(find.descendant(of: alert, matching: find.byType(Text)).first).data;
  }

  group('changing the PIN and the admin PIN', () {
    testWidgets('makes the old PIN fail and the new one work', (tester) async {
      await open(tester);
      await tapRow(tester, 'openpgp-pin');
      await fill(tester, tr('securityKeys.pin.current'), '123456');
      await fill(tester, tr('securityKeys.openpgp.field.new.pin'), '654321');
      await fill(tester, tr('securityKeys.openpgp.field.again.pin'), '654321');
      await submit(tester, 'securityKeys.openpgp.change.pin');

      expect(find.byType(CardPinChangeForm), findsNothing);
      expect(card.pin, '654321');
      expect(card.pinTries, 3);
    });

    testWidgets('changes the admin PIN', (tester) async {
      await open(tester);
      await tapRow(tester, 'openpgp-admin');
      await fill(tester, tr('securityKeys.openpgp.adminPin'), '12345678');
      await fill(tester, tr('securityKeys.openpgp.field.new.admin'), '87654321');
      await fill(tester, tr('securityKeys.openpgp.field.again.admin'), '87654321');
      await submit(tester, 'securityKeys.openpgp.change.admin');

      expect(card.adminPin, '87654321');
    });

    for (final (what, next, again, max, error) in [
      ('five characters', '12345', '12345', 127, 'securityKeys.openpgp.rule.pin'),
      ("more than the card's maximum", '123456789', '123456789', 8, 'securityKeys.openpgp.rule.tooLong'),
      ('two different entries', '654321', '654322', 127, 'securityKeys.pin.mismatch'),
    ]) {
      testWidgets('$what send nothing', (tester) async {
        await open(tester, setUp: (card) => card.pinMaxLength = max);
        card.log.clear();
        await tapRow(tester, 'openpgp-pin');
        await fill(tester, tr('securityKeys.pin.current'), '123456');
        await fill(tester, tr('securityKeys.openpgp.field.new.pin'), next);
        await fill(tester, tr('securityKeys.openpgp.field.again.pin'), again);
        await submit(tester, 'securityKeys.openpgp.change.pin');

        expect(formError(tester), tr(error, {'count': max}));
        expect(card.pinsSent, isEmpty);
        expect(card.log.where((entry) => entry.startsWith('change')), isEmpty);
        expect(card.pin, FakeOpenPgpCard.factoryPin);
      });
    }

    testWidgets('a wrong current PIN says so with the tries left', (tester) async {
      await open(tester);
      await tapRow(tester, 'openpgp-pin');
      await fill(tester, tr('securityKeys.pin.current'), '000000');
      await fill(tester, tr('securityKeys.openpgp.field.new.pin'), '654321');
      await fill(tester, tr('securityKeys.openpgp.field.again.pin'), '654321');
      await submit(tester, 'securityKeys.openpgp.change.pin');

      expect(formError(tester), '${tr('securityKeys.openpgp.wrong.pin')} ${tr('securityKeys.pin.triesLeft', {'count': 2})}');
      expect(card.pinTries, 2);
    });
  });

  group('unblocking', () {
    testWidgets('with the admin PIN restores full tries', (tester) async {
      await open(tester, setUp: (card) => card.pinTries = 0);
      expect(rowValue(tester, 'openpgp-pin'), contains(tr('securityKeys.openpgp.blocked')));
      await tapRow(tester, 'openpgp-pin');
      expect(find.byType(SegmentedControl<bool>), findsNothing, reason: 'no reset code is set');
      await fill(tester, tr('securityKeys.openpgp.adminPin'), '12345678');
      await fill(tester, tr('securityKeys.openpgp.field.new.pin'), '246802');
      await fill(tester, tr('securityKeys.openpgp.field.again.pin'), '246802');
      await submit(tester, 'securityKeys.openpgp.change.unblock');

      expect(card.pinTries, 3);
      expect(card.pin, '246802');
    });

    testWidgets('with the reset code restores full tries, and a wrong one shows its tries left', (tester) async {
      await open(
        tester,
        setUp: (card) => card
          ..pinTries = 0
          ..resetCode = '87654321'
          ..resetCodeTries = 3,
      );
      await tapRow(tester, 'openpgp-pin');
      await fill(tester, tr('securityKeys.openpgp.resetCode'), '00000000');
      await fill(tester, tr('securityKeys.openpgp.field.new.pin'), '246802');
      await fill(tester, tr('securityKeys.openpgp.field.again.pin'), '246802');
      await submit(tester, 'securityKeys.openpgp.change.unblock');
      expect(formError(tester), '${tr('securityKeys.openpgp.wrong.resetCode')} ${tr('securityKeys.pin.triesLeft', {'count': 2})}');

      await fill(tester, tr('securityKeys.openpgp.resetCode'), '87654321');
      await submit(tester, 'securityKeys.openpgp.change.unblock');

      expect(card.pinTries, 3);
      expect(card.resetCodeTries, 3);
      expect(card.pin, '246802');
    });

    testWidgets('sets the reset code with the admin PIN', (tester) async {
      await open(tester);
      await tapRow(tester, 'openpgp-reset-code');
      await fill(tester, tr('securityKeys.openpgp.adminPin'), '12345678');
      await fill(tester, tr('securityKeys.openpgp.field.new.resetCode'), '11223344');
      await fill(tester, tr('securityKeys.openpgp.field.again.resetCode'), '11223344');
      await submit(tester, 'securityKeys.openpgp.change.resetCode');

      expect(card.resetCode, '11223344');
      expect(rowValue(tester, 'openpgp-reset-code'), contains(tr('securityKeys.pin.triesLeft', {'count': 3})));
    });

    testWidgets('with both PINs blocked and no reset code, only the factory reset remains', (tester) async {
      await open(
        tester,
        setUp: (card) => card
          ..pinTries = 0
          ..adminPinTries = 0,
      );

      expect(find.byKey(const ValueKey('openpgp-all-blocked')), findsOneWidget);
      expect(tappable(tester, find.byKey(const ValueKey('openpgp-pin'))), isFalse);
    });
  });

  group('the PIN for every signature', () {
    testWidgets('changes with the admin PIN, and the card reports it', (tester) async {
      await open(tester);
      expect(card.pinForEverySignature, isTrue);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('openpgp-every-signature')), matching: find.byType(AppSwitch)));
      await tester.pumpAndSettle();
      expect(find.byType(CardPinPrompt), findsOneWidget);
      expect(find.text(tr('securityKeys.openpgp.adminPin')), findsWidgets);
      await tester.enterText(find.descendant(of: find.byType(CardPinPrompt), matching: find.byType(TextField)), '12345678');
      await tester.pump();
      await tester.tap(find.text(tr('securityKeys.pin.continue')));
      await tester.pumpAndSettle();

      expect(card.pinForEverySignature, isFalse);
      expect(
        tester
            .widget<AppSwitch>(find.descendant(of: find.byKey(const ValueKey('openpgp-every-signature')), matching: find.byType(AppSwitch)))
            .value,
        isFalse,
      );
    });

    group('on an iPhone, where each read is a connection of its own,', () {
      final toggle = find.descendant(of: find.byKey(const ValueKey('openpgp-every-signature')), matching: find.byType(AppSwitch));

      /// Reads [card] as the sheet is opened, then asks to change the
      /// setting: the card is read, and the admin PIN asked for.
      Future<void> askForAdminPin(WidgetTester tester) async {
        card = FakeOpenPgpCard();
        (rig, _) = await openWithCard(tester, capabilities: FakeSecurityKeys.iphone);
        rig.phone.arrive(cardKey(card).device(kinds: nfc));
        await rig.tap('securityKeys.wait.iphone.read');
        await openPgpKeys(rig);
        rig.phone.arrive(cardKey(card).device(kinds: nfc));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(CardPinPrompt), findsOneWidget);
      }

      testWidgets('the admin PIN typed after a read goes to the next, and no further', (tester) async {
        await askForAdminPin(tester);
        rig.phone.arrive(cardKey(card).device(kinds: nfc));
        await typeCardPin(tester, '12345678');

        expect(find.byType(CardPinPrompt), findsNothing, reason: 'asked once');
        expect(card.pinForEverySignature, isFalse);
        expect(OpenPgpCardController.of(_keysOf(tester))!.holdsAnyPin, isFalse, reason: 'the read is over, and the PIN went with it');
      });

      testWidgets('a PIN typed for one card is not sent to another read in its place', (tester) async {
        await askForAdminPin(tester);
        final other = FakeOpenPgpCard(serial: 0x87654321);
        rig.phone.arrive(cardKey(other).device(kinds: nfc));
        await typeCardPin(tester, '12345678');

        expect(other.pinsSent, isEmpty);
        expect(other.pinForEverySignature, isTrue);
        expect(find.byType(CardPinPrompt), findsOneWidget, reason: 'the other card is asked for its own');
      });
    });
  });

  testWidgets('a key taken away during a change says the PIN may be either, and keeps no PIN', (tester) async {
    await open(tester);
    rig.phone.removeWhen = (frame) => frame.length > 1 && frame[1] == 0x24;
    rig.phone.removeAfterProcessing = true;
    await tapRow(tester, 'openpgp-pin');
    await fill(tester, tr('securityKeys.pin.current'), '123456');
    await fill(tester, tr('securityKeys.openpgp.field.new.pin'), '654321');
    await fill(tester, tr('securityKeys.openpgp.field.again.pin'), '654321');
    await submit(tester, 'securityKeys.openpgp.change.pin');

    expect(formError(tester), tr('securityKeys.openpgp.takenAway'));
    expect(OpenPgpCardController.of(_keysOf(tester))!.holdsAnyPin, isFalse);
    expect(rig.store.storedKeys(), isNot(contains(matches('pin'))));
  });
}

/// The Security key sheet's controller, from its PGP keys row.
SecurityKeyController _keysOf(WidgetTester tester) => tester.widget<OpenPgpKeysRow>(find.byType(OpenPgpKeysRow, skipOffstage: false)).keys;
