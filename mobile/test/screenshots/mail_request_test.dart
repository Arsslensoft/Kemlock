import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/theme_choice.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/ui/ui.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../features/mail/mail_app_kit.dart';
import '../helpers/screenshots.dart';

/// Renders a mail app's request screen: the lock screen with its line, and
/// the approval with the warning of an app signed differently, in dark and
/// light (openspec: add-pgp-mail-provider, task 8.3):
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/mail_request_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<MailScreensApp> start(WidgetTester tester, {required bool unlock}) async {
      final mail = MailScreensApp(tester);
      await mail.start(
        unlock: unlock,
        beforeStart: () async =>
            mail.app.store.setItem(keyTheme, (brightness == Brightness.dark ? ThemeChoice.dark : ThemeChoice.light).name),
      );
      // startApp's tall screen, back to a phone's
      usePhoneScreen(tester);
      await tester.pumpAndSettle();
      return mail;
    }

    testScreenshot('mail request: the lock screen names the app, $name', (tester) async {
      final mail = await start(tester, unlock: false);
      await mail.bringUp(mail.call(OpenPgp.decryptVerify));
      await takeScreenshot(tester, 'mail_request_lock_$name');
    });

    testScreenshot('mail request: allowing an app, $name', (tester) async {
      final mail = await start(tester, unlock: true);
      await mail.addKey('kemlock-ed');
      await mail.addKey('ed');
      await mail.approve();
      // The toasts of the keys added would lie over the buttons
      (tester.state(find.byType(ToastHost)) as ToastController).hide();
      await mail.bringUp(
        mail.call(
          OpenPgp.checkPermission,
          caller: const MailCaller(package: 'net.thunderbird.android', cert: 'ff00', label: 'Thunderbird'),
        ),
      );
      await takeScreenshot(tester, 'mail_request_approve_$name');
    });
  }
}
