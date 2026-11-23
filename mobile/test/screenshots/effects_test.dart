import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/tab_bar.dart';
import 'package:kemlock/ui/ui.dart';

import '../fakes/fake_scanner.dart';
import '../helpers/app_harness.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders every effect of `lib/ui/theme/effects.dart` on a sample of what
/// it decorates, with the same sample undecorated under it, in dark and
/// light and held at a quarter and three quarters of each loop; and the
/// four tabs and a sheet with their chrome lit, held half way:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/effects_test.dart
///
/// One test runs without the flag: the board is drawn twice and the two
/// pictures are the same bytes (openspec: visual-effects, "An effect's
/// picture is repeatable").
void main() {
  const boardSize = Size(393, 2860);

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    for (final (phase, at) in [(0.25, '25'), (0.75, '75')]) {
      testScreenshot('effects: the board, $name, at $phase', (tester) async {
        usePhoneScreen(tester, size: boardSize);
        await pumpScreen(tester, brightness: brightness, reducedMotion: false, EffectsBoard(phase: phase));
        await takeScreenshot(tester, 'effects_board_${name}_$at');
      });
    }

    testScreenshot('effects: the board with reduced motion, $name', (tester) async {
      usePhoneScreen(tester, size: boardSize);
      await pumpScreen(tester, brightness: brightness, const EffectsBoard(phase: null));
      await takeScreenshot(tester, 'effects_board_${name}_still');
    });

    testScreenshot('effects: the tabs and a sheet with their chrome lit, $name', (tester) async {
      usePhoneScreen(tester);
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final app = TestApp();
      await tester.runAsync(() => app.createVault('pw'));
      await app.pump(tester, overrides: [FakeScanner().asOverride]);
      await app.unlock(tester, 'pw');
      // The harness reduces motion to settle the unlock. With it off the loops show, held half way by the harness's pin.
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.pumpAndSettle();

      for (final tab in AppTab.values) {
        await tester.tap(find.descendant(of: find.byType(AppTabBar), matching: find.text(t(tab.labelId))));
        await tester.pumpAndSettle();
        await takeScreenshot(tester, 'effects_tab_${tab.name}_$name');
      }
      await tester.tap(find.descendant(of: find.byType(AppTabBar), matching: find.byIcon(Icons.add_rounded)));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'effects_sheet_$name');
    });
  }

  testWidgets('the board held at one moment is the same picture twice, and another picture at another moment', (tester) async {
    usePhoneScreen(tester, size: boardSize);
    // Real soft shadows, as in the screenshots: tests otherwise draw them as solid blocks.
    debugDisableShadows = false;
    try {
      Future<Uint8List> picture(double phase) async {
        // A fresh tree each time.
        await tester.pumpWidget(const SizedBox());
        await pumpScreen(
          tester,
          reducedMotion: false,
          RepaintBoundary(
            key: const ValueKey('board'),
            child: EffectsBoard(phase: phase),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(tester.hasRunningAnimations, isFalse);
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('board')));
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return data!.buffer.asUint8List();
        });
        return bytes!;
      }

      final first = await picture(0.5);
      final second = await picture(0.5);
      expect(first.length, boardSize.width * boardSize.height * 4);
      expect(second, first);

      final other = await picture(0.25);
      expect(other, isNot(first));
    } finally {
      debugDisableShadows = true;
    }
  });
}

/// Every effect on a sample of what it decorates, each over the same
/// sample without it. [phase] holds every loop there; null draws the board
/// as reduced motion leaves it.
class EffectsBoard extends StatelessWidget {
  const EffectsBoard({super.key, required this.phase});

  final double? phase;

