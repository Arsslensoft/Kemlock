import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

void main() {
  group('PageTitle', () {
    testWidgets('shows the title as a heading, with the count, the trailing control and the subtitle', (tester) async {
      await pumpOnPage(
        tester,
        PageTitle(
          title: 'Codes',
          count: 12,
          trailing: IconButton(onPressed: () {}, icon: const Icon(Icons.add_rounded)),
          subtitle: 'All your accounts',
        ),
      );
      expect(find.textContaining('Codes'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.text('All your accounts'), findsOneWidget);
      expect(tester.getSemantics(find.textContaining('Codes')), isSemantics(isHeader: true));
    });

    testWidgets('leaves the count out when there is none', (tester) async {
      await pumpOnPage(tester, const PageTitle(title: 'Backup'));
      expect(find.byType(WidgetSpan), findsNothing);
      expect(find.text('Backup'), findsOneWidget);
    });
  });

  group('ScreenHeader', () {
    testWidgets('names the back button for screen readers and goes back on a tap', (tester) async {
      var back = 0;
      await pumpOnPage(tester, ScreenHeader(title: 'About', onBack: () => back++, backLabel: 'Back'));
      expect(find.bySemanticsLabel('Back'), findsOneWidget);
      expect(tester.getSemantics(find.text('About')), isSemantics(label: 'About', isHeader: true));

      await tester.tap(find.bySemanticsLabel('Back'));
      expect(back, 1);
    });
  });

  group('Group', () {
    testWidgets('puts its label in capitals over the card', (tester) async {
      await pumpOnPage(
        tester,
        const Group(
          label: 'Security',
          children: [GroupRow(first: true, primary: 'Auto-lock')],
        ),
      );
      expect(find.text('SECURITY'), findsOneWidget);
      expect(tester.getSemantics(find.text('SECURITY')), isSemantics(isHeader: true));
      expect(find.byType(GroupCard), findsOneWidget);
    });
  });

  group('GroupRow', () {
    testWidgets('is a button with a chevron when it can be tapped', (tester) async {
      var taps = 0;
      await pumpOnPage(
        tester,
        GroupRow(icon: const Icon(Icons.timer_outlined), primary: 'Auto-lock', value: const Text('1 min'), onTap: () => taps++),
      );
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(find.text('1 min'), findsOneWidget);
      final row = tester.getSemantics(find.text('Auto-lock'));
      expect(row, isSemantics(isButton: true, hasTapAction: true));
      expect(row.label, allOf(contains('Auto-lock'), contains('1 min')));

      await tester.tap(find.text('Auto-lock'));
      expect(taps, 1);
    });

    testWidgets('shows its control instead of a chevron, and is not a button itself', (tester) async {
      var taps = 0;
      await pumpOnPage(
        tester,
        GroupRow(
          primary: 'Fingerprint',
          secondary: 'Instead of the password',
          control: Switch(value: true, onChanged: (_) {}),
          onTap: () => taps++,
        ),
      );
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Instead of the password'), findsOneWidget);
      expect(
        find
            .byType(InkWell)
            .evaluate()
            .where((e) => (e.widget as InkWell).onTap != null && e.findAncestorWidgetOfExactType<Switch>() == null),
        isEmpty,
      );
    });

    testWidgets('paints a dangerous row red', (tester) async {
      await pumpOnPage(
        tester,
        GroupRow(icon: const Icon(Icons.delete_outline_rounded), primary: 'Delete this vault', danger: true, onTap: () {}),
      );
      expect(tester.widget<Text>(find.text('Delete this vault')).style!.color, AppPalette.dark.error);
      expect(IconTheme.of(tester.element(find.byIcon(Icons.delete_outline_rounded))).color, AppPalette.dark.error);
    });

    testWidgets('draws a separator above itself unless it is first', (tester) async {
      Iterable<CustomPaint> separators() => tester
          .widgetList<CustomPaint>(find.descendant(of: find.byType(GroupRow), matching: find.byType(CustomPaint)))
          .where((p) => p.painter != null);

      await pumpOnPage(tester, const GroupRow(first: true, primary: 'First'));
      expect(separators(), isEmpty);
      await pumpOnPage(tester, const GroupRow(primary: 'Second'));
      expect(separators(), hasLength(1));
    });

    testWidgets('is at least 54 tall', (tester) async {
      await pumpOnPage(tester, const GroupRow(primary: 'Short'));
      expect(tester.getSize(find.byType(GroupRow)).height, greaterThanOrEqualTo(54));
    });

    BoxDecoration tile(WidgetTester tester) =>
        tester.widget<Container>(find.descendant(of: find.byType(GroupRow), matching: find.byType(Container)).first).decoration!
            as BoxDecoration;

    testWidgets('paints an accent tile in accentSoft and accentText with a standing glow, in each scheme', (tester) async {
      for (final brightness in Brightness.values) {
        final b = BmcTokens.of(brightness);
        await pumpOnPage(
          tester,
          reducedMotion: false,
          effects: EffectsMode.running,
          brightness: brightness,
          GroupRow(icon: const Icon(Icons.key_rounded), primary: 'Security key', accent: true, onTap: () {}),
        );
        expect(tile(tester), BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(10), boxShadow: StandingGlow.tile(b)));
        expect(IconTheme.of(tester.element(find.byIcon(Icons.key_rounded))).color, b.accentText);
        // A standing glow: nothing moves, with motion on.
        await tester.pump(const Duration(seconds: 1));
        expect(tester.hasRunningAnimations, isFalse);
      }
      expect(StandingGlow.tile(BmcTokens.dark).single.color.a, closeTo(0.22, 1e-6));
      expect(StandingGlow.tile(BmcTokens.dark).single.blurRadius, 12);
    });

    testWidgets('paints the tile of a plain row and of a dangerous one as before, with no glow', (tester) async {
      await pumpOnPage(tester, GroupRow(icon: const Icon(Icons.timer_outlined), primary: 'Auto-lock', onTap: () {}));
      expect(tile(tester), BoxDecoration(color: BmcTokens.dark.raised, borderRadius: BorderRadius.circular(10)));

      await pumpOnPage(
        tester,
        GroupRow(icon: const Icon(Icons.delete_outline_rounded), primary: 'Delete', danger: true, accent: true, onTap: () {}),
      );
      expect(tile(tester), BoxDecoration(color: BmcTokens.dark.dangerSoft, borderRadius: BorderRadius.circular(10)));
    });
  });

  group('AppSwitch', () {
    List<BoxShadow>? glow(WidgetTester tester) =>
        (tester.widget<DecoratedBox>(find.descendant(of: find.byType(AppSwitch), matching: find.byType(DecoratedBox)).first).decoration
                as BoxDecoration)
            .boxShadow;

    testWidgets('glows round its track while it is on, and not while it is off', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpOnPage(tester, brightness: brightness, AppSwitch(value: true, onChanged: (_) {}));
        expect(glow(tester), StandingGlow.toggle(BmcTokens.of(brightness)));
        // Round the track, which is 52 by 32 in the middle of the switch.
        final track = find.descendant(of: find.byType(AppSwitch), matching: find.byType(DecoratedBox)).first;
        expect(tester.getSize(track), const Size(52, 32));
        expect(tester.getCenter(track), tester.getCenter(find.byType(Switch)));

        await pumpOnPage(tester, brightness: brightness, AppSwitch(value: false, onChanged: (_) {}));
        expect(glow(tester), isNull);
      }
      expect(StandingGlow.toggle(BmcTokens.dark).single.color.a, closeTo(0.45, 1e-6));
      expect(StandingGlow.toggle(BmcTokens.dark).single.blurRadius, 14);
    });

    testWidgets('has no glow when it cannot be changed, and no ticker for the glow it has', (tester) async {
      await pumpOnPage(tester, const AppSwitch(value: true, onChanged: null));
      expect(glow(tester), isNull);

      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, AppSwitch(value: true, onChanged: (_) {}));
      await tester.pump(const Duration(seconds: 1));
      expect(glow(tester), isNotNull);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('is Material'
        's switch, the same size, and says and does what it did', (tester) async {
      await pumpOnPage(tester, Switch(value: true, onChanged: (_) {}));
      final plain = tester.getSize(find.byType(Switch));

      bool? changed;
      await pumpOnPage(tester, AppSwitch(value: true, onChanged: (value) => changed = value));
      expect(tester.getSize(find.byType(AppSwitch)), plain);
      expect(
        tester.getSemantics(find.byType(Switch)),
        isSemantics(hasToggledState: true, isToggled: true, hasTapAction: true, isEnabled: true),
      );
      await tester.tap(find.byType(AppSwitch));
      expect(changed, isFalse);
    });
  });

  group('EmptyState', () {
    testWidgets('shows the icon, title, body and action', (tester) async {
      var taps = 0;
      await pumpOnPage(
        tester,
        EmptyState(
          icon: const Icon(Icons.key_rounded),
          title: 'No accounts yet',
          body: 'Scan a QR code to add one.',
          action: FilledButton(onPressed: () => taps++, child: const Text('Add')),
        ),
      );
      expect(find.text('No accounts yet'), findsOneWidget);
      expect(find.text('Scan a QR code to add one.'), findsOneWidget);
      await tester.tap(find.text('Add'));
      expect(taps, 1);
      expect(IconTheme.of(tester.element(find.byIcon(Icons.key_rounded))).size, 28);
    });

    testWidgets('rises into place', (tester) async {
      await pumpOnPage(tester, const EmptyState(icon: Icon(Icons.key_rounded), title: 'Nothing'));
      expect(find.ancestor(of: find.text('Nothing'), matching: find.byType(Rise)), findsOneWidget);
    });
  });

  group('AccentTag', () {
    testWidgets('shows its label in capitals, as wide as the word', (tester) async {
      await pumpOnPage(tester, const AccentTag(label: 'v6'));
      expect(find.text('V6'), findsOneWidget);
      final size = tester.getSize(find.byType(AccentTag));
      expect(size.height, 20);
      expect(size.width, lessThan(100));
    });
  });

  group('SegmentedControl', () {
    Widget control(String value, ValueChanged<String> onChanged, {SegmentSemantics semantics = SegmentSemantics.radio}) =>
        SegmentedControl<String>(
          semanticLabel: 'Theme',
          semantics: semantics,
          value: value,
          onChanged: onChanged,
          options: const [
            SegmentOption(value: 'system', label: 'System'),
            SegmentOption(value: 'light', label: 'Light', icon: Icon(Icons.light_mode_outlined)),
            SegmentOption(value: 'dark', label: 'Dark'),
          ],
        );

    testWidgets('picks the tapped option', (tester) async {
      final picked = <String>[];
      await pumpOnPage(tester, control('system', picked.add));
      await tester.tap(find.text('Dark'));
      await tester.tap(find.text('Light'));
      expect(picked, ['dark', 'light']);
    });

    testWidgets('is a named radio group with the chosen option checked', (tester) async {
      await pumpOnPage(tester, control('light', (_) {}));
      expect(find.bySemanticsLabel('Theme'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Light')),
        isSemantics(label: 'Light', isInMutuallyExclusiveGroup: true, hasCheckedState: true, isChecked: true, hasTapAction: true),
      );
      expect(tester.getSemantics(find.text('Dark')), isSemantics(label: 'Dark', hasCheckedState: true, isChecked: false));
    });

    testWidgets('is a tab bar of tabs with the chosen one selected', (tester) async {
      await pumpOnPage(tester, control('dark', (_) {}, semantics: SegmentSemantics.tabs));
      expect(
        tester.getSemantics(find.text('Dark')),
        isSemantics(label: 'Dark', hasSelectedState: true, isSelected: true, hasTapAction: true),
      );
      expect(tester.getSemantics(find.text('System')), isSemantics(label: 'System', hasSelectedState: true, isSelected: false));
    });

    testWidgets('moves along with the arrow keys, wrapping round', (tester) async {
      final picked = <String>[];
      await pumpOnPage(tester, control('dark', picked.add));
      Focus.of(tester.element(find.text('Dark'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(picked, ['system', 'light']);
    });

    testWidgets('slides the thumb under the chosen option', (tester) async {
      await pumpOnPage(tester, SizedBox(width: 300, child: control('light', (_) {})));
      await tester.pumpAndSettle();
      final thumb = tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned));
      expect(thumb.left, closeTo((300 - 8) / 3, 0.01));
      expect(tester.getSize(find.byType(SegmentedControl<String>)).height, 44);
    });

    testWidgets('is 34 tall when small', (tester) async {
      await pumpOnPage(
        tester,
        SegmentedControl<String>(
          size: SegmentSize.small,
          semanticLabel: 'Language',
          value: 'en',
          onChanged: (_) {},
          options: const [
            SegmentOption(value: 'en', label: 'EN'),
            SegmentOption(value: 'fr', label: 'FR'),
          ],
        ),
      );
      expect(tester.getSize(find.byType(SegmentedControl<String>)).height, 34);
    });
  });

  group('AppAlert', () {
    testWidgets('tints each severity as the web app does', (tester) async {
      Color background(AlertSeverity severity) =>
          (tester.widget<Container>(find.descendant(of: find.byType(AppAlert), matching: find.byType(Container)).first).decoration!
                  as BoxDecoration)
              .color!;

      for (final (severity, tint, ink) in [
        (AlertSeverity.error, BmcTokens.dark.dangerSoft, AppPalette.dark.error),
        (AlertSeverity.warning, BmcTokens.dark.warnSoft, AppPalette.dark.warning),
        (AlertSeverity.info, BmcTokens.dark.accentSoft, BmcTokens.dark.accentText),
        (AlertSeverity.success, BmcTokens.dark.accentSoft, BmcTokens.dark.accentText),
      ]) {
        await pumpOnPage(tester, AppAlert(severity: severity, child: const Text('Message')));
        expect(background(severity), tint, reason: severity.name);
        expect(DefaultTextStyle.of(tester.element(find.text('Message'))).style.color, ink, reason: severity.name);
      }
    });

    testWidgets('closes with a named close button', (tester) async {
      var closed = 0;
      await pumpOnPage(
        tester,
        AppAlert(severity: AlertSeverity.warning, onClose: () => closed++, closeLabel: 'Close', child: const Text('Skipped 3')),
      );
      await tester.tap(find.bySemanticsLabel('Close'));
      expect(closed, 1);
    });

    testWidgets('takes another icon', (tester) async {
      await pumpOnPage(tester, const AppAlert(severity: AlertSeverity.warning, icon: Icon(Icons.lock_open_rounded), child: Text('Plain')));
      expect(find.byIcon(Icons.lock_open_rounded), findsOneWidget);
      expect(find.byIcon(Icons.report_problem_outlined), findsNothing);
    });

    Container box(WidgetTester tester) =>
        tester.widget<Container>(find.descendant(of: find.byType(AppAlert), matching: find.byType(Container)).first);

    testWidgets('glows when it is an information alert that is asked to, with an accent line inside its edge', (tester) async {
      await pumpOnPage(tester, const AppAlert(severity: AlertSeverity.info, glow: true, child: Text('Signed by Ada')));
      final glow = tester.widget<Glow>(find.descendant(of: find.byType(AppAlert), matching: find.byType(Glow)));
      expect(glow.period, const Duration(milliseconds: 3400));
      expect(glow.borderRadius, BorderRadius.circular(14));
      expect(
        box(tester).foregroundDecoration,
        BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BmcTokens.dark.accentLine),
        ),
      );
      // The line is painted over the box: the message is where it is without it.
      final withGlow = tester.getRect(find.text('Signed by Ada'));
      await pumpOnPage(tester, const AppAlert(severity: AlertSeverity.info, child: Text('Signed by Ada')));
      expect(tester.getRect(find.text('Signed by Ada')), withGlow);
    });

    testWidgets('never glows as a warning, an error or a success, even when asked to', (tester) async {
      for (final severity in [AlertSeverity.warning, AlertSeverity.error, AlertSeverity.success]) {
        await pumpOnPage(tester, AppAlert(severity: severity, glow: true, child: const Text('Message')));
        expect(find.byType(Glow), findsNothing, reason: severity.name);
        expect(box(tester).foregroundDecoration, isNull, reason: severity.name);
      }
    });

    testWidgets('paints as it did before when it is not asked to glow', (tester) async {
      for (final (severity, tint) in [
        (AlertSeverity.error, BmcTokens.dark.dangerSoft),
        (AlertSeverity.warning, BmcTokens.dark.warnSoft),
        (AlertSeverity.info, BmcTokens.dark.accentSoft),
        (AlertSeverity.success, BmcTokens.dark.accentSoft),
      ]) {
        await pumpOnPage(tester, AppAlert(severity: severity, child: const Text('Message')));
        expect(find.byType(Glow), findsNothing, reason: severity.name);
        expect(
          box(tester).decoration,
          BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
          reason: severity.name,
        );
        expect(box(tester).foregroundDecoration, isNull, reason: severity.name);
        expect(
          tester.renderObject(find.descendant(of: find.byType(AppAlert), matching: find.byType(DecoratedBox)).first),
          isA<RenderDecoratedBox>().having(
            (render) => render.decoration,
            'decoration',
            BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
          ),
          reason: severity.name,
        );
      }
    });

    testWidgets('says the same to a screen reader with its glow as without', (tester) async {
      await pumpOnPage(tester, const AppAlert(severity: AlertSeverity.info, glow: true, child: Text('Signed by Ada')));
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['Signed by Ada']);
    });
  });

  group('ProgressBar', () {
    Finder fill() => find.descendant(of: find.byType(FractionallySizedBox), matching: find.byType(DecoratedBox));
    BoxDecoration decoration(WidgetTester tester, Finder finder) => tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;

    Widget bar(num value, num total) => SizedBox(
      width: 300,
      child: ProgressBar(value: value, total: total, semanticsLabel: '$value of $total passkeys used'),
    );

    testWidgets('is a 6-high rounded track in raised, with a filled part in the accent and the glow', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpOnPage(tester, brightness: brightness, bar(7, 100));
        expect(tester.getSize(find.byType(ProgressBar)), const Size(300, 6));
        final track = find.descendant(of: find.byType(ProgressBar), matching: find.byType(DecoratedBox)).first;
        expect(decoration(tester, track), BoxDecoration(color: BmcTokens.of(brightness).raised, borderRadius: BorderRadius.circular(3)));
        expect(
          decoration(tester, fill()),
          BoxDecoration(
            color: AppPalette.of(brightness).primary,
            borderRadius: BorderRadius.circular(3),
            boxShadow: StandingGlow.bar(BmcTokens.of(brightness)),
          ),
        );
      }
      expect(StandingGlow.bar(BmcTokens.dark).single.color.a, closeTo(0.7, 1e-6));
      expect(StandingGlow.bar(BmcTokens.dark).single.blurRadius, 10);
    });

    testWidgets('grows from empty to seven hundredths of its width for 7 of 100, over .9 seconds after .5', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, effects: EffectsMode.running, bar(7, 100));
      expect(tester.getSize(fill()).width, 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getSize(fill()).width, 0, reason: 'still waiting');
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.getSize(fill()).width, closeTo(21 * Ease.roll.transform(0.5), 1e-6));
      await tester.pumpAndSettle();
      expect(tester.getSize(fill()).width, closeTo(21, 1e-9));
      expect(tester.getTopLeft(fill()), tester.getTopLeft(find.byType(ProgressBar)));
      expect(tester.getSize(find.byType(ProgressBar)), const Size(300, 6));
    });

    testWidgets('stops at the bar'
        's end when it is full, and clamps a value below 0 or above the total', (tester) async {
      for (final (value, width) in [(100, 300.0), (250, 300.0), (-3, 0.0), (0, 0.0), (50, 150.0)]) {
        await pumpOnPage(tester, bar(value, 100));
        expect(tester.getSize(fill()).width, width, reason: '$value of 100');
        expect(tester.getRect(find.byType(ProgressBar)).expandToInclude(tester.getRect(fill())), tester.getRect(find.byType(ProgressBar)));
      }
      expect(ProgressBar.fractionOf(7, 100), 0.07);
      expect(ProgressBar.fractionOf(250, 100), 1);
      expect(ProgressBar.fractionOf(-3, 100), 0);
    });

    testWidgets('draws an empty bar for a total of 0, with no glow, and divides nothing by it', (tester) async {
      for (final value in [0, 7]) {
        await pumpOnPage(tester, bar(value, 0));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(fill()).width, 0);
        expect(decoration(tester, fill()).boxShadow, isNull);
      }
      expect(ProgressBar.fractionOf(7, 0), 0);
      expect(ProgressBar.fractionOf(0, 0), 0);
    });

    testWidgets('gives a screen reader its label and nothing else', (tester) async {
      await pumpOnPage(tester, bar(7, 100));
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['7 of 100 passkeys used']);
      expect(find.bySemanticsLabel('7 of 100 passkeys used'), findsOneWidget);
    });

    testWidgets('shows its value at once under reduced motion, and under the pin', (tester) async {
      await pumpOnPage(tester, effects: EffectsMode.running, bar(7, 100));
      expect(tester.getSize(fill()).width, closeTo(21, 1e-9));
      expect(tester.hasRunningAnimations, isFalse);

      await pumpOnPage(tester, reducedMotion: false, bar(7, 100));
      expect(tester.getSize(fill()).width, closeTo(21, 1e-9));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('fills from the right where text runs right to left', (tester) async {
      await pumpOnPage(tester, Directionality(textDirection: TextDirection.rtl, child: bar(7, 100)));
      expect(tester.getSize(fill()).width, closeTo(21, 1e-9));
      expect(tester.getTopRight(fill()), tester.getTopRight(find.byType(ProgressBar)));
    });
  });
}
