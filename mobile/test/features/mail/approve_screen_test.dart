import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_handler.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/test_app.dart';
import 'mail_app_kit.dart';

/// "Let Thunderbird use your PGP keys?" (openspec: add-pgp-mail-provider,
/// task 6.2).
void main() {
  Finder title() => find.text(t('mail.approve.title', {'app': 'Thunderbird'}));

  Future<MailScreensApp> upTo(WidgetTester tester, {MailCaller caller = thunderbird}) async {
    final mail = MailScreensApp(tester);
    await mail.start();
    await mail.addKey('ed');
    await mail.addKey('rsa');
    return mail;
  }

  testWidgets("names the app and its package, and Allow with one key ticked writes that key and today's date", (tester) async {
    final mail = await upTo(tester);
    final call = mail.call(OpenPgp.checkPermission);
    await mail.bringUp(call);
    expect(title(), findsOneWidget);
    expect(find.text('net.thunderbird.android'), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-other-signature')), findsNothing);
    expect(find.byKey(const ValueKey('mail-hidden-vault')), findsNothing);

    await tapOn(tester, find.descendant(of: find.byKey(const ValueKey('approve-pgp-ed')), matching: find.byType(Checkbox)));
    await tapOn(tester, find.text(t('mail.approve.allow')));
    await mail.settle();

    final app = (await tester.runAsync(() => mail.apps.of(thunderbird.package)))!;
    expect(app.keys, ['pgp-ed']);
    expect(app.cert, thunderbird.cert);
    expect(app.name, 'Thunderbird');
    expect(DateTime.fromMillisecondsSinceEpoch(app.allowedAt, isUtc: true), mailNow);
    expect(mail.finished, [(call.requestId, true)]);
  });

  testWidgets("Don't allow writes nothing and cancels", (tester) async {
    final mail = await upTo(tester);
    final call = mail.call(OpenPgp.checkPermission);
    await mail.bringUp(call);
    await tapOn(tester, find.text(t('mail.approve.deny')));
    await mail.settle();
    expect(await tester.runAsync(() => mail.apps.current()), isEmpty);
    expect(mail.app.store.getItem('backmycodes_mail_apps'), isNull);
    expect(mail.finished, [(call.requestId, false)]);
  });

  testWidgets('Allow works with no key ticked', (tester) async {
    final mail = await upTo(tester);
    final call = mail.call(OpenPgp.checkPermission);
    await mail.bringUp(call);
    await tapOn(tester, find.text(t('mail.approve.allow')));
    await mail.settle();
    expect((await tester.runAsync(() => mail.apps.of(thunderbird.package)))!.keys, isEmpty);
    expect(mail.finished, [(call.requestId, true)]);
  });

  testWidgets('warns only of a known package under another certificate', (tester) async {
    final mail = await upTo(tester);
    await mail.approve();
    await mail.bringUp(
      mail.call(
        OpenPgp.checkPermission,
        caller: const MailCaller(package: 'net.thunderbird.android', cert: 'ff00', label: 'Thunderbird'),
      ),
    );
    expect(title(), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-other-signature')), findsOneWidget);
    expect(find.text(t('mail.approve.otherSignature')), findsOneWidget);
  });

  testWidgets('warns of what a mail app remembers only in a hidden vault', (tester) async {
    final mail = MailScreensApp(tester);
    await mail.start(beforeStart: () => mail.app.vaultStore.createVault('Hidden', 'hidden pw', listed: false));
    mail.app.controller.lock();
    await tester.pumpAndSettle();
    await submitPassword(tester, 'hidden pw');
    await pumpUntil(tester, tab('nav.vault'));
    expect(mail.app.state.vault.hidden, isTrue);
    await mail.bringUp(mail.call(OpenPgp.checkPermission));
    expect(find.byKey(const ValueKey('mail-hidden-vault')), findsOneWidget);
    expect(find.text(t('mail.approve.hidden', {'app': 'Thunderbird'})), findsOneWidget);
  });
}
