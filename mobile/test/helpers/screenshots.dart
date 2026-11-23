import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

/// Screenshots run only with `--dart-define=SCREENSHOTS=true`, together
/// with `--update-goldens`, which writes the PNGs to
/// `test/screenshots/goldens/` (kept out of git). They are for looking at
/// the design without a phone, not for comparing in CI:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots
const screenshotsEnabled = bool.fromEnvironment('SCREENSHOTS');

bool _fontsLoaded = false;

/// Loads Geist, Geist Mono and the Material icons, so screenshots show real
/// text and icons instead of the test font's boxes.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<ByteData> load(String asset) => rootBundle.load(asset);
  final geist = FontLoader('Geist');
  final mono = FontLoader('GeistMono');
  for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    geist.addFont(load('assets/fonts/Geist-$weight.ttf'));
    mono.addFont(load('assets/fonts/GeistMono-$weight.ttf'));
  }
  final icons = FontLoader('MaterialIcons')..addFont(load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([geist.load(), mono.load(), icons.load()]);
}

/// A screenshot test: skipped unless [screenshotsEnabled], with the app's
/// fonts loaded and real soft shadows, which tests otherwise draw as solid
/// blocks.
void testScreenshot(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, skip: !screenshotsEnabled, (tester) async {
      await tester.runAsync(loadAppFonts);
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        // Back before the test ends: Flutter checks the painting flags before tear-downs run.
        debugDisableShadows = true;
      }
    });

/// A phone screen: 393 by 852 points at 3x, with a notch and a home bar.
void usePhoneScreen(WidgetTester tester, {Size size = const Size(393, 852)}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

/// Lets images decode, which happens outside the fake clock, then settles
/// the animations.
Future<void> settleForScreenshot(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.pump(const Duration(seconds: 2));
}

/// Writes the app as it is now to `test/screenshots/goldens/<name>.png`,
/// without settling first.
Future<void> captureScreenshot(String name) => expectLater(find.byType(MaterialApp).first, matchesGoldenFile('goldens/$name.png'));

/// Settles the screen, then writes it to `test/screenshots/goldens/<name>.png`.
Future<void> takeScreenshot(WidgetTester tester, String name) async {
  await settleForScreenshot(tester);
  await captureScreenshot(name);
}

/// A page of specimens for screenshots: a [title] over [children], with a
/// small label before each group (see [specimenLabel]).
class ScreenshotBoard extends StatelessWidget {
  const ScreenshotBoard({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 12, 16, 40),
      children: [
        Text(title, style: AppType.h2.copyWith(color: context.palette.text)),
        ...children,
      ],
    ),
  );
}

/// The faint capitals over a group of specimens.
Widget specimenLabel(String text) => Builder(
  builder: (context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 24, 2, 10),
    child: Text(text.toUpperCase(), style: AppType.overline.copyWith(color: context.bmc.faint)),
  ),
);
