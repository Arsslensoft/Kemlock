import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

/// The digits the strips of a [CodeDigits] rest on: the digit drawn with no
/// offset in each window, in order.
List<String> _restingDigits(WidgetTester tester) => [
  for (final t in tester.widgetList<FractionalTranslation>(_strips))
    if (t.translation == Offset.zero) (t.child! as Text).data!,
];

/// The digit nearest to showing in each window of the [CodeDigits] on
/// screen, as a number.
List<int> _nearestDigits(WidgetTester tester) => [
  for (final strip in tester.elementList(find.descendant(of: find.byType(CodeDigits), matching: find.byType(Stack))))
    (tester
            .widgetList<FractionalTranslation>(
              find.descendant(of: find.byElementPredicate((e) => e == strip), matching: find.byType(FractionalTranslation)),
            )
            .toList()
          ..sort((a, b) => a.translation.dy.abs().compareTo(b.translation.dy.abs())))
        .map((t) => int.parse((t.child! as Text).data!))
        .first,
];

/// The digit windows of the [CodeDigits] on screen.
final _strips = find.descendant(of: find.byType(CodeDigits), matching: find.byType(FractionalTranslation));

/// Pumps [build] with a value that [notifier] can change without
/// rebuilding the page around it.
Future<void> _pumpWith<T>(WidgetTester tester, ValueNotifier<T> notifier, Widget Function(T value) build) => pumpOnPage(
  tester,
  reducedMotion: false,
  ValueListenableBuilder<T>(valueListenable: notifier, builder: (context, value, _) => build(value)),
);

/// The painter of the ring of the only [CountdownRing].
CountdownRingPainter _ringPainter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.descendant(of: find.byType(CountdownRing), matching: find.byType(CustomPaint))).painter!
        as CountdownRingPainter;

