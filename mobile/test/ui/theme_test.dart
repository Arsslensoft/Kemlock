import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/test_app.dart';

void main() {
  group('tokens', () {
    test('carry the colours of theme.ts for each scheme', () {
      expect(AppPalette.dark.primary, const Color(0xFF5AA9FF));
      expect(AppPalette.dark.onPrimary, const Color(0xFF051220));
      expect(AppPalette.dark.paper, const Color(0xFF131417));
      expect(AppPalette.light.primary, const Color(0xFF1F6FEB));
      expect(AppPalette.light.warning, const Color(0xFF9A4A06));
      expect(AppPalette.light.error, const Color(0xFFB42318));
      expect(BmcTokens.dark.raised, const Color(0xFF1C1D21));
      expect(BmcTokens.dark.accentText, const Color(0xFF7DBBFF));
      expect(BmcTokens.light.faint, const Color(0xFF63686F));
      expect(BmcTokens.light.thumb, const Color(0xFFFFFFFF));
    });

    test('keep the rgba alphas exactly', () {
      expect(AppPalette.dark.divider.a, closeTo(0.07, 1e-9));
      expect(AppPalette.light.hover.a, closeTo(0.04, 1e-9));
      expect(BmcTokens.dark.scrim.a, closeTo(0.55, 1e-9));
      expect(BmcTokens.light.scrim.a, closeTo(0.28, 1e-9));
      expect(BmcTokens.dark.accentSoft.a, closeTo(0.14, 1e-9));
      expect(BmcTokens.light.glass.a, closeTo(0.78, 1e-9));
    });

    test('turn the CSS shadows into box shadows', () {
      final dark = BmcTokens.dark.shadow.single;
      expect(dark.offset, const Offset(0, 18));
      expect(dark.blurRadius, 40);
      expect(dark.color.a, closeTo(0.45, 1e-9));
      final light = BmcTokens.light.shadow.single;
      expect(light.offset, const Offset(0, 14));
      expect(light.blurRadius, 36);
    });

    test('give the ground colour of each scheme for native chrome', () {
      expect(Ground.of(Brightness.dark), const Color(0xFF0A0B0D));
      expect(Ground.of(Brightness.light), const Color(0xFFF4F4F1));
      expect(AppPalette.light.background, Ground.light);
    });

    test('blend between schemes', () {
      final halfway = AppPalette.dark.lerp(AppPalette.light, 0.5);
      expect(halfway.primary, Color.lerp(AppPalette.dark.primary, AppPalette.light.primary, 0.5));
      final tokens = BmcTokens.dark.lerp(BmcTokens.light, 1);
      expect(tokens.raised, BmcTokens.light.raised);
      expect(tokens.shadow.single.blurRadius, 36);
    });

    test('carry the colours of the effects: those of kemlock.css when dark, and the design'
        's when light', () {
      const dark = BmcTokens.dark;
      expect(dark.glow, const Color.fromRGBO(90, 169, 255, 0.38));
      expect(dark.ambient, const Color.fromRGBO(90, 169, 255, 0.2));
      expect(dark.ambient2, const Color.fromRGBO(125, 187, 255, 0.1));
      expect(dark.sheen, const Color.fromRGBO(255, 255, 255, 0.5));
      expect(dark.neonHot, const Color(0xFFD6ECFF));

      const light = BmcTokens.light;
      expect(light.glow, const Color.fromRGBO(31, 111, 235, 0.26));
      expect(light.ambient, const Color.fromRGBO(31, 111, 235, 0.09));
      expect(light.ambient2, const Color.fromRGBO(31, 111, 235, 0.05));
      expect(light.sheen, const Color.fromRGBO(255, 255, 255, 0.45));
      expect(light.neonHot, const Color(0xFF5AA9FF));
    });

    test('blend the colours of the effects between schemes, from one end to the other', () {
      List<Color> effects(BmcTokens b) => [b.glow, b.ambient, b.ambient2, b.sheen, b.neonHot];
      expect(effects(BmcTokens.dark.lerp(BmcTokens.light, 0)), effects(BmcTokens.dark));
      expect(effects(BmcTokens.dark.lerp(BmcTokens.light, 1)), effects(BmcTokens.light));
      expect(BmcTokens.dark.lerp(BmcTokens.light, 0.5).glow, Color.lerp(BmcTokens.dark.glow, BmcTokens.light.glow, 0.5));
    });
  });

  group('buildAppTheme', () {
    for (final brightness in Brightness.values) {
      test('paints the ${brightness.name} scheme with its tokens', () {
        final theme = buildAppTheme(brightness);
        expect(theme.brightness, brightness);
        expect(theme.scaffoldBackgroundColor, Ground.of(brightness));
        expect(theme.extension<AppPalette>(), AppPalette.of(brightness));
        expect(theme.extension<BmcTokens>(), BmcTokens.of(brightness));
        expect(theme.colorScheme.primary, AppPalette.of(brightness).primary);
        expect(theme.colorScheme.error, AppPalette.of(brightness).error);
        expect(theme.dividerColor, AppPalette.of(brightness).divider);
      });
    }

    test('sets type in Geist on the MUI scale', () {
      final theme = buildAppTheme(Brightness.dark);
      expect(theme.textTheme.displayLarge!.fontFamily, fontSans);
      expect(theme.textTheme.displayLarge!.fontSize, 36);
      expect(theme.textTheme.headlineSmall!.fontSize, 19);
      expect(theme.textTheme.bodyLarge!.fontSize, 15);
      expect(theme.textTheme.bodyMedium!.fontSize, 14);
      expect(theme.textTheme.bodyLarge!.color, AppPalette.dark.text);
      expect(AppType.h1.letterSpacing, closeTo(-0.035 * 36, 1e-9));
      expect(AppType.mono().fontFamily, fontMono);
      expect(AppType.mono().fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('turns ripples off, as MUI has them', () {
      final theme = buildAppTheme(Brightness.light);
      expect(theme.splashFactory, NoSplash.splashFactory);
      expect(theme.filledButtonTheme.style!.splashFactory, NoSplash.splashFactory);
    });

    test('gives buttons radius 14 and 44 points of height, and the large and small sizes', () {
      final style = buildAppTheme(Brightness.dark).filledButtonTheme.style!;
      expect(style.minimumSize!.resolve({}), const Size(64, 44));
      expect((style.shape!.resolve({})! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(14));
      expect(style.backgroundColor!.resolve({}), AppPalette.dark.primary);
      expect(style.backgroundColor!.resolve({WidgetState.pressed}), AppPalette.dark.primaryDark);
      expect(largeButtonStyle.minimumSize!.resolve({}), const Size(64, 56));
      expect(smallButtonStyle.minimumSize!.resolve({}), const Size(48, 34));
    });

    test('rings a focused field with a soft halo', () {
      final fields = buildAppTheme(Brightness.dark).inputDecorationTheme;
      final focused = fields.focusedBorder! as HaloInputBorder;
      expect(focused.borderSide.color, BmcTokens.dark.accentLine);
      expect(focused.halo, BmcTokens.dark.accentSoft);
      expect((fields.enabledBorder! as OutlineInputBorder).borderSide.color, BmcTokens.dark.line2);

      // Focusing fades the halo in with the line.
      final halfway = ShapeBorder.lerp(fields.enabledBorder, focused, 0.5)! as HaloInputBorder;
      expect(halfway.halo.a, closeTo(BmcTokens.dark.accentSoft.a / 2, 0.01));
    });

    test('puts dialogs and sheets over the scrim', () {
      final theme = buildAppTheme(Brightness.light);
      expect(theme.dialogTheme.barrierColor, BmcTokens.light.scrim);
      expect(theme.bottomSheetTheme.modalBarrierColor, BmcTokens.light.scrim);
      expect(theme.dialogTheme.backgroundColor, AppPalette.light.paper);
    });
  });

  testWidgets('context.palette and context.bmc read the tokens of the current scheme', (tester) async {
    late AppPalette palette;
    late BmcTokens bmc;
    await pumpOnPage(
      tester,
      brightness: Brightness.light,
      Builder(
        builder: (context) {
          palette = context.palette;
          bmc = context.bmc;
          return const SizedBox();
        },
      ),
    );
    expect(palette, AppPalette.light);
    expect(bmc, BmcTokens.light);
  });

  testWidgets('a focused field paints its halo', (tester) async {
    await pumpOnPage(tester, const TextField(decoration: InputDecoration(labelText: 'Secret key')));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final decorator = tester.widget<InputDecorator>(find.byType(InputDecorator));
    expect(decorator.isFocused, isTrue);
    expect(Theme.of(tester.element(find.byType(TextField))).inputDecorationTheme.focusedBorder, isA<HaloInputBorder>());
  });
}