  static const _fingerprint = '7A3F 91C2 0B5E D418 66AF\n2C90 E1B7 5D03 F8A4 19CE';
  static const _message = 'Meet at the north gate at nine. Bring the second key.';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return EffectsScope(
      pinned: phase,
      // The board shows every effect at once, which no screen may.
      loopLimit: 24,
      child: ScreenshotBoard(
        title: phase == null ? 'Effects, still' : 'Effects at $phase',
        children: [
          specimenLabel('Main button: sheen and shadow, and without'),
          Sheen(
            child: FilledButton(style: largeButtonStyle, onPressed: () {}, child: const Text('Encrypt and share')),
          ),
          const SizedBox(height: 12),
          FilledButton(style: largeButtonStyle, onPressed: () {}, child: const Text('Encrypt and share')),

          specimenLabel('Chip: faint sheen, and without'),
          const Wrap(
            spacing: 8,
            children: [
              Sheen(faint: true, borderRadius: BorderRadius.all(Radius.circular(16)), child: _Chip('Ada Lovelace')),
              _Chip('Ada Lovelace'),
            ],
          ),

          specimenLabel('Option: selected with its glow, selected without, not selected'),
          const Glow(
            child: _Option(title: 'Curve25519', body: 'Small and fast. The usual choice.', selected: true),
          ),
          const SizedBox(height: 12),
          const _Option(title: 'Curve25519', body: 'Small and fast. The usual choice.', selected: true),
          const SizedBox(height: 12),
          const Glow(
            active: false,
            child: _Option(title: 'RSA 4096', body: 'For old software that needs it.', selected: false),
          ),

          specimenLabel('Alert: information with its glow, without, and a warning'),
          const AppAlert(severity: AlertSeverity.info, glow: true, child: Text('Signed by Ada Lovelace. The signature is good.')),
          const SizedBox(height: 12),
          const AppAlert(severity: AlertSeverity.info, child: Text('Signed by Ada Lovelace. The signature is good.')),
          const SizedBox(height: 12),
          const AppAlert(severity: AlertSeverity.warning, glow: true, child: Text('This key was not checked with its owner.')),

          specimenLabel('Card: the border light, and without'),
          const NeonBorder(child: _KeyCard(radius: 20.5)),
          const SizedBox(height: 12),
          const Padding(padding: EdgeInsets.all(NeonBorder.width), child: _KeyCard(radius: 20.5)),

          specimenLabel('Fingerprint: the scan line, and without'),
          ScanLine(
            child: Text(_fingerprint, style: AppType.mono(fontSize: 16, color: p.text)),
          ),
          const SizedBox(height: 12),
          Text(_fingerprint, style: AppType.mono(fontSize: 16, color: p.text)),

          specimenLabel('Text: half way through its reveal, and revealed'),
          // A reveal plays once and the pin shows its end, so its middle is drawn here from its parts.
          Opacity(
            opacity: 0.65,
            child: RevealClip(
              revealed: 0.5,
              textDirection: Directionality.of(context),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3, tileMode: TileMode.decal),
                child: Text(_message, style: AppType.body1.copyWith(color: p.text)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Reveal(
            child: Text(_message, style: AppType.body1.copyWith(color: p.text)),
          ),

          specimenLabel('Countdown ring: with time left, and about to change'),
          const Row(
            children: [
              CountdownRing(remaining: 17, period: 30, label: true),
              SizedBox(width: 16),
              CountdownRing(remaining: 4, period: 30, label: true),
              SizedBox(width: 16),
              CountdownRing(remaining: 17, period: 30, size: 18, stroke: 2),
            ],
          ),

          specimenLabel('Progress bar: 7 of 100, 64 of 100, full'),
          const ProgressBar(value: 7, total: 100, semanticsLabel: '7 of 100'),
          const SizedBox(height: 14),
          const ProgressBar(value: 64, total: 100, semanticsLabel: '64 of 100'),
          const SizedBox(height: 14),
          const ProgressBar(value: 100, total: 100, semanticsLabel: '100 of 100'),

          specimenLabel('Switch and tile: on with its glow and the accent tile, off and the plain tile'),
          Group(
            children: [
              GroupRow(
                first: true,
                accent: true,
                icon: const Icon(Icons.key_rounded),
                primary: 'Unlock with a security key',
                control: AppSwitch(value: true, onChanged: (_) {}),
              ),
              GroupRow(
                icon: const Icon(Icons.fingerprint_rounded),
                primary: 'Unlock with fingerprint',
                control: AppSwitch(value: false, onChanged: (_) {}),
              ),
            ],
          ),

          specimenLabel('Tab bar: the active tab and the add button'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: AppTabBar(active: AppTab.vault, onSelect: (_) {}, addLabel: 'Add', onAdd: () {}),
          ),

          specimenLabel('Page: two ambient lights'),
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              height: 300,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: p.background),
                  const AmbientLight(lights: 2),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Vault', style: AppType.h1.copyWith(color: p.text)),
                  ),
                ],
              ),
            ),
          ),

          specimenLabel('Sheet: one ambient light'),
          AppBottomSheet(
            label: 'A sheet',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Security key', style: AppType.h3.copyWith(color: p.text)),
                  const SizedBox(height: 10),
                  Text('Hold the key to the back of the phone, or plug it in.', style: AppType.body1.copyWith(color: p.textSecondary)),
                  const SizedBox(height: 120),
                  Text('The light lies behind this text.', style: AppType.caption.copyWith(color: b.faint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A chip as the mockups draw a recipient: a pill in accentSoft.
class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(color: context.bmc.accentSoft, borderRadius: BorderRadius.circular(16)),
    child: Center(
      widthFactor: 1,
      child: Text(
        label,
        style: TextStyle(fontFamily: fontSans, fontSize: 13.5, fontWeight: FontWeight.w600, color: context.bmc.accentText),
      ),
    ),
  );
}

/// An option card as the mockups draw one: its mark filled and its border
/// in the accent when selected, which say so without the glow.
class _Option extends StatelessWidget {
  const _Option({required this.title, required this.body, required this.selected});

  final String title;
  final String body;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Semantics(
      container: true,
      selected: selected,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? Color.alphaBlend(b.accentSoft, p.paper) : p.paper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? b.accentLine : p.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? p.onPrimary : null,
                border: Border.all(color: selected ? p.primary : b.faint, width: selected ? 7 : 2),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppType.body1.copyWith(fontWeight: FontWeight.w500, color: p.text),
                  ),
                  Text(body, style: AppType.caption.copyWith(color: p.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card of a connected security key, which says in words what the
/// border light accompanies.
class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) => Material(
    color: context.palette.paper,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    clipBehavior: Clip.antiAlias,
    child: const GroupRow(
      first: true,
      accent: true,
      icon: Icon(Icons.usb_rounded),
      primary: 'YubiKey 5C NFC',
      secondary: 'Connected over USB',
    ),
  );
}
