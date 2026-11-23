import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the theme's type scale and Material's own widgets in dark and
/// light, for comparing with the web app:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/theme_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('theme: type scale, $name', (tester) async {
      usePhoneScreen(tester, size: const Size(393, 900));
      await pumpScreen(
        tester,
        brightness: brightness,
        const ScreenshotBoard(title: 'Type', children: [_Type()]),
      );
      await takeScreenshot(tester, 'theme_type_$name');
    });

    testScreenshot('theme: material widgets, $name', (tester) async {
      usePhoneScreen(tester, size: const Size(393, 1100));
      await pumpScreen(
        tester,
        brightness: brightness,
        const ScreenshotBoard(title: 'Controls', children: [_Controls()]),
      );
      // Focus the second field, to show its halo.
      await tester.tap(find.byType(TextField).last);
      await takeScreenshot(tester, 'theme_controls_$name');
    });
  }
}

class _Type extends StatelessWidget {
  const _Type();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    Widget line(String label, TextStyle style, [String text = 'Back my codes']) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 78,
            child: Text(label, style: AppType.caption.copyWith(color: b.faint)),
          ),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        specimenLabel('Headings'),
        line('h1', AppType.h1, 'Codes'),
        line('h2', AppType.h2, 'Unlock'),
        line('h3', AppType.h3),
        line('h4', AppType.h4),
        line('h5', AppType.h5),
        line('h6', AppType.h6),
        specimenLabel('Text'),
        line('subtitle1', AppType.subtitle1),
        line('subtitle2', AppType.subtitle2),
        line('body1', AppType.body1, 'Your codes stay on this phone, encrypted.'),
        line('body2', AppType.body2.copyWith(color: p.textSecondary), 'Your codes stay on this phone, encrypted.'),
        line('caption', AppType.caption.copyWith(color: p.textSecondary), 'Added 16 Oct 2026'),
        line('overline', AppType.overline.copyWith(color: b.faint), 'SECURITY'),
        line('button', AppType.button.copyWith(color: p.primary), 'Unlock'),
        line('mono', AppType.mono(fontSize: 22, fontWeight: FontWeight.w500), '492 018'),
        specimenLabel('Colours'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, color) in [
              ('page', p.background),
              ('paper', p.paper),
              ('raised', b.raised),
              ('sunken', b.sunken),
              ('primary', p.primary),
              ('accentText', b.accentText),
              ('accentSoft', b.accentSoft),
              ('warning', p.warning),
              ('warnSoft', b.warnSoft),
              ('error', p.error),
              ('dangerSoft', b.dangerSoft),
              ('faint', b.faint),
            ])
              Column(
                children: [
                  Container(
                    width: 52,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: b.line2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(label, style: AppType.caption.copyWith(fontSize: 10, color: p.textSecondary)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        specimenLabel('Buttons'),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(onPressed: () {}, child: const Text('Unlock')),
            OutlinedButton(onPressed: () {}, child: const Text('Export')),
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(
              style: filledButtonColors(background: p.error, foreground: p.onError),
              onPressed: () {},
              child: const Text('Delete'),
            ),
            const FilledButton(onPressed: null, child: Text('Disabled')),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton(style: largeButtonStyle, onPressed: () {}, child: const Text('Create vault')),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton(style: smallButtonStyle, onPressed: () {}, child: const Text('Small')),
            const SizedBox(width: 10),
            IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz_rounded)),
          ],
        ),
        specimenLabel('Fields'),
        const TextField(decoration: InputDecoration(labelText: 'Account name')),
        const SizedBox(height: 14),
        const TextField(
          decoration: InputDecoration(labelText: 'Secret key', helperText: 'Letters A to Z and digits 2 to 7'),
        ),
        specimenLabel('Switches and chips'),
        Row(
          children: [
            Switch(value: true, onChanged: (_) {}),
            const SizedBox(width: 12),
            Switch(value: false, onChanged: (_) {}),
            const SizedBox(width: 12),
            Checkbox(value: true, onChanged: (_) {}),
            Checkbox(value: false, onChanged: (_) {}),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            const Chip(label: Text('Work')),
            Chip(
              label: const Text('Personal'),
              side: BorderSide(color: context.bmc.line2),
              backgroundColor: Colors.transparent,
            ),
          ],
        ),
        specimenLabel('Progress'),
        const LinearProgressIndicator(value: 0.62),
        const SizedBox(height: 14),
        const Tooltip(message: 'Copied', child: Text('Tooltip below')),
      ],
    );
  }
}
