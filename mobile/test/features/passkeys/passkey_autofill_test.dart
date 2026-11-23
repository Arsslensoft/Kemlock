import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/autofill/autofill_copy.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/platform/autofill.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart';
import '../../helpers/app_harness.dart';
import '../backup/backup_test_kit.dart' show realDirectory;

const _passkey = Passkey(
  id: 'p1',
  credentialId: 'AAECAwQFBgcICQoLDA0ODw',
  rpId: 'github.com',
  rpName: 'GitHub',
  userHandle: 'dXNlcg',
  userName: 'octocat@example.com',
  privateKey: 'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgSECRET',
  addedAt: 1,
);
const _account = OtpAccount(id: 'a1', issuer: 'github.com', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

void main() {
  group('the passkeys setting', () {
    test('is off, and not written, until it is turned on', () {
      final untouched = Prefs.parse(
        '{"clearClipboard":true,"lastBackupAt":null,"autoLockMinutes":5,"lockOnHide":false,"accountSort":"name","backupNudgeDismissedAt":null}',
      );

      expect(untouched.passkeys, isFalse);
      expect(
        jsonEncode(untouched.toJson()),
        '{"clearClipboard":true,"lastBackupAt":null,"autoLockMinutes":5,"lockOnHide":false,"accountSort":"name","backupNudgeDismissedAt":null}',
      );
      expect(untouched.copyWith(passkeys: true).toJson()['passkeys'], isTrue);
      expect(Prefs.fromJson(untouched.copyWith(passkeys: true).toJson()).passkeys, isTrue);
    });
  });

  group('with the app', () {
    Future<TestApp> open(WidgetTester tester) async {
      final app = TestApp();
      await startApp(tester, app, overrides: [realDirectory]);
      await createVault(tester);
      await app.container.read(vaultControllerProvider.notifier).addAccount(_account);
      await app.container.read(vaultControllerProvider.notifier).addPasskeys(const [_passkey]);
      await tester.pumpAndSettle();
      return app;
    }

    String vaultId(TestApp app) => app.container.read(vaultControllerProvider).vault.id;

    /// Lets the host's write finish: it loads the 2FA directory and decrypts the inbox key for real.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pumpAndSettle();
      }
    }

    Future<void> setPrefs(WidgetTester tester, TestApp app, Prefs Function(Prefs prefs) change) async {
      app.container.read(prefsProvider.notifier).update(change);
      await settle(tester);
    }

    testWidgets('a vault that never turned passkeys on has no inbox key, and its copy no passkeys', (tester) async {
      final app = await open(tester);
      await setPrefs(tester, app, (prefs) => prefs.copyWith(autofill: true));

      expect(app.store.getItem('backmycodes_passkey_inbox'), isNull);
      expect(app.autofill.copies[vaultId(app)]!.containsKey('passkeys'), isFalse);
      expect(app.autofill.inboxKeys, isEmpty);
      expect(app.store.getItem('backmycodes_prefs'), isNot(contains('passkeys')));
    });

    testWidgets('turning passkeys on writes them, with the inbox key; the index holds no key', (tester) async {
      final app = await open(tester);

      final inbox = await tester.runAsync(() => app.container.read(vaultControllerProvider.notifier).passkeyInbox(create: true));
      await setPrefs(tester, app, (prefs) => prefs.copyWith(passkeys: true));

      final copy = app.autofill.copies[vaultId(app)]!;
      expect((copy['passkeys']! as List).single, autofillPasskey(_passkey, withKey: true));
      // Codes stay out while their own setting is off
      expect(copy['accounts'], isEmpty);
      final index = app.autofill.indexes[vaultId(app)]!;
      expect(jsonEncode(index), isNot(contains('privateKey')));
      expect(jsonEncode(index), isNot(contains(_passkey.privateKey)));
      expect((index['passkeys']! as List).single, {
        'credentialId': _passkey.credentialId,
        'rpId': 'github.com',
        'rpName': 'GitHub',
        'userHandle': 'dXNlcg',
        'userName': 'octocat@example.com',
      });
      expect(app.autofill.inboxKeys[vaultId(app)], b64(inbox!.point));
      // The inbox key is kept encrypted in the vault, and is the same next time
      expect(app.store.getItem('backmycodes_passkey_inbox'), isNotNull);
      final again = await tester.runAsync(() => app.container.read(vaultControllerProvider.notifier).passkeyInbox());
      expect(again!.point, inbox.point);
    });

    testWidgets('turning passkeys off takes them and the inbox key out of the copy', (tester) async {
      final app = await open(tester);
      await tester.runAsync(() => app.container.read(vaultControllerProvider.notifier).passkeyInbox(create: true));
      await setPrefs(tester, app, (prefs) => prefs.copyWith(passkeys: true, autofill: true));

      await setPrefs(tester, app, (prefs) => prefs.copyWith(passkeys: false));

      expect(app.autofill.copies[vaultId(app)]!.containsKey('passkeys'), isFalse);
      expect(app.autofill.inboxKeys, isEmpty);
      expect((app.autofill.copies[vaultId(app)]!['accounts']! as List), hasLength(1));
    });

    testWidgets('a hidden vault writes neither codes nor passkeys', (tester) async {
      final app = await open(tester);
      await tester.runAsync(() => app.container.read(vaultControllerProvider.notifier).passkeyInbox(create: true));
      await setPrefs(tester, app, (prefs) => prefs.copyWith(passkeys: true, autofill: true));
      expect(app.autofill.copies, isNotEmpty);

      app.vaults.setListed(vaultId(app), false);
      app.container.read(vaultControllerProvider.notifier).vaultChanged();
      await settle(tester);

      expect(app.autofill.copies, isEmpty);
      expect(app.autofill.inboxKeys, isEmpty);
    });
  });

  group('without the native side', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('passkeys read as unsupported, and the inbox as empty', () async {
      const platform = ChannelAutofillPlatform();

      expect(await platform.passkeyStatus(), PasskeyStatus.unsupported);
      expect(await platform.readInbox('main'), isEmpty);
      expect(await platform.openPasskeySettings(), isFalse);
      await platform.clearInbox('main', const ['x']);
    });

    test('the channel carries the inbox key and the inbox as the native side expects', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.kemlock.app/autofill'),
        (call) async {
          calls.add(call);
          return switch (call.method) {
            'passkeyStatus' => {'supported': true, 'enabled': true},
            'readInbox' => [
              {'name': 'a.json', 'content': '{}'},
              {'name': 7, 'content': 'skipped'},
            ],
            _ => null,
          };
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.kemlock.app/autofill'),
          null,
        ),
      );
      const platform = ChannelAutofillPlatform();
      final point = b64(newP256KeyPair().point);

      await platform.writeVault('v1', '{}', null, inboxKey: point, takes: const VaultTakes(passkeys: true, logins: true));
      expect(await platform.passkeyStatus(), const PasskeyStatus(supported: true, enabled: true));
      expect(await platform.readInbox('v1'), [(name: 'a.json', content: '{}')]);
      await platform.clearInbox('v1', const ['a.json']);

      expect(calls.first.arguments, {
        'vault': 'v1',
        'copy': '{}',
        'index': null,
        'inboxKey': point,
        'takes': {'passkeys': true, 'logins': true, 'suggest': false},
      });
      expect(calls.last.arguments, {
        'vault': 'v1',
        'names': ['a.json'],
      });
    });
  });
}
