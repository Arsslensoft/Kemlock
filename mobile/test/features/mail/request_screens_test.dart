import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_grants.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/features/settings/auto_lock.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/test_app.dart';
import 'mail_app_kit.dart';
import 'mail_kit.dart';

const _fairEmail = MailCaller(package: 'eu.faircode.email', cert: 'bb22', label: 'FairEmail');

/// The request screen's other pages (openspec: add-pgp-mail-provider,
/// task 6.3).
void main() {
  group('the key picker', () {
    Future<MailScreensApp> upTo(WidgetTester tester) async {
      final mail = MailScreensApp(tester);
      await mail.start();
      for (final key in ['ed', 'rsa', 'expired', 'revoked']) {
        await mail.addKey(key);
      }
      await mail.approve();
      return mail;
    }

    testWidgets("lists the address's keys first, and no expired or revoked one", (tester) async {
      final mail = await upTo(tester);
      await mail.bringUp(mail.call(OpenPgp.getSignKeyId, extras: {'user_id': 'Fixture RSA <rsa@example.org>'}));
      expect(find.text(t('mail.pick.title', {'app': 'Thunderbird'})), findsOneWidget);
      final rsa = tester.getTopLeft(find.byKey(const ValueKey('pick-pgp-rsa'))).dy;
      final ed = tester.getTopLeft(find.byKey(const ValueKey('pick-pgp-ed'))).dy;
      expect(rsa, lessThan(ed));
      expect(find.byKey(const ValueKey('pick-pgp-expired')), findsNothing);
      expect(find.byKey(const ValueKey('pick-pgp-revoked')), findsNothing);
    });

    testWidgets('picking allows the key for the app and hands back its id', (tester) async {
      final mail = await upTo(tester);
      final call = mail.call(OpenPgp.getSignKeyId);
      await mail.bringUp(call);
      await tapOn(tester, find.byKey(const ValueKey('pick-pgp-rsa')));
      await mail.settle();
      expect((await tester.runAsync(() => mail.apps.of(thunderbird.package)))!.keys, ['pgp-rsa']);
      expect(mail.requests.finished.single.requestId, call.requestId);
      expect(mail.requests.finished.single.ok, isTrue);
      expect(mail.requests.finished.single.extras, {'sign_key_id': keyIdOf(rsaFingerprint)});
    });
  });

  group('an unchecked key', () {
    Future<MailScreensApp> upTo(WidgetTester tester) async {
      final mail = MailScreensApp(tester);
      await mail.start();
      await mail.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA');
      await mail.approve();
      await mail.approve(caller: _fairEmail);
      return mail;
    }

    testWidgets('"Encrypt anyway" remembers its fingerprint for that app only', (tester) async {
      final mail = await upTo(tester);
      final call = mail.call(
        OpenPgp.encrypt,
        extras: {
          'user_ids': ['rsa@example.org'],
        },
        input: [1, 2, 3],
      );
      await mail.bringUp(call);
      expect(find.text(t('mail.unchecked.title', {'name': 'Fixture RSA'})), findsOneWidget);
      expect(find.text(t('mail.unchecked.body', {'app': 'Thunderbird'})), findsOneWidget);
      await tapOn(tester, find.text(t('mail.unchecked.anyway')));
      await mail.settle();
      expect((await tester.runAsync(() => mail.apps.of(thunderbird.package)))!.unchecked, [rsaFingerprint]);
      expect((await tester.runAsync(() => mail.apps.of(_fairEmail.package)))!.unchecked, isEmpty);
      expect(mail.finished, [(call.requestId, true)]);
    });

    testWidgets('"Check it now" opens the check of the contact', (tester) async {
      final mail = await upTo(tester);
      await mail.bringUp(
        mail.call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': ['rsa@example.org'],
          },
          input: [1],
        ),
      );
      await tapOn(tester, find.text(t('mail.unchecked.check')));
      expect(find.text(t('contacts.sheet.checkNow')), findsWidgets);
      expect(find.byKey(const ValueKey('check-fingerprint')), findsOneWidget);
    });

    // The check covers the addresses the key named when it was made; the fixture's own came after it
    const checkedBefore = (fingerprint: rsaFingerprint, addresses: ['old@example.org']);

    testWidgets('a key compared before it named the address says so, not that it was never compared', (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start();
      await mail.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', checkedFor: checkedBefore);
      await mail.approve();
      await mail.bringUp(
        mail.call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': ['rsa@example.org'],
          },
          input: [1],
        ),
      );

      expect(find.text(t('mail.unchecked.title', {'name': 'Fixture RSA'})), findsOneWidget);
      expect(find.text(t('mail.unchecked.body.otherAddress', {'app': 'Thunderbird'})), findsOneWidget);
      expect(find.text(t('mail.unchecked.body', {'app': 'Thunderbird'})), findsNothing);
    });

    testWidgets('a key never compared beside one compared for other addresses says both', (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start();
      await mail.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', checkedFor: checkedBefore);
      await mail.addContact('c-grace', 'keys/contacts/grace-1.public.asc', name: 'Grace Hopper');
      await mail.approve();
      await mail.bringUp(
        mail.call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': ['rsa@example.org', 'grace@example.org'],
          },
          input: [1],
        ),
      );

      expect(find.text(t('mail.unchecked.body.mixed', {'app': 'Thunderbird'})), findsOneWidget);
      expect(find.byKey(const ValueKey('unchecked-c-rsa')), findsOneWidget);
      expect(find.byKey(const ValueKey('unchecked-c-grace')), findsOneWidget);
    });
  });

  testWidgets('the missing keys list the addresses, and can only close', (tester) async {
    final mail = MailScreensApp(tester);
    await mail.start();
    await mail.addKey('ed');
    await mail.approve();
    final call = mail.call(
      OpenPgp.encrypt,
      extras: {
        'user_ids': ['ed25519@example.org', 'nobody@example.org'],
      },
      input: [1],
    );
    await mail.bringUp(call);
    expect(find.text(t('mail.missing.title')), findsOneWidget);
    expect(find.text('nobody@example.org'), findsOneWidget);
    expect(find.text('ed25519@example.org'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    await tapOn(tester, find.text(t('mail.missing.close')));
    expect(mail.finished, [(call.requestId, false)]);
  });

  testWidgets('a key the app may not use yet is added on Allow, and the request goes on', (tester) async {
    final mail = MailScreensApp(tester);
    await mail.start();
    await mail.addKey('ed');
    await mail.addKey('rsa');
    await mail.approve(keys: const ['pgp-ed']);
    final call = mail.call(OpenPgp.detachedSign, extras: {'sign_key_id': keyIdOf(rsaFingerprint)}, input: [1]);
    await mail.bringUp(call);
    expect(find.text(t('mail.addKey.title', {'app': 'Thunderbird', 'key': 'Fixture RSA'})), findsOneWidget);
    await tapOn(tester, find.text(t('mail.approve.allow')));
    await mail.settle();
    expect((await tester.runAsync(() => mail.apps.of(thunderbird.package)))!.keys, ['pgp-ed', 'pgp-rsa']);
    expect(mail.finished, [(call.requestId, true)]);
    expect(mail.app.container.read(mailGrantsProvider).holds(call.requestId), isTrue, reason: 'the person allowed the key');
  });

  group('a request screen', () {
    testWidgets('that asks nothing takes no hold on auto-lock', (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start();
      await mail.approve();
      // A request the app got while the vault was locked, its screen fired once the vault is open
      mail.app.controller.lock();
      await tester.pumpAndSettle();
      final call = mail.call(OpenPgp.checkPermission);
      final answer = (await tester.runAsync(() => mail.requests.send(call)))!;
      expect(answer.resultCode, OpenPgp.resultUserInteraction);
      await mail.app.unlock(tester, 'pw');
      mail.requests.bringToFront(call.requestId, call.caller);
      await mail.settle();
      expect(mail.finished, [(call.requestId, true)]);
      expect(mail.app.container.read(mailGrantsProvider).holds(call.requestId), isFalse);
      expect(mail.app.container.read(autoLockHoldsProvider).isHeld, isFalse);
    });

    testWidgets('in front while the person unlocks takes the hold', (tester) async {
      final mail = MailScreensApp(tester);
      await mail.start();
      await mail.approve();
      mail.app.controller.lock();
      await tester.pumpAndSettle();
      final call = mail.call(OpenPgp.checkPermission);
      await mail.bringUp(call);
      expect(find.byKey(const ValueKey('mail-request-line')), findsOneWidget);
      await mail.app.unlock(tester, 'pw');
      await mail.settle();
      expect(mail.finished, [(call.requestId, true)]);
      expect(mail.app.container.read(mailGrantsProvider).holds(call.requestId), isTrue);
    });
  });
}
