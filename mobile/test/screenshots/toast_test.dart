import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/ui/ui.dart';

import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

/// Renders each kind of toast over a page, in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/toast_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    for (final (kind, message, severity, action) in [
      ('copied', 'Code copied', ToastSeverity.success, null),
      ('undo', 'GitHub deleted', ToastSeverity.success, ToastAction(label: 'Undo', onPressed: () {})),
      ('error', 'The file could not be read. Try another one.', ToastSeverity.error, null),
      ('locked', 'Vault locked', ToastSeverity.info, null),
    ]) {
      testScreenshot('toast: $kind, $name', (tester) async {
        usePhoneScreen(tester, size: const Size(393, 420));
        await pumpScreen(
          tester,
          brightness: brightness,
          ScreenshotBoard(
            title: 'Toast',
            children: [Text('Toasts float 98px above the home bar.', style: AppType.body2)],
          ),
        );
        await settleForScreenshot(tester);
        showToast(tester.element(find.byType(ScreenshotBoard)), message, severity: severity, action: action);
        // Caught once it is in, well before it goes after three seconds.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await captureScreenshot('toast_${kind}_$name');
        await tester.pump(const Duration(seconds: 6));
      });
    }
  }
}
