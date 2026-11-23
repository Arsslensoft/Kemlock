import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/settings/vault_health_card.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/test_app.dart';

/// Five items, the first [ok] of them ticked.
List<HealthItem> _items(int ok, {VoidCallback? onSetUp}) => [
  for (var i = 0; i < 5; i++)
    HealthItem(
      id: 'item$i',
      ok: i < ok,
      title: 'Item $i',
      detail: i < ok ? 'Fine $i' : 'Missing $i',
      action: (label: 'Fix $i', onPressed: onSetUp ?? () {}),
    ),
];

void main() {
  testWidgets('scores the ticked items', (tester) async {
    await pumpOnPage(tester, VaultHealthCard(items: _items(3)));

    expect(find.text('3/5'), findsOneWidget);
    expect(find.text(t('settings.health.label').toUpperCase()), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      expect(find.text('Item $i'), findsOneWidget);
    }
  });

  testWidgets('names the score from at risk to excellent', (tester) async {
    for (final (ok, id) in [
      (0, 'settings.health.atRisk'),
      (1, 'settings.health.atRisk'),
      (2, 'settings.health.attention'),
      (3, 'settings.health.attention'),
      (4, 'settings.health.good'),
      (5, 'settings.health.excellent'),
    ]) {
      await pumpOnPage(tester, VaultHealthCard(items: _items(ok)));
      expect(find.text(t(id)), findsOneWidget, reason: '$ok of 5');
    }
  });

  testWidgets('offers the action of each item that is not ticked', (tester) async {
    var pressed = 0;
    await pumpOnPage(tester, VaultHealthCard(items: _items(3, onSetUp: () => pressed++)));

    expect(find.text('Fix 0'), findsNothing);
    expect(find.text('Fix 2'), findsNothing);
    expect(find.text('Fix 3'), findsOneWidget);
    expect(find.text('Fix 4'), findsOneWidget);

    await tester.tap(find.text('Fix 3'));
    expect(pressed, 1);
  });

  testWidgets('turns amber while more than one item is missing', (tester) async {
    await pumpOnPage(tester, VaultHealthCard(items: _items(3)));
    final palette = tester.element(find.byType(VaultHealthCard)).palette;
    Color? statusColour(String id) => tester
        .widget<AnimatedDefaultTextStyle>(find.ancestor(of: find.text(t(id)), matching: find.byType(AnimatedDefaultTextStyle)).first)
        .style
        .color;

    expect(statusColour('settings.health.attention'), palette.warning);

    await pumpOnPage(tester, VaultHealthCard(items: _items(4)));
    expect(statusColour('settings.health.good'), palette.text);
  });

  testWidgets('tells screen readers when the status changes', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpOnPage(tester, VaultHealthCard(items: _items(5)));

    expect(tester.getSemantics(find.text(t('settings.health.excellent'))), isSemantics(isLiveRegion: true));
    expect(tester.getSemantics(find.text(t('settings.health.label').toUpperCase())), isSemantics(isHeader: true));
    semantics.dispose();
  });
}
