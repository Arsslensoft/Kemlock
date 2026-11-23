import 'package:flutter/material.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the codes, the countdown rings, the vault dial and the brand mark,
/// in dark and light, and a code caught mid-roll:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/codes_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('codes: digits and rings, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpScreen(
        tester,
        brightness: brightness,
        const ScreenshotBoard(title: 'Codes', children: [_Codes()]),
      );
      await takeScreenshot(tester, 'codes_digits_$name');
    });

    testScreenshot('codes: vault dial, $name', (tester) async {
      usePhoneScreen(tester, size: const Size(393, 1200));
      await pumpScreen(
        tester,
        brightness: brightness,
        const ScreenshotBoard(title: 'Vault dial', children: [_Dials()]),
      );
      await takeScreenshot(tester, 'codes_vault_dial_$name');
    });
  }

  testScreenshot('codes: rolling in, dark', (tester) async {
    usePhoneScreen(tester, size: const Size(393, 300));
    await pumpScreen(
      tester,
      reducedMotion: false,
      const ScreenshotBoard(
        title: 'Rolling',
        children: [
          SizedBox(height: 20),
          Center(
            child: CodeDigits(code: '274913', style: TextStyle(fontSize: 52)),
          ),
        ],
      ),
    );
    // Part way through the first roll: the first digits are nearly there, the last still on their way up from 0.
    await tester.pump(const Duration(milliseconds: 280));
    await captureScreenshot('codes_rolling_dark');
    await tester.pumpAndSettle();
  });
}

class _Codes extends StatelessWidget {
  const _Codes();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        specimenLabel('Account card (22, urgent in warning)'),
        Row(
          children: [
            const CountdownRing(remaining: 21, period: 60, size: 18, stroke: 2),
            const SizedBox(width: 8),
            CodeDigits(
              code: '492018',
              style: TextStyle(fontSize: 22, color: p.text),
            ),
            const SizedBox(width: 24),
            CodeDigits(
              code: '730155',
              style: TextStyle(fontSize: 22, color: p.warning),
            ),
          ],
        ),
        specimenLabel('Eight digits (19) and Steam'),
        Row(
          children: [
            const CodeDigits(code: '12345678', style: TextStyle(fontSize: 19)),
            const SizedBox(width: 24),
            CodeDigits(
              code: 'K7GR2',
              style: TextStyle(fontSize: 22, color: p.text),
            ),
          ],
        ),
        specimenLabel('Account sheet (52)'),
        const Center(
          child: CodeDigits(code: '118342', style: TextStyle(fontSize: 52, letterSpacing: 0.78)),
        ),
        specimenLabel('Countdown rings'),
        const Row(
          children: [
            CountdownRing(remaining: 30, period: 30, label: true),
            SizedBox(width: 16),
            CountdownRing(remaining: 17, period: 30, label: true),
            SizedBox(width: 16),
            CountdownRing(remaining: 4, period: 30, label: true),
            SizedBox(width: 16),
            CountdownRing(remaining: 1, period: 30, label: true),
            SizedBox(width: 16),
            CountdownRing(remaining: 40, period: 60, size: 18, stroke: 2),
          ],
        ),
        specimenLabel('Brand mark'),
        const Row(children: [BrandMark(), SizedBox(width: 16), BrandMark(size: 40), SizedBox(width: 16), BrandMark(size: 64)]),
      ],
    );
  }
}

class _Dials extends StatelessWidget {
  const _Dials();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (label, state, icon) in [
        ('Idle', VaultDialState.idle, Icons.lock_rounded),
        ('Busy', VaultDialState.busy, Icons.lock_rounded),
        ('Open', VaultDialState.open, Icons.check_rounded),
      ]) ...[Align(alignment: Alignment.centerLeft, child: specimenLabel(label)), VaultDial(state: state, icon: Icon(icon), size: 260)],
    ],
  );
}
