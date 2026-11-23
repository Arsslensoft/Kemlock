import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/share/share_sheet.dart';
import 'package:kemlock/platform/shared_items.dart';

import '../features/share/share_kit.dart';
import '../helpers/screenshots.dart';

/// "Shared to Kemlock" for a text and for a file, in dark and light. No
/// mockup draws it; it is held against decision 10 of add-share-extension:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/share_test.dart
void main() {
  Future<ShareApp> vault(WidgetTester tester, Brightness brightness) async {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final share = ShareApp(tester);
    await share.start(keys: ['kemlock-ed']);
    usePhoneScreen(tester);
    await tester.pumpAndSettle();
    return share;
  }

  for (final brightness in Brightness.values) {
    final name = brightness.name;

    testScreenshot('share: a shared text, $name', (tester) async {
      final share = await vault(tester, brightness);
      unawaited(
        showShareSheet(
          share.shell,
          const SharedText(
            'Hi Ada,\n'
            'The draft of the contract is ready. Could you read it before Friday and tell me what you think of the '
            'second clause?\n'
            'The meeting moved to nine, at the usual place.\n'
            'Bring the signed copy.\n'
            'Grace',
          ),
        ),
      );
      await share.settle();
      await takeScreenshot(tester, 'share_text_$name');
    });

    testScreenshot('share: a shared file, $name', (tester) async {
      final share = await vault(tester, brightness);
      unawaited(showShareSheet(share.shell, share.copied('contract.pdf', List.filled(184320, 0x25))));
      await share.settle();
      await takeScreenshot(tester, 'share_file_$name');
    });
  }
}
