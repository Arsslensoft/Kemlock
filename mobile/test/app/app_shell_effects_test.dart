import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/app_shell.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/features/settings/settings_page.dart';
import 'package:kemlock/ui/ui.dart';

import '../fakes/fake_scanner.dart';
import '../helpers/app_harness.dart';
import '../helpers/test_app.dart';

/// The loops under [of], in the order they are built.
List<LoopState> _loops(WidgetTester tester, Finder of) => [
  for (final element
      in find.descendant(of: of, matching: find.byElementPredicate((e) => e is StatefulElement && e.state is LoopState)).evaluate())
    (element as StatefulElement).state as LoopState,
];

/// Which of [loops] move over the next 300ms.
Future<List<bool>> _moving(WidgetTester tester, List<LoopState> loops) async {
  final before = [for (final loop in loops) loop.phase.value];
  await tester.pump(const Duration(milliseconds: 300));
  return [for (var i = 0; i < loops.length; i++) loops[i].phase.value != before[i]];
}

Future<TestApp> _open(WidgetTester tester, {EffectsMode effects = EffectsMode.pinned}) async {
  final app = TestApp();
  await tester.runAsync(() => app.createVault('pw'));
  // A fake camera behind the QR viewfinder the Add account sheet opens on.
  await app.pump(tester, overrides: [FakeScanner().asOverride], effects: effects);
  await app.unlock(tester, 'pw');
  return app;
}

void main() {
  testWidgets('every tab has two ambient lights under its page, the active tab'
      's glow and the add button'
      's halo', (tester) async {
    await _open(tester);
    for (final tab in AppTab.values) {
      await tester.tap(find.descendant(of: find.byType(AppTabBar), matching: find.text(t(tab.labelId))));
      await tester.pumpAndSettle();
      final light = find.descendant(of: find.byType(AppShell), matching: find.byType(AmbientLight));
      expect(light, findsOneWidget, reason: tab.name);
      expect(tester.widget<AmbientLight>(light).lights, 2, reason: tab.name);
      expect(tester.getSize(light), tester.getSize(find.byType(AppShell)), reason: tab.name);
      expect(
        find.descendant(of: find.byType(AppTabBar), matching: find.byType(Glow)),
        findsOneWidget,
        reason: tab.name,
      );
      expect(
        find.descendant(of: find.byType(AppTabBar), matching: find.byType(Halo)),
        findsOneWidget,
        reason: tab.name,
      );
    }
  });

  testWidgets('the page scrolls over lights that stay put', (tester) async {
    await _open(tester);
    await tester.tap(find.descendant(of: find.byType(AppTabBar), matching: find.text(t('nav.settings'))));
    await tester.pumpAndSettle();
    final light = find.descendant(of: find.byType(AppShell), matching: find.byType(AmbientLight));
    final lightBefore = tester.getRect(light);
    final title = find.descendant(of: find.byType(SettingsPage), matching: find.byType(PageTitle));
    final titleBefore = tester.getTopLeft(title.first);

    await tester.drag(find.byType(SettingsPage), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(tester.getRect(light), lightBefore);
    expect(tester.getTopLeft(title.first).dy, lessThan(titleBefore.dy));
    // The lights are painted before the page, which lies over them.
    final shell = tester.element(find.byType(AppShell));
    final order = <Type>[];
    void visit(Element element) {
      if (element.widget is AmbientLight || element.widget is SettingsPage) order.add(element.widget.runtimeType);
      element.visitChildren(visit);
    }

    shell.visitChildren(visit);
    expect(order, [AmbientLight, SettingsPage]);
  });

  testWidgets('a sheet opened over a tab stops the tab'
      's lights, glow and halo and runs its own light', (tester) async {
    await _open(tester, effects: EffectsMode.running);
    // The harness reduces motion to settle the unlock; from here the phone asks for none of that.
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();
    await tester.pump();

    final shell = _loops(tester, find.byType(AppShell));
    // Two lights, the tab glow and the halo.
    expect(shell, hasLength(4));
    expect(await _moving(tester, shell), everyElement(isTrue));
    final scope = tester.state<EffectsScopeState>(find.byType(EffectsScope).last);
    final route = ModalRoute.of(tester.element(find.byType(AppShell)));
    expect(scope.liveOn(route), 4);

    await tester.tap(find.descendant(of: find.byType(AppTabBar), matching: find.byIcon(Icons.add_rounded)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(await _moving(tester, shell), everyElement(isFalse));
    expect(scope.liveOn(route), 0);
    final sheet = _loops(
      tester,
      find.byType(AppBottomSheet),
    ).where((loop) => loop.context.findAncestorWidgetOfExactType<AmbientLight>() != null).toList();
    expect(sheet, hasLength(1));
    expect(await _moving(tester, sheet), [isTrue]);

    Navigator.of(tester.element(find.byType(AppBottomSheet)), rootNavigator: true).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(await _moving(tester, shell), everyElement(isTrue));
    await tester.pumpWidget(const SizedBox());
  });
}
