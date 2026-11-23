import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/features/keys/key_widgets.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';

final _expires = DateTime.utc(2026, 11, 23);

void main() {
  for (final (name, standing, word, tone) in [
    (
      'expiring in 7 days',
      KeyStanding(standing: Standing.expiringSoon, expires: _expires, daysLeft: 7),
      'Expires in 7 days',
      StatusTone.warning,
    ),
    (
      'expiring tomorrow',
      KeyStanding(standing: Standing.expiringSoon, expires: _expires, daysLeft: 1),
      'Expires in 1 day',
      StatusTone.warning,
    ),
    ('expiring today', KeyStanding(standing: Standing.expiringSoon, expires: _expires, daysLeft: 0), 'Expires today', StatusTone.warning),
    ('expired', KeyStanding(standing: Standing.expired, expires: _expires), 'Expired', StatusTone.danger),
    ('revoked', const KeyStanding(standing: Standing.revoked), 'Revoked', StatusTone.danger),
  ]) {
    testWidgets('a key $name carries a tag saying so', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpOnPage(tester, KeyStandingTag(standing: standing));

      // In capitals on screen, and as written for a screen reader
      expect(find.text(word.toUpperCase()), findsOneWidget);
      expect(find.bySemanticsLabel(word), findsOneWidget);
      expect(tester.widget<StatusTag>(find.byType(StatusTag)).tone, tone);
      semantics.dispose();
    });
  }

  testWidgets('a key in order carries none', (tester) async {
    await pumpOnPage(
      tester,
      KeyStandingTag(
        standing: KeyStanding(standing: Standing.ok, expires: _expires, daysLeft: 300),
      ),
    );
    expect(find.byType(StatusTag), findsNothing);
    expect(find.byType(Text), findsNothing);

    await pumpOnPage(tester, const KeyStandingTag(standing: KeyStanding.ok));
    expect(find.byType(StatusTag), findsNothing);
  });

  testWidgets('the tag is in the warning colour on its soft ground, or the error colour on its', (tester) async {
    for (final (tone, ink, ground) in [
      (StatusTone.warning, (BuildContext c) => c.palette.warning, (BuildContext c) => c.bmc.warnSoft),
      (StatusTone.danger, (BuildContext c) => c.palette.error, (BuildContext c) => c.bmc.dangerSoft),
    ]) {
      await pumpOnPage(tester, StatusTag(label: 'Revoked', tone: tone));

      final context = tester.element(find.byType(StatusTag));
      expect(tester.widget<Text>(find.text('REVOKED')).style!.color, ink(context));
      final box = tester.widget<Container>(find.descendant(of: find.byType(StatusTag), matching: find.byType(Container)));
      expect((box.decoration! as BoxDecoration).color, ground(context));
      // The shape of the badges beside it
      expect(tester.getSize(find.byType(StatusTag)).height, 20);
    }
  });

  test('the tag is worded in the language asked for', () {
    final fr = testCatalog.of(AppLocale.fr);

    expect(standingLabel(fr, KeyStanding(standing: Standing.expiringSoon, expires: _expires, daysLeft: 7)), 'Expire dans 7 jours');
    expect(standingLabel(fr, KeyStanding(standing: Standing.expiringSoon, expires: _expires, daysLeft: 1)), 'Expire dans 1 jour');
    expect(standingLabel(fr, KeyStanding(standing: Standing.expiringSoon, expires: _expires, daysLeft: 0)), 'Expire aujourd’hui');
    expect(standingLabel(fr, const KeyStanding(standing: Standing.revoked)), 'Révoquée');
    expect(standingLabel(fr, KeyStanding(standing: Standing.expired, expires: _expires)), 'Expirée');
    expect(standingLabel(fr, KeyStanding.ok), isNull);
  });

  testWidgets('a row with a tag is still one button, with the tag in the place of its chevron', (tester) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await pumpOnPage(
      tester,
      Group(
        children: [
          GroupRow(
            first: true,
            icon: const Text('PGP'),
            accent: true,
            primary: 'Ada Lovelace',
            secondary: 'ada@example.org · Ed25519',
            tag: const StatusTag(label: 'Revoked', tone: StatusTone.danger),
            onTap: () => taps++,
          ),
        ],
      ),
    );

    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    await tester.tap(find.text('Ada Lovelace'));
    expect(taps, 1);
    expect(
      tester.getSemantics(find.text('Ada Lovelace')),
      isSemantics(isButton: true, label: 'Ada Lovelace\nada@example.org · Ed25519\nRevoked'),
    );
    semantics.dispose();
  });
}
