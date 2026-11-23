// What the app does with something another app shares (openspec:
// add-share-extension, decisions 2, 7 and 9): at once in an open vault,
// after unlock behind the lock screen, in whichever vault opens; Decrypt
// or Verify for PGP data, "Shared to Kemlock" for anything else.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/app_shell.dart';
import 'package:kemlock/features/pgp/decrypt_sheet.dart';
import 'package:kemlock/features/pgp/verify_sheet.dart';
import 'package:kemlock/features/share/share_sheet.dart';
import 'package:kemlock/platform/shared_items.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../fakes/fake_files.dart';
import '../features/pgp/pgp_kit.dart';
import '../features/share/share_kit.dart';
import '../flows/flow_kit.dart';
import '../helpers/test_app.dart';

void main() {
  Future<ShareApp> started(WidgetTester tester) async {
    final share = ShareApp(tester);
    await share.start(keys: ['ed']);
    return share;
  }

  /// Locks the vault, as auto-lock would, and shows the lock screen.
  Future<void> lock(ShareApp share) async {
    share.app.controller.lock();
    await share.settle();
    expect(find.text(t('lock.title.locked')), findsOneWidget);
  }

  /// Types [password] on the lock screen and waits for a vault to open.
  Future<void> unlock(ShareApp share, String password) async {
    await submitPassword(share.tester, password);
    await pumpUntil(share.tester, find.byType(AppShell));
    await share.settle();
    expect(share.app.state.phase, VaultPhase.unlocked);
  }

  Finder fieldHolding(String text) => find.byWidgetPredicate((widget) => widget is TextField && widget.controller?.text == text);

  group('when it is offered', () {
    testWidgets('with the vault open, at once', (tester) async {
      final share = await started(tester);
      await share.share(const SharedText('Meet me at nine.'));

      expect(find.byType(ShareSheet), findsOneWidget);
      expect(find.text(t('lock.title.locked')), findsNothing);
      expect(share.waiting, isNull);
    });

    testWidgets('behind the lock screen, once the password opens the vault', (tester) async {
      final share = await started(tester);
      await lock(share);

      await share.share(const SharedText('Meet me at nine.'));
      expect(find.text(t('share.lock.waiting')), findsOneWidget);
      expect(find.byType(ShareSheet), findsNothing);

      await unlock(share, masterPassword);
      expect(find.byType(ShareSheet), findsOneWidget);
      expect(inSheet<ShareSheet>(find.text('Meet me at nine.')), findsOneWidget);
      expect(share.waiting, isNull);
    });

    testWidgets('in a hidden vault opened by its password, with that vault\'s keys', (tester) async {
      final share = await started(tester);
      await tester.runAsync(() => share.app.vaultStore.createVault('Diary', 'diary-pw', listed: false));
      await lock(share);

      await share.share(const SharedText('Meet me at nine.'));
      await unlock(share, 'diary-pw');

      expect(share.app.state.vault.hidden, isTrue);
      expect(share.app.state.keys, isEmpty, reason: "the hidden vault's own keys, not the listed vault's");
      expect(find.byType(ShareSheet), findsOneWidget);
      // Nothing on the phone says a share went to it
      expect(storedText(share.app), isNot(contains('Meet me')));
      expect([
        for (final key in share.app.store.storedKeys())
          if (key.toLowerCase().contains('share')) key,
      ], isEmpty);
    });

    testWidgets('"Not now" on the lock screen: the vault opens with nothing offered', (tester) async {
      final share = await started(tester);
      await lock(share);
      await share.share(const SharedText('Meet me at nine.'));

      await share.tap(find.text(t('share.lock.notNow')));
      await unlock(share, masterPassword);

      expect(find.byType(ShareSheet), findsNothing);
      expect(share.waiting, isNull);
    });

    testWidgets('ten minutes behind the lock screen: the line is gone and unlocking offers nothing', (tester) async {
      final share = await started(tester);
      await lock(share);
      await share.share(const SharedText('Meet me at nine.'));

      await tester.pump(sharedItemLife);
      await share.settle();
      expect(find.text(t('share.lock.waiting')), findsNothing);

      await unlock(share, masterPassword);
      expect(find.byType(ShareSheet), findsNothing);
    });
  });

  group('where it goes', () {
    testWidgets('an encrypted message goes straight to Decrypt, holding it', (tester) async {
      final share = await started(tester);
      final message = fixtureText('share/encrypted.asc');
      await share.share(SharedText(message));

      expect(find.byType(ShareSheet), findsNothing);
      expect(find.byType(DecryptSheet), findsOneWidget);
      expect(inSheet<DecryptSheet>(fieldHolding(message)), findsOneWidget);

      // And it opens with the vault's key
      await share.tap(find.widgetWithText(FilledButton, t('pgp.decrypt.button')));
      expect(inSheet<DecryptSheet>(find.textContaining('Meet me at the usual place at nine.')), findsOneWidget);
    });

    testWidgets('an encrypted file with an unhelpful name goes to Decrypt, by its content', (tester) async {
      final share = await started(tester);
      final file = share.copied('download.bin', fixtureBytes('share/encrypted.gpg'));
      await share.share(file);

      expect(find.byType(ShareSheet), findsNothing);
      expect(inSheet<DecryptSheet>(find.text('download.bin')), findsOneWidget);
    });

    testWidgets('a clear-signed text goes straight to Verify, holding it', (tester) async {
      final share = await started(tester);
      final message = fixtureText('share/clearsigned.asc');
      await share.share(SharedText(message));

      expect(find.byType(ShareSheet), findsNothing);
      expect(inSheet<VerifySheet>(fieldHolding(message)), findsOneWidget);
    });

    testWidgets('a detached signature goes to Verify with the signature set and no file', (tester) async {
      final share = await started(tester);
      final signature = share.copied('message.txt.sig', fixtureBytes('share/detached.sig'));
      await share.share(signature);

      expect(find.byType(ShareSheet), findsNothing);
      expect(inSheet<VerifySheet>(find.text('message.txt.sig')), findsOneWidget);
      expect(inSheet<VerifySheet>(find.text(t('pgp.verify.field'))), findsNothing);
      expect(inSheet<VerifySheet>(find.widgetWithText(FilledButton, t('pgp.verify.button'))), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, t('pgp.verify.button'))).onPressed, isNull);

      // The person chooses the file it signs, and it checks out
      share.files.nextPath = FakeFiles.onDisk('message.txt', fixtureBytes('share/message.txt'));
      await share.tap(find.text(t('pgp.decrypt.chooseFile')));
      await share.tap(find.widgetWithText(FilledButton, t('pgp.verify.button')));
      expect(share.requests, hasLength(1));
      expect(File(signature.path).existsSync(), isTrue, reason: 'kept until the sheet closes, to check again');
      await share.closeSheet();
      expect(File(signature.path).existsSync(), isFalse);
    });

    testWidgets('a plain text is offered for Encrypt and Sign', (tester) async {
      final share = await started(tester);
      await share.share(SharedText(fixtureText('share/mentions-pgp.txt')));

      expect(find.byType(ShareSheet), findsOneWidget);
      expect(find.byType(DecryptSheet), findsNothing);
    });
  });
}