void main() {
  group('CodeDigits', () {
    test('groups 6- and 8-digit codes in halves for screen readers', () {
      expect(CodeDigits.grouped('492018'), '492 018');
      expect(CodeDigits.grouped('12345678'), '1234 5678');
      expect(CodeDigits.grouped('K7GR2'), 'K7GR2');
      expect(CodeDigits.grouped('1234567'), '1234567');
    });

    testWidgets('reads as the grouped code', (tester) async {
      await pumpOnPage(tester, const CodeDigits(code: '492018'));
      expect(find.bySemanticsLabel('492 018'), findsOneWidget);
    });

    testWidgets('rests each strip on its digit', (tester) async {
      await pumpOnPage(tester, const CodeDigits(code: '492018'));
      await tester.pumpAndSettle();
      expect(_restingDigits(tester), ['4', '9', '2', '0', '1', '8']);
    });

    testWidgets('rolls up from 0 on first build, the later places after the earlier', (tester) async {
      await pumpOnPage(tester, reducedMotion: false, const CodeDigits(code: '999999'));
      expect(_restingDigits(tester), ['0', '0', '0', '0', '0', '0']);

      await tester.pump(const Duration(milliseconds: 300));
      final digits = _nearestDigits(tester);
      // The first place is further along than the last, which started 225ms later.
      expect(digits.first, greaterThan(digits.last));
      expect(digits.first, lessThan(9));

      await tester.pumpAndSettle();
      expect(_restingDigits(tester), ['9', '9', '9', '9', '9', '9']);
    });

    testWidgets('rolls to a new code from where it is', (tester) async {
      final code = ValueNotifier('111111');
      addTearDown(code.dispose);
      await _pumpWith(tester, code, (value) => CodeDigits(code: value));
      await tester.pumpAndSettle();

      code.value = '222222';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_restingDigits(tester), isEmpty, reason: 'every strip is on its way from 1 to 2');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('222 222'), findsOneWidget);
      expect(_restingDigits(tester), ['2', '2', '2', '2', '2', '2']);
    });

    testWidgets('keeps letters still', (tester) async {
      await pumpOnPage(tester, const CodeDigits(code: 'K7GR2'));
      await tester.pumpAndSettle();
      expect(find.text('K'), findsOneWidget);
      expect(find.text('G'), findsOneWidget);
      expect(find.text('R'), findsOneWidget);
      expect(_restingDigits(tester), ['7', '2']);
    });

    testWidgets('sets the code in Geist Mono at the given size and colour', (tester) async {
      await pumpOnPage(
        tester,
        const CodeDigits(
          code: '492018',
          style: TextStyle(fontSize: 52, color: Color(0xFFFFA24C)),
        ),
      );
      await tester.pumpAndSettle();
      final digit = tester.widget<Text>(find.text('4').last);
      expect(digit.style!.fontFamily, fontMono);
      expect(digit.style!.fontSize, 52);
      expect(digit.style!.color, const Color(0xFFFFA24C));
    });
  });

  group('CountdownRing', () {
    testWidgets('shows the seconds left with a label', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 17, period: 30, label: true));
      expect(find.text('17'), findsOneWidget);
    });

    testWidgets('shows no number without one', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 17, period: 30));
      expect(find.text('17'), findsNothing);
    });

    testWidgets('is Azure, then the warning colour from urgentAt', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 6, period: 30, label: true));
      expect(tester.widget<Text>(find.text('6')).style!.color, BmcTokens.dark.accentText);

      await pumpOnPage(tester, const CountdownRing(remaining: 5, period: 30, label: true));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('5')).style!.color, AppPalette.dark.warning);
    });

    testWidgets('draws the arc where it will be at the next tick', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 16, period: 30));
      await tester.pumpAndSettle();
      // (16 - 1) / 30 of the ring is left.
      expect(_ringPainter(tester).fraction, closeTo(0.5, 1e-9));
    });

    testWidgets('drains linearly over the next second', (tester) async {
      final remaining = ValueNotifier(16);
      addTearDown(remaining.dispose);
      await _pumpWith(tester, remaining, (value) => CountdownRing(remaining: value, period: 30));
      await tester.pumpAndSettle();
      remaining.value = 15;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_ringPainter(tester).fraction, closeTo((15 + 14) / 2 / 30, 0.005));
      await tester.pumpAndSettle();
    });

    testWidgets('is the given size and hidden from screen readers but for its label', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 9, period: 30, size: 18, stroke: 2));
      expect(tester.getSize(find.byType(CountdownRing)), const Size(18, 18));
      expect(find.descendant(of: find.byType(CountdownRing), matching: find.byType(ExcludeSemantics)), findsOneWidget);
    });

    testWidgets('glows under its arc in the arc'
        's own colour, which is the warning colour from urgentAt', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 6, period: 30));
      expect(_ringPainter(tester).glow, BmcTokens.dark.accentText.withValues(alpha: 0.8));
      expect(CountdownRingPainter.glowBlur, 3);
      // The track, the glow and the arc over it.
      final ring = find.descendant(of: find.byType(CountdownRing), matching: find.byType(CustomPaint));
      expect(
        ring,
        paints
          ..circle(color: BmcTokens.dark.line2)
          ..arc(color: BmcTokens.dark.accentText.withValues(alpha: 0.8))
          ..arc(color: BmcTokens.dark.accentText),
      );

      await pumpOnPage(tester, const CountdownRing(remaining: 5, period: 30));
      await tester.pumpAndSettle();
      expect(_ringPainter(tester).color, AppPalette.dark.warning);
      expect(_ringPainter(tester).glow, AppPalette.dark.warning.withValues(alpha: 0.8));
      expect(
        ring,
        paints
          ..circle()
          ..arc(color: AppPalette.dark.warning.withValues(alpha: 0.8))
          ..arc(color: AppPalette.dark.warning),
      );
    });

    testWidgets('draws no glow once nothing is left', (tester) async {
      await pumpOnPage(tester, const CountdownRing(remaining: 1, period: 30));
      await tester.pumpAndSettle();
      final ring = find.descendant(of: find.byType(CountdownRing), matching: find.byType(CustomPaint));
      expect(ring, paints..circle());
      expect(ring, isNot(paints..arc()));
    });

    test('repaints only when the fraction, the colour, the stroke or the track changes', () {
      const painter = CountdownRingPainter(fraction: 0.5, stroke: 3, track: Color(0xFF111111), color: Color(0xFF5AA9FF));
      const same = CountdownRingPainter(fraction: 0.5, stroke: 3, track: Color(0xFF111111), color: Color(0xFF5AA9FF));
      expect(same.shouldRepaint(painter), isFalse);
      expect(
        const CountdownRingPainter(fraction: 0.4, stroke: 3, track: Color(0xFF111111), color: Color(0xFF5AA9FF)).shouldRepaint(painter),
        isTrue,
      );
      expect(
        const CountdownRingPainter(fraction: 0.5, stroke: 3, track: Color(0xFF111111), color: Color(0xFFFFA24C)).shouldRepaint(painter),
        isTrue,
      );
      expect(
        const CountdownRingPainter(fraction: 0.5, stroke: 2, track: Color(0xFF111111), color: Color(0xFF5AA9FF)).shouldRepaint(painter),
        isTrue,
      );
      expect(
        const CountdownRingPainter(fraction: 0.5, stroke: 3, track: Color(0xFF222222), color: Color(0xFF5AA9FF)).shouldRepaint(painter),
        isTrue,
      );
    });

    testWidgets('keeps its size, its label and its semantics with the glow, and runs no loop for it', (tester) async {
      await pumpOnPage(
        tester,
        reducedMotion: false,
        effects: EffectsMode.running,
        const CountdownRing(remaining: 17, period: 30, label: true),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(CountdownRing)), const Size(44, 44));
      expect(tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label), ['17']);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('VaultDial', () {
    testWidgets('settles under reduced motion and is hidden from screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpOnPage(
        tester,
        const VaultDial(
          state: VaultDialState.idle,
          icon: Icon(Icons.lock_rounded, semanticLabel: 'Locked'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Locked'), findsNothing);
      handle.dispose();
    });

    testWidgets('is at most 78% of the screen wide', (tester) async {
      await pumpOnPage(tester, const VaultDial(state: VaultDialState.idle, icon: Icon(Icons.lock_rounded), size: 2000));
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(tester.getSize(find.byType(VaultDial)).width, closeTo(screen.width * 0.78, 0.01));
    });

    testWidgets('lights the inner rings and the emblem edge while busy', (tester) async {
      await pumpOnPage(tester, const VaultDial(state: VaultDialState.busy, icon: Icon(Icons.lock_rounded)));
      await tester.pumpAndSettle();
      final emblem = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      final decoration = emblem.decoration! as BoxDecoration;
      expect((decoration.border! as Border).top.color, BmcTokens.dark.accentLine);
      expect(decoration.color, AppPalette.dark.paper);
    });

    testWidgets('blooms the rings away and pops the icon in an Azure emblem when open', (tester) async {
      await pumpOnPage(tester, const VaultDial(state: VaultDialState.open, icon: Icon(Icons.check_rounded)));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);
      expect(find.ancestor(of: find.byIcon(Icons.check_rounded), matching: find.byType(PopIn)), findsOneWidget);
      final decoration = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).decoration! as BoxDecoration;
      expect(decoration.color, AppPalette.dark.primary);
    });
  });

  group('BrandMark', () {
    String assetOf(WidgetTester tester, Finder f) =>
        (tester.widget<SvgPicture>(find.descendant(of: f, matching: find.byType(SvgPicture))).bytesLoader as SvgAssetLoader).assetName;

    testWidgets('is the keyhole K icon of the given size, hidden from screen readers', (tester) async {
      await pumpOnPage(tester, const BrandMark(size: 64));
      expect(tester.getSize(find.byType(BrandMark)), const Size(64, 64));
      expect(assetOf(tester, find.byType(BrandMark)), BrandMark.asset);
      expect(find.descendant(of: find.byType(BrandMark), matching: find.byType(ExcludeSemantics)), findsOneWidget);
    });

    testWidgets('uses the plainer small icon at 48 and under', (tester) async {
      await pumpOnPage(tester, const BrandMark(size: 48));
      expect(assetOf(tester, find.byType(BrandMark)), BrandMark.smallAsset);
    });
  });

  group('BrandWordmark', () {
    testWidgets('is steel on the dark theme and says its label to screen readers', (tester) async {
      await pumpOnPage(tester, const BrandWordmark(label: 'Kemlock'));
      final svg = find.byType(SvgPicture);
      expect(((tester.widget<SvgPicture>(svg)).bytesLoader as SvgAssetLoader).assetName, BrandWordmark.darkAsset);
      expect(tester.widget<SvgPicture>(svg).semanticsLabel, 'Kemlock');
    });

    testWidgets('is gunmetal on the light theme', (tester) async {
      await pumpOnPage(tester, const BrandWordmark(label: 'Kemlock'), brightness: Brightness.light);
      expect(((tester.widget<SvgPicture>(find.byType(SvgPicture))).bytesLoader as SvgAssetLoader).assetName, BrandWordmark.lightAsset);
    });
  });
}
