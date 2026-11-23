// Linking an account's code to the user's own Vaultwarden login and back,
// and the account sheet's part: the login's details, its password only on
// request, and deleting the account.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/lock/key_reader.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vaultwarden_sheet.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/links.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/vault/key_unlock.dart';

import '../../../helpers/test_app.dart';
import '../../../vault/rotation_helpers.dart' show newKit;
import '../sync_screen_kit.dart';
import 'fake_vaultwarden.dart';
import 'vw_kit.dart';

const _secret = 'JBSWY3DPEHPK3PXP';

OtpAccount _account() => const OtpAccount(id: 'a1', issuer: 'GitHub', label: 'me@example.com', secret: _secret, addedAt: 1);

/// The user's own GitHub login, with a password and a website.
Future<String> _userLogin(FakeVaultwarden server, {int reprompt = 0}) async {
  final key = server.userKey;
  final cipher = server.put({
    'type': 1,
    'name': await bwEncryptString('GitHub', key),
    'reprompt': reprompt,
    'login': {
      'username': await bwEncryptString('octocat', key),
      'password': await bwEncryptString('hunter2', key),
      'uris': [
        {'uri': await bwEncryptString('https://github.com', key), 'match': null},
      ],
    },
  });
  return cipher['id']! as String;
}

/// Stands in for the browser: keeps the links opened.
class _Links implements LinkLauncher {
  final opened = <Uri>[];

  @override
  Future<bool> launch(Uri url) async {
    opened.add(url);
    return true;
  }
}

