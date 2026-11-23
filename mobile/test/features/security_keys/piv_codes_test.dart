import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/security_keys/piv_codes_sheet.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:kemlock/ui/ui.dart';

import '../../fakes/fake_piv_card.dart';
import '../../helpers/test_app.dart';
import 'piv_harness.dart';

void main() {
  /// Opens the sheet of the PIN or the PUK on [card].
  Future<PivRig> openCode(WidgetTester tester, FakePivCard card, PivCode code) async {
    final rig = await openPivRig(tester, card: card);
    await rig.openCertificates();
    await rig.keys.tapRow(code == PivCode.pin ? 'piv.pin' : 'piv.puk');
    expect(find.byType(PivCodeSheet), findsOneWidget);
    return rig;
  }

  /// Types the three fields of the open form and sends it.
  Future<void> send(PivRig rig, String current, String next, [String? again]) async {
    final fields = find.descendant(of: find.byType(PivCodeSheet), matching: find.byType(TextField));
    await rig.tester.enterText(fields.at(0), current);
    await rig.tester.enterText(fields.at(1), next);
    await rig.tester.enterText(fields.at(2), again ?? next);
    await rig.tester.pump();
    final button = find.descendant(of: find.byType(PivCodeSheet), matching: find.byType(FilledButton));
    await rig.tester.ensureVisible(button);
    await rig.tester.tap(button);
    await rig.tester.pumpAndSettle();
  }

  List<String> codeChanges(FakePivCard card) => [
    for (final line in card.log)
      if (line.startsWith('change') || line == 'unblock' || line == 'verify') line,
  ];

  group('changing', () {
    testWidgets('the PIN: the old one fails after, and the new one works', (tester) async {
      final rig = await openCode(tester, FakePivCard(), PivCode.pin);
      await send(rig, '123456', '271828');

      expect(rig.card.pin, '271828');
      expect(find.byType(PivCodeSheet), findsNothing);
      expect(find.text(t('piv.pin.changed')), findsOneWidget);
      // Read again: the factory warning has gone for the PIN, and stays for the PUK
      expect(find.text(t('piv.codes.factory', {'codes': 'puk'})), findsOneWidget);
    });

    testWidgets('the PUK, with its own length', (tester) async {
      final rig = await openCode(tester, FakePivCard(), PivCode.puk);
      await send(rig, '12345678', '31415926');
      expect(rig.card.puk, '31415926');
    });

    testWidgets('sends nothing for a PIN of 5 or 9 characters, the factory PIN, or two entries that differ', (tester) async {
      final rig = await openCode(tester, FakePivCard(), PivCode.pin);
      for (final (next, again, message) in [
        ('12345', '12345', 'piv.pin.length'),
        ('123456789', '123456789', 'piv.pin.length'),
        ('123456', '123456', 'piv.pin.factoryRefused'),
        ('271828', '271829', 'piv.code.mismatch'),
      ]) {
        await send(rig, '123456', next, again);
        expect(find.text(t(message)), findsOneWidget, reason: next);
      }
      expect(codeChanges(rig.card), isEmpty);
      expect(rig.card.pin, pivFactoryPin);
    });

    testWidgets('sends nothing for a PUK of 7 characters, or the factory PUK', (tester) async {
      final rig = await openCode(tester, FakePivCard(), PivCode.puk);
      await send(rig, '12345678', '1234567');
      expect(find.text(t('piv.puk.length')), findsOneWidget);
      await send(rig, '12345678', '12345678');
      expect(find.text(t('piv.puk.factoryRefused')), findsOneWidget);
      expect(codeChanges(rig.card), isEmpty);
    });
  });

  group('tries', () {
    testWidgets('a wrong PIN says so with the tries now left', (tester) async {
      final rig = await openCode(tester, FakePivCard(), PivCode.pin);
      await send(rig, '000000', '271828');
      expect(find.text('${t('piv.pin.wrong')} ${t('securityKeys.pin.triesLeft', {'count': 2})}'), findsOneWidget);
      expect(rig.card.pinTries, 2);
    });

    testWidgets('one try left is warned of, and asked again before it is sent', (tester) async {
      final rig = await openCode(tester, FakePivCard()..pinTries = 1, PivCode.pin);
      expect(find.text(t('piv.lastTry.pin')), findsOneWidget);
      await send(rig, '000000', '271828');
      expect(find.text(t('piv.lastTry.title')), findsOneWidget);
      expect(codeChanges(rig.card), isEmpty, reason: 'nothing before the person agrees');
      await tester.tap(find.text(t('export.cancel')).last);
      await tester.pumpAndSettle();
      expect(codeChanges(rig.card), isEmpty);
      expect(rig.card.pinTries, 1);

      await send(rig, '000000', '271828');
      await tester.tap(find.widgetWithText(FilledButton, t('piv.continue')));
      await tester.pumpAndSettle();
      expect(rig.card.pinTries, 0);
    });

    testWidgets('a blocked PIN is unblocked with the PUK, and has its full tries again', (tester) async {
      final rig = await openCode(tester, FakePivCard()..pinTries = 0, PivCode.pin);
      expect(find.text(t('piv.pin.unblock.body')), findsOneWidget);
      expect(find.widgetWithText(TextField, t('piv.puk.current')), findsOneWidget);

      await send(rig, '12345678', '161803');

      expect((rig.card.pin, rig.card.pinTries), ('161803', 3));
      expect(codeChanges(rig.card), ['unblock']);
      expect(find.text(t('piv.pin.unblocked')), findsOneWidget);
    });

    testWidgets('with no PUK tries left nothing is sent, and with both blocked only a reset remains', (tester) async {
      final pukRig = await openCode(tester, FakePivCard()..pukTries = 0, PivCode.puk);
      expect(find.text(t('piv.puk.blocked')), findsOneWidget);
      expect(find.descendant(of: find.byType(PivCodeSheet), matching: find.byType(TextField)), findsNothing);
      expect(codeChanges(pukRig.card), isEmpty);

      final both = await openCode(
        tester,
        FakePivCard()
          ..pinTries = 0
          ..pukTries = 0,
        PivCode.pin,
      );
      expect(find.descendant(of: find.byType(PivCodeSheet), matching: find.text(t('piv.codes.bothBlocked'))), findsOneWidget);
      expect(find.descendant(of: find.byType(PivCodeSheet), matching: find.byType(TextField)), findsNothing);
      expect(codeChanges(both.card), isEmpty);
    });
  });

  testWidgets('the codes typed are gone once the app was hidden', (tester) async {
    final rig = await openCode(tester, FakePivCard(), PivCode.pin);
    final fields = find.descendant(of: find.byType(PivCodeSheet), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), '271828');
    hideAndShow(tester);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      expect(tester.widget<TextField>(fields.at(i)).controller!.text, isEmpty);
    }
    expect(rig.card.pin, pivFactoryPin);
  });

  group('factory codes', () {
    testWidgets('are warned of on a card whose metadata reports them', (tester) async {
      await openCode(tester, FakePivCard(), PivCode.pin);
      expect(find.text(t('piv.pin.factoryWarning')), findsOneWidget);
      expect(find.text(t('piv.codes.factory', {'codes': 'both'})), findsOneWidget, reason: 'on the Certificates sheet below');
    });

    testWidgets('are not guessed at on a standard-only card, and no counter moves', (tester) async {
      final card = FakePivCard(makerCommands: false);
      await openCode(tester, card, PivCode.pin);
      expect(find.textContaining('123456'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(PivCodeSheet),
          matching: find.byWidgetPredicate((widget) => widget is AppAlert && widget.severity == AlertSeverity.warning),
        ),
        findsNothing,
      );
      expect((card.pinTries, card.pukTries), (3, 3));
      expect(codeChanges(card), isEmpty);
    });
  });
}
