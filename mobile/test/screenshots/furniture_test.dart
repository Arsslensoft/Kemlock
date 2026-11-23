import 'package:flutter/material.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the page furniture (titles, grouped rows, the empty state, badges,
/// segmented controls and alerts) in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/furniture_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('furniture: settings page, $name', (tester) async {
      usePhoneScreen(tester, size: const Size(393, 1000));
      await pumpScreen(tester, brightness: brightness, const _Settings());
      await takeScreenshot(tester, 'furniture_settings_$name');
    });

    testScreenshot('furniture: empty state and alerts, $name', (tester) async {
      usePhoneScreen(tester, size: const Size(393, 1080));
      await pumpScreen(tester, brightness: brightness, const _EmptyAndAlerts());
      await takeScreenshot(tester, 'furniture_empty_alerts_$name');
    });
  }
}

class _Settings extends StatefulWidget {
  const _Settings();

  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  String _theme = 'dark';
  String _language = 'en';
  String _method = 'scan';
  bool _biometric = true;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top, 16, 40),
      children: [
        ScreenHeader(title: 'About', onBack: () {}, backLabel: 'Back'),
        PageTitle(
          title: 'Settings',
          count: 12,
          trailing: IconButton(onPressed: () {}, icon: const Icon(Icons.add_rounded)),
          subtitle: 'Your vault, its backups and the app.',
        ),
        Group(
          label: 'Security',
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.fingerprint_rounded),
              primary: 'Unlock with fingerprint',
              secondary: 'Instead of typing the password',
              control: Switch(value: _biometric, onChanged: (v) => setState(() => _biometric = v)),
            ),
            GroupRow(icon: const Icon(Icons.timer_outlined), primary: 'Auto-lock', value: const Text('1 min'), onTap: () {}),
            GroupRow(icon: const Icon(Icons.groups_outlined), primary: 'Spaces', value: const Text('2'), onTap: () {}),
            GroupRow(icon: const Icon(Icons.delete_outline_rounded), primary: 'Delete this vault', danger: true, onTap: () {}),
          ],
        ),
        Group(
          label: 'Appearance',
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.dark_mode_outlined),
              primary: 'Theme',
              control: SizedBox(
                width: 196,
                child: SegmentedControl<String>(
                  size: SegmentSize.small,
                  semanticLabel: 'Theme',
                  value: _theme,
                  onChanged: (v) => setState(() => _theme = v),
                  options: const [
                    SegmentOption(value: 'system', label: 'System'),
                    SegmentOption(value: 'light', label: 'Light'),
                    SegmentOption(value: 'dark', label: 'Dark'),
                  ],
                ),
              ),
            ),
            GroupRow(
              icon: const Icon(Icons.translate_rounded),
              primary: 'Language',
              control: SizedBox(
                width: 196,
                child: SegmentedControl<String>(
                  size: SegmentSize.small,
                  mono: true,
                  semanticLabel: 'Language',
                  value: _language,
                  onChanged: (v) => setState(() => _language = v),
                  options: const [
                    SegmentOption(value: 'en', label: 'EN'),
                    SegmentOption(value: 'fr', label: 'FR'),
                  ],
                ),
              ),
            ),
          ],
        ),
        specimenLabel('Segmented control (tabs)'),
        SegmentedControl<String>(
          semantics: SegmentSemantics.tabs,
          semanticLabel: 'How to add',
          value: _method,
          onChanged: (v) => setState(() => _method = v),
          options: const [
            SegmentOption(value: 'scan', label: 'Scan', icon: Icon(Icons.qr_code_scanner_rounded)),
            SegmentOption(value: 'photo', label: 'Photo', icon: Icon(Icons.image_outlined)),
            SegmentOption(value: 'manual', label: 'Manual', icon: Icon(Icons.keyboard_rounded)),
          ],
        ),
      ],
    ),
  );
}

class _EmptyAndAlerts extends StatelessWidget {
  const _EmptyAndAlerts();

  @override
  Widget build(BuildContext context) => ScreenshotBoard(
    title: 'Furniture',
    children: [
      EmptyState(
        icon: const Icon(Icons.key_rounded),
        title: 'No accounts yet',
        body: 'Scan the QR code a site shows when you turn on two-factor sign-in.',
        action: FilledButton(onPressed: () {}, child: const Text('Add an account')),
      ),
      specimenLabel('Alerts'),
      const AppAlert(severity: AlertSeverity.error, child: Text('That password is not right.')),
      const SizedBox(height: 10),
      AppAlert(
        severity: AlertSeverity.warning,
        onClose: () {},
        closeLabel: 'Close',
        child: const Text('3 accounts were skipped because they are already in this vault.'),
      ),
      const SizedBox(height: 10),
      const AppAlert(severity: AlertSeverity.info, child: Text('Check the codes before saving them.')),
      const SizedBox(height: 10),
      const AppAlert(severity: AlertSeverity.success, child: Text('Export saved.')),
      specimenLabel('Tag'),
      const Align(
        alignment: Alignment.centerLeft,
        child: AccentTag(label: 'v6'),
      ),
    ],
  );
}
