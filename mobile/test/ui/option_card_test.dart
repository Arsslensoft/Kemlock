import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

// openspec: add-post-quantum-pgp, task 7.1

/// The radio mark's ring: the first decorated circle in the card.
BoxDecoration _mark(WidgetTester tester, String title) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(of: find.widgetWithText(OptionCard, title), matching: find.byType(AnimatedContainer)),
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  Widget cards({required String selected, required void Function(String) onTap}) => Column(
    children: [
      for (final title in ['Ed25519', 'Post-quantum, standard'])
        OptionCard(
          title: title,
          caption: 'Caption of $title.',
          tag: title == 'Post-quantum, standard' ? 'Recommended' : null,
          selected: selected == title,
          onTap: () => onTap(title),
        ),
    ],
  );

  testWidgets('the selected card has the accent and a filled mark, the other a plain ring', (tester) async {
    await pumpOnPage(tester, cards(selected: 'Post-quantum, standard', onTap: (_) {}));
    final on = _mark(tester, 'Post-quantum, standard');
    final off = _mark(tester, 'Ed25519');
    expect((on.border! as Border).top.width, 7);
    expect((off.border! as Border).top.width, 2);
    expect(on.color, isNotNull);
    expect(off.color, isNull);
    final onShape =
        tester
                .widget<Material>(
                  find.descendant(of: find.widgetWithText(OptionCard, 'Post-quantum, standard'), matching: find.byType(Material)).first,
                )
                .shape!
            as RoundedRectangleBorder;
    final offShape =
        tester
                .widget<Material>(find.descendant(of: find.widgetWithText(OptionCard, 'Ed25519'), matching: find.byType(Material)).first)
                .shape!
            as RoundedRectangleBorder;
    expect(onShape.side.color, isNot(offShape.side.color));
  });

  testWidgets('the tag shows beside the title, in capitals, on its card only', (tester) async {
    await pumpOnPage(tester, cards(selected: 'Ed25519', onTap: (_) {}));
    expect(find.text('RECOMMENDED'), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(OptionCard, 'Post-quantum, standard'), matching: find.text('RECOMMENDED')),
      findsOneWidget,
    );
    expect(find.text('Caption of Ed25519.'), findsOneWidget);
  });

  testWidgets('a tap chooses the card', (tester) async {
    final tapped = <String>[];
    await pumpOnPage(tester, cards(selected: 'Ed25519', onTap: tapped.add));
    await tester.tap(find.text('Post-quantum, standard'));
    expect(tapped, ['Post-quantum, standard']);
  });

  testWidgets('a screen reader hears a radio button named by the title', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpOnPage(tester, cards(selected: 'Post-quantum, standard', onTap: (_) {}));
    expect(
      tester.getSemantics(find.widgetWithText(OptionCard, 'Post-quantum, standard')),
      matchesSemantics(
        label: 'Post-quantum, standard',
        hint: 'Caption of Post-quantum, standard.',
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        isChecked: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.widgetWithText(OptionCard, 'Ed25519')),
      matchesSemantics(
        label: 'Ed25519',
        hint: 'Caption of Ed25519.',
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });
}
