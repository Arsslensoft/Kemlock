import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

/// The tab bar on [active], which a tap on a tab changes, as the shell does.
class _Bar extends StatefulWidget {
  const _Bar({this.active = AppTab.codes, this.onAdd});

  final AppTab active;
  final VoidCallback? onAdd;

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> {
  late AppTab _active = widget.active;

  @override
  Widget build(BuildContext context) =>
      AppTabBar(active: _active, onSelect: (tab) => setState(() => _active = tab), addLabel: 'Add account', onAdd: widget.onAdd ?? () {});
}

void main() {
  Finder glow() => find.descendant(of: find.byType(AppTabBar), matching: find.byType(Glow));
  Finder tab(AppTab tab) => find.descendant(of: find.byType(AppTabBar), matching: find.bySemanticsLabel(t(tab.labelId)));

  testWidgets('glows round the active tab only, and the glow follows a tab change', (tester) async {
    await pumpOnPage(tester, const _Bar());
    expect(glow(), findsOneWidget);
    expect(tester.widget<Glow>(glow()).borderRadius, BorderRadius.circular(25));
    expect(tester.getRect(glow()).contains(tester.getCenter(find.text(t('nav.codes')))), isTrue);
    for (final other in [AppTab.backup, AppTab.vault, AppTab.settings]) {
      expect(tester.getRect(glow()).contains(tester.getCenter(find.text(t(other.labelId)))), isFalse, reason: other.name);
    }

    await tester.tap(find.text(t('nav.vault')));
    await tester.pumpAndSettle();
    expect(glow(), findsOneWidget);
    expect(tester.getRect(glow()).contains(tester.getCenter(find.text(t('nav.vault')))), isTrue);
    expect(tester.getRect(glow()).contains(tester.getCenter(find.text(t('nav.codes')))), isFalse);
  });

  testWidgets('gives the add button one halo and the glow token'
      's shadow, in each scheme', (tester) async {
    for (final brightness in Brightness.values) {
      await pumpOnPage(tester, brightness: brightness, const _Bar());
      final halo = find.descendant(of: find.byType(AppTabBar), matching: find.byType(Halo));
      expect(halo, findsOneWidget);
      expect(tester.widget<Halo>(halo).period, const Duration(milliseconds: 2800));
      // The ring starts on the button's own edge.
      final button = find.ancestor(of: find.byIcon(Icons.add_rounded), matching: find.byType(Container)).first;
      expect(tester.getRect(halo), tester.getRect(button));
      expect((tester.widget<Container>(button).decoration! as BoxDecoration).boxShadow, StandingGlow.add(BmcTokens.of(brightness)));
      final ring = tester.widget<DecoratedBox>(find.descendant(of: halo, matching: find.byType(DecoratedBox))).decoration as BoxDecoration;
      expect(ring.border, Border.all(color: AppPalette.of(brightness).primary.withValues(alpha: 0.7)));
    }
  });

  testWidgets('runs two loops, the glow and the halo, which reduced motion holds still', (tester) async {
    await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, const _Bar());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);
    final scope = tester.state<EffectsScopeState>(find.byType(EffectsScope));
    expect(scope.liveOn(ModalRoute.of(tester.element(find.byType(AppTabBar)))), 2);
    await tester.pumpWidget(const SizedBox());

    await pumpOnPage(tester, effects: EffectsMode.running, const _Bar());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('keeps each tab'
      's label and selected state, the bar'
      's name and the add button'
      's', (tester) async {
    var adds = 0;
    await pumpOnPage(tester, _Bar(active: AppTab.backup, onAdd: () => adds++));
    for (final each in AppTab.values) {
      expect(
        tester.getSemantics(tab(each)),
        isSemantics(label: t(each.labelId), isButton: true, isSelected: each == AppTab.backup),
        reason: each.name,
      );
    }
    expect(find.bySemanticsLabel(t('nav.label')), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('Add account')), isSemantics(label: 'Add account', isButton: true));
    // The bar, its four tabs and the add button: neither the glow nor the halo is a stop.
    expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), [
      t('nav.label'),
      for (final each in AppTab.values) t(each.labelId),
      'Add account',
    ]);

    await tester.tap(find.byIcon(Icons.add_rounded));
    expect(adds, 1);
  });
}
