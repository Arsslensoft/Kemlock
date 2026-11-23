import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/scan/qr_viewfinder.dart';
import 'package:kemlock/platform/scanner_source.dart';

import '../fakes/fake_scanner.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders the QR viewfinder starting, scanning, refused and locked on a
/// code, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/scan_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<void> pumpViewfinder(WidgetTester tester, FakeScanner scanner, {bool found = false}) => pumpOnPage(
      tester,
      brightness: brightness,
      center: false,
      reducedMotion: false,
      overrides: [scanner.asOverride],
      Column(
        children: [
          const SizedBox(height: 24),
          QrViewfinder(onScan: (_) {}, found: found),
        ],
      ),
    );

    testScreenshot('scan: scanning, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpViewfinder(tester, FakeScanner(animated: true));
      await settleForScreenshot(tester);
      // Part way through a sweep.
      await tester.pump(const Duration(milliseconds: 700));
      await captureScreenshot('scan_scanning_$name');
    });

    testScreenshot('scan: found, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpViewfinder(tester, FakeScanner(animated: true), found: true);
      await takeScreenshot(tester, 'scan_found_$name');
    });

    testScreenshot('scan: refused, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpViewfinder(tester, FakeScanner()..deny());
      await takeScreenshot(tester, 'scan_denied_$name');
    });

    testScreenshot('scan: starting, $name', (tester) async {
      usePhoneScreen(tester);
      await pumpOnPage(
        tester,
        brightness: brightness,
        center: false,
        overrides: [scannerSourceProvider.overrideWithValue(_StartingSource.new)],
        Column(
          children: [
            const SizedBox(height: 24),
            QrViewfinder(onScan: (_) {}),
          ],
        ),
      );
      await takeScreenshot(tester, 'scan_starting_$name');
    });
  }
}

/// A camera that never gets past starting.
class _StartingSource extends ScannerSource {
  final ValueNotifier<ScannerState> _state = ValueNotifier(const ScannerState());

  @override
  ValueListenable<ScannerState> get state => _state;

  @override
  Stream<String> get codes => const Stream.empty();

  @override
  bool get animated => false;

  @override
  Future<void> start() async => _state.value = _state.value.copyWith(phase: ScannerPhase.starting);

  @override
  Future<void> stop() async {}

  @override
  Future<void> setTorch(bool on) async {}

  @override
  Future<void> switchCamera() async {}

  @override
  Widget buildPreview(BuildContext context) => const FakeCameraPreview();

  @override
  Future<void> dispose() async {}
}