void main() {
  test("links to an item in the web vault, under the server's path too", () {
    expect(vwWebVaultItem('https://vault.example.com', 'c1'), Uri.parse('https://vault.example.com/#/vault?itemId=c1'));
    expect(vwWebVaultItem('https://home.example.com:8443/vw/', 'c1'), Uri.parse('https://home.example.com:8443/vw/#/vault?itemId=c1'));
  });

  group('the backend', () {
    late FakeVaultwarden server;
    late SyncSheetKit kit;
    late VaultwardenBackend backend;
    late VaultwardenTarget target;

    Future<void> setUpBackend(WidgetTester tester) async {
      server = FakeVaultwarden();
      target = await makeHome(server, VaultwardenMode.plain);
      kit = SyncSheetKit();
      await kit.pump(tester, (_) async {});
      backend = VaultwardenBackend(vault: kit.vaultStore, session: kit.session, clientFor: (_) => server.newClient());
      await backend.saveCredentials(server.credentials());
    }

    Future<Lists> sync(Lists local) async {
      final result = await backend.sync(target, local, const ScopeState(known: []), now: server.revision + 500);
      return result.doc;
    }

    testWidgets('links a code to the user login and back', (tester) async {
      await setUpBackend(tester);
      final login = await _userLogin(server);
      await sync(Lists(accounts: [_account()]));
      // Kemlock made its own GitHub login first
      expect(server.ciphers.values.where((c) => c['type'] == 1 && c['deletedDate'] == null), hasLength(2));

      final choices = await backend.loginsToLink(target);
      expect(choices.single.cipherId, login, reason: "Kemlock's own login isn't offered");
      expect((choices.single.name, choices.single.username, choices.single.website), ('GitHub', 'octocat', 'https://github.com'));

      await backend.link(target, _account(), login);
      final doc = await sync(Lists(accounts: [_account()]));
      expect(doc.accounts.single.id, 'a1');
      expect(server.ciphers.values.where((c) => c['type'] == 1 && c['deletedDate'] == null).map((c) => c['id']), [login]);

      final linked = await backend.linkedLogin('a1');
      expect((linked!.name, linked.username, linked.website, linked.hasPassword), ('GitHub', 'octocat', 'https://github.com', true));
      expect(await linked.password(), 'hunter2');

      await backend.unlink(target, _account());
      await sync(Lists(accounts: [_account()]));
      expect(await backend.linkedLogin('a1'), isNull);
      final user = server.ciphers[login]!;
      expect((user['login']! as Map<String, Object?>)['totp'], isNull);
      expect(await bwDecryptString((user['login']! as Map<String, Object?>)['password']! as String, server.userKey), 'hunter2');
      final names = [
        for (final cipher in server.ciphers.values)
          if (cipher['deletedDate'] == null && cipher['type'] == 1) await bwDecryptString(cipher['name']! as String, server.userKey),
      ];
      expect(names, ['GitHub', 'GitHub'], reason: 'the user login, and a new one of Kemlock\'s');
    });
  });

  group('the account sheet', () {
    // The sheet's code ticks every second; take the screen away so the test ends with no timer running
    Future<void> leave(WidgetTester tester, SyncSheetKit kit) async {
      await tester.pumpWidget(const SizedBox());
      kit.container.dispose();
    }

    Future<(SyncSheetKit, FakeVaultwarden, List<String>)> open(
      WidgetTester tester, {
      int reprompt = 0,
      LinkLauncher? links,
      List<Override> extra = const [],
    }) async {
      final server = FakeVaultwarden();
      final target = await makeHome(server, VaultwardenMode.plain);
      final login = await _userLogin(server, reprompt: reprompt);
      final deleted = <String>[];
      final kit = SyncSheetKit();
      await kit.pump(
        tester,
        (context) => showAccountSheet(context, account: _account(), onDelete: deleted.add, onUpdate: (_) {}),
        overrides: [
          vwClientFactoryProvider.overrideWithValue((_) => server.newClient()),
          vwKeyDerivationProvider.overrideWithValue(const CheapKeyDerivation()),
          if (links != null) linkLauncherProvider.overrideWithValue(links),
          ...extra,
        ],
      );
      final backend = VaultwardenBackend(vault: kit.vaultStore, session: kit.session, clientFor: (_) => server.newClient());
      await backend.saveCredentials(server.credentials());
      await backend.link(target, _account(), login);
      await backend.sync(
        target,
        Lists(accounts: [_account()]),
        const ScopeState(known: []),
        now: server.revision + 500,
      );
      await kit.vault.addAccounts([_account()]);
      await kit.save(SyncSettings(vaultwarden: target));
      kit.sync.setScopeStatus(vaultwardenScope, ScopeStatus(lastSyncAt: server.revision));
      await tester.pumpAndSettle();
      await kit.open(tester);
      return (kit, server, deleted);
    }

    testWidgets('shows the login, and its password only when asked', (tester) async {
      final (kit, _, _) = await open(tester);

      expect(find.text(t('vaultwarden.login.title')), findsOneWidget);
      expect(find.text('octocat'), findsOneWidget);
      expect(find.text('https://github.com'), findsOneWidget);
      expect(find.text('hunter2'), findsNothing);

      await tester.ensureVisible(find.byTooltip(t('vaultwarden.login.show')));
      await tester.tap(find.byTooltip(t('vaultwarden.login.show')));
      await tester.pumpAndSettle();
      expect(find.text('hunter2'), findsOneWidget);
      await leave(tester, kit);
    });

    testWidgets('opens the login in the web vault', (tester) async {
      final links = _Links();
      final (kit, server, _) = await open(tester, links: links);
      final login = server.ciphers.values.singleWhere((cipher) => cipher['type'] == 1 && cipher['deletedDate'] == null);

      await tester.ensureVisible(find.text(t('vaultwarden.login.open')));
      await tester.tap(find.text(t('vaultwarden.login.open')));
      await tester.pumpAndSettle();
      expect(links.opened, [Uri.parse('https://vault.example.com/#/vault?itemId=${login['id']}')]);
      await leave(tester, kit);
    });

    testWidgets("asks for the vault's password when the login re-prompts", (tester) async {
      final (kit, _, _) = await open(tester, reprompt: 1);

      await tester.ensureVisible(find.byTooltip(t('vaultwarden.login.show')));
      await tester.tap(find.byTooltip(t('vaultwarden.login.show')));
      await tester.pumpAndSettle();
      expect(find.text(t('vaultwarden.login.reprompt')), findsOneWidget);
      await tester.enterText(field(t('unlock.field.password')), 'pw');
      await tapButton(tester, t('vaultwarden.continue'));
      expect(find.text('hunter2'), findsOneWidget);
      await leave(tester, kit);
    });

    // openspec: add-security-key-unlock, task 6.7
    for (final mode in [UnlockMode.both, UnlockMode.key]) {
      testWidgets('asks a vault that opens with ${mode.name} for what opens it when the login re-prompts', (tester) async {
        final key = _GivenKey();
        final (kit, _, _) = await open(tester, reprompt: 1, extra: [keyReaderProvider.overrideWithValue(key)]);
        await tester.runAsync(() async {
          final store = kit.vaultStore;
          await store.setRecoveryKey(kit.session, newKit());
          final proof = await store.enrolKey(
            kit.session,
            await store.proveOwner(password: 'pw'),
            salt: store.keyChallenge().salt,
            credential: key.credential,
            output: key.output,
            name: 'Example Key',
            pinBound: true,
          );
          await store.setUnlockMode(kit.session, proof, mode);
        });

        await tester.ensureVisible(find.byTooltip(t('vaultwarden.login.show')));
        await tester.tap(find.byTooltip(t('vaultwarden.login.show')));
        await tester.pumpAndSettle();
        if (mode == UnlockMode.both) {
          await tester.enterText(field(t('unlock.field.password')), 'pw');
          await tapButton(tester, t('vaultwarden.continue'));
        } else {
          expect(find.text(t('vaultwarden.login.reprompt')), findsNothing);
        }
        expect(find.text(t('unlockMethod.prove.key.title')), findsOneWidget);
        await tester.enterText(field(t('lock.key.pin')), '123456');
        await tapButton(tester, t('lock.key.read'));

        expect(key.reads, 1);
        expect(find.text('hunter2'), findsOneWidget);
        await leave(tester, kit);
      });
    }

    testWidgets('says the code also leaves the login before deleting the account', (tester) async {
      final (kit, _, deleted) = await open(tester);

      await tapButton(tester, t('accountCard.tooltip.remove'));
      expect(find.text(t('vaultwarden.deleteLinked', {'name': 'GitHub'})), findsOneWidget);
      await tapButton(tester, t('changePw.cancel'));
      expect(deleted, isEmpty);

      await tapButton(tester, t('accountCard.tooltip.remove'));
      final confirm = find.text(t('accountCard.tooltip.remove')).last;
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(deleted, ['a1']);
      await leave(tester, kit);
    });

    // openspec: add-offline-mode, "Sync is paused"
    testWidgets('while offline mode is on it still shows the login, says sync is paused and cannot unlink', (tester) async {
      final (kit, server, _) = await open(tester);
      await kit.setOffline(tester, true);
      server.requests.clear();

      expect(find.text('octocat'), findsOneWidget);
      expect(find.text(t('sync.offline')), findsOneWidget);
      expect(button(tester, t('vaultwarden.unlink')).onPressed, isNull);
      expect(server.requests, isEmpty);
      await leave(tester, kit);
    });
  });
}

/// A security key that gives the same reading whatever is asked of it.
class _GivenKey implements KeyReader {
  final credential = randomBytes(64);
  final output = randomBytes(32);
  var reads = 0;

  @override
  Future<SecurityKeyCapabilities> capabilities() async => const SecurityKeyCapabilities(nfc: true, nfcOn: true, usb: true);

  @override
  final ValueNotifier<KeyReadStage> stage = ValueNotifier(KeyReadStage.idle);

  @override
  bool get coveredBySystem => false;

  @override
  Future<void> cancel() async {}

  @override
  Future<KeyEnrolment> enrol({
    required Uint8List pin,
    required Uint8List salt,
    required List<Uint8List> exclude,
    required KeyPrompts prompts,
    bool lastTryConfirmed = false,
  }) => throw UnimplementedError();

  @override
  Future<KeyOutput> read({
    required Uint8List pin,
    required Uint8List salt,
    required List<Uint8List> allow,
    required KeyPrompts prompts,
    bool lastTryConfirmed = false,
  }) async {
    reads++;
    return KeyOutput(credential: Uint8List.fromList(credential), output: Uint8List.fromList(output));
  }
}
