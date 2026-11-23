import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/account_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vaultwarden_sheet.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_security_keys.dart';
import '../features/sync/sync_screen_kit.dart';
import '../features/sync/vaultwarden/fake_vaultwarden.dart';
import '../features/sync/vaultwarden/vw_kit.dart';
import '../helpers/screenshots.dart';
import '../helpers/test_app.dart';

const _github = OtpAccount(id: 'a1', issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);
const _key = VaultKey(
  id: 'k1',
  name: 'laptop',
  kind: KeyKind.ssh,
  algorithm: 'ed25519',
  privateKey: 'MC4CAQAwBQYDK2VwBCIEINTuctv5E1hK1bbY8fdp+K06/nwoy/HU++CXqI9EdVhC',
  origin: KeyOrigin.generated,
  addedAt: 1,
);
const _note = SecureNote(id: 'n1', title: 'Travel diary', text: 'Day one', addedAt: 1);

/// Renders the Vaultwarden parts of the sync sheet and the account sheet,
/// in dark and light:
///
///     flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots/vaultwarden_test.dart
void main() {
  for (final brightness in Brightness.values) {
    final name = brightness.name;

    Future<(SyncSheetKit, FakeVaultwarden)> sheet(
      WidgetTester tester, {
      Future<void> Function(BuildContext context)? show,
      FakeSecurityKeys? phone,
    }) async {
      usePhoneScreen(tester);
      final server = FakeVaultwarden();
      await server.allowSignIn();
      final kit = SyncSheetKit(phone: phone);
      await kit.pump(
        tester,
        show ?? showSyncSheet,
        brightness: brightness,
        overrides: [
          vwClientFactoryProvider.overrideWithValue((_) => server.newClient()),
          vwKeyDerivationProvider.overrideWithValue(const CheapKeyDerivation()),
          vwCertificateProbeProvider.overrideWithValue((_) async => null),
        ],
      );
      return (kit, server);
    }

    Future<void> signIn(WidgetTester tester) async {
      await tester.tap(find.text(t('sync.where.vaultwarden')));
      await tester.pumpAndSettle();
      await tester.enterText(field(t('vaultwarden.field.server')), 'https://vault.example.com');
      await tester.enterText(field(t('vaultwarden.field.email')), 'me@example.com');
      await tester.enterText(field(t('vaultwarden.field.password')), 'master password');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.signIn'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    }

    testScreenshot('vaultwarden: signing in, $name', (tester) async {
      final (kit, _) = await sheet(tester);
      await kit.open(tester);
      await tester.tap(find.text(t('sync.where.vaultwarden')));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'vaultwarden_sign_in_$name');
    });

    testScreenshot('vaultwarden: how to keep the codes, $name', (tester) async {
      final (kit, _) = await sheet(tester);
      await kit.open(tester);
      await signIn(tester);
      await tester.tap(find.text(t('vaultwarden.storage.plain')));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'vaultwarden_storage_$name');
    });

    testScreenshot('vaultwarden: where, sealed, $name', (tester) async {
      final (kit, _) = await sheet(tester);
      await kit.open(tester);
      await signIn(tester);
      await tapButton(tester, t('vaultwarden.continue'));
      await takeScreenshot(tester, 'vaultwarden_home_$name');
    });

    testScreenshot('vaultwarden: what the first sync will do, $name', (tester) async {
      final (kit, _) = await sheet(tester);
      await kit.vault.addAccounts([_github]);
      await kit.open(tester);
      await signIn(tester);
      await tapButton(tester, t('vaultwarden.continue'));
      await tester.enterText(field(t('vaultwarden.field.passphrase')), 'a long sealing phrase');
      await tester.pump();
      await tapButton(tester, t('vaultwarden.continue'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'vaultwarden_summary_$name');
    });

    testScreenshot('vaultwarden: what the first sync will do, plain, with keys and notes, $name', (tester) async {
      final (kit, _) = await sheet(tester);
      await kit.vault.addAccounts([_github]);
      await kit.vault.addKey(_key);
      await kit.vault.addNote(_note);
      await kit.open(tester);
      await signIn(tester);
      await tester.tap(find.text(t('vaultwarden.storage.plain')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(t('vaultwarden.storage.plainAgree')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('vaultwarden.storage.plainAgree')));
      await tester.pumpAndSettle();
      await tapButton(tester, t('vaultwarden.continue'));
      await tapButton(tester, t('vaultwarden.continue'));
      await takeScreenshot(tester, 'vaultwarden_summary_plain_items_$name');
    });

    testScreenshot('vaultwarden: on, with keys waiting, a note too long and no files, $name', (tester) async {
      final (kit, server) = await sheet(tester);
      final target = await makeHome(server, VaultwardenMode.plain);
      await kit.vault.addNote(_note);
      await kit.save(SyncSettings(vaultwarden: target));
      await kit.sync.saveScopeStates({
        vaultwardenScope: ScopeState(
          known: const [],
          lastSyncAt: testNow.millisecondsSinceEpoch,
          extra: const {
            'paused': {'key': 2, 'passkey': 1},
            'tooLong': ['n1'],
            'noFiles': 'none',
          },
        ),
      }, kit.session);
      kit.sync.setScopeStatus(vaultwardenScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.open(tester);
      await takeScreenshot(tester, 'vaultwarden_on_items_$name');
    });

    testScreenshot('vaultwarden: on, and asking about removals, $name', (tester) async {
      final (kit, server) = await sheet(tester);
      final target = await makeHome(server, VaultwardenMode.sealed);
      await kit.save(SyncSettings(vaultwarden: target));
      kit.sync.setScopeStatus(vaultwardenScope, ScopeStatus(lastSyncAt: testNow.millisecondsSinceEpoch));
      await kit.open(tester);
      await takeScreenshot(tester, 'vaultwarden_on_$name');

      kit.sync.setScopeStatus(vaultwardenScope, const ScopeStatus(problem: SyncProblem.removals, count: 12));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'vaultwarden_removals_$name');
    });

    /// Opens the sheet on an Android phone, with an account whose second
    /// step is a security key registered for [domain], up to the two-step
    /// screen.
    Future<(FakeSecurityKeys, FakeFidoKey)> keyStep(WidgetTester tester, {String domain = 'https://vault.example.com'}) async {
      final phone = FakeSecurityKeys();
      final fido = FakeFidoKey()..maxCredentialCountInList = 8;
      final credential = fido.addSignInCredential(Uri.parse(domain).host);
      final (kit, server) = await sheet(tester, phone: phone);
      server
        ..domain = domain
        ..registerKey(credential.id, credential.keyPair.point);
      await kit.open(tester);
      await signIn(tester);
      return (phone, fido);
    }

    testScreenshot('vaultwarden: the security key step, $name', (tester) async {
      await keyStep(tester);
      await takeScreenshot(tester, 'vaultwarden_key_step_$name');
    });

    testScreenshot('vaultwarden: the security key step waiting for a touch, $name', (tester) async {
      final (phone, fido) = await keyStep(tester);
      // A plugged-in key that waits for its touch for as long as the picture takes
      phone.yieldOnRead = true;
      phone.arrive(
        FakeKey(
          productName: 'Example Key',
          ctap: _WaitsForTouch(fido),
          keepaliveEvery: const Duration(milliseconds: 1),
        ).device(kinds: {SecurityKeyLinkKind.usbHid}),
      );
      await tester.tap(find.widgetWithText(FilledButton, t('vaultwarden.key.use')));
      for (var i = 0; i < 400 && find.text(t('vaultwarden.key.status.touch')).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 2));
      }

      await takeScreenshot(tester, 'vaultwarden_key_touch_$name');

      await tester.tap(find.byKey(vwKeyCancelKey));
      for (var i = 0; i < 400 && find.text(t('vaultwarden.key.status.touch')).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 2));
      }
      await tester.pump(const Duration(milliseconds: 100));
    });

    testScreenshot('vaultwarden: a server set up under another address, $name', (tester) async {
      final (phone, fido) = await keyStep(tester, domain: 'https://vault.example.org');
      phone.arrive(FakeKey(productName: 'Example Key', ctap: fido).device(kinds: {SecurityKeyLinkKind.nfc}));
      await tapButton(tester, t('vaultwarden.key.use'));
      await takeScreenshot(tester, 'vaultwarden_key_other_address_$name');
    });

    testScreenshot('vaultwarden: the login a code is in, $name', (tester) async {
      final (kit, server) = await sheet(
        tester,
        show: (context) => showAccountSheet(context, account: _github, onDelete: (_) {}, onUpdate: (_) {}),
      );
      final target = await makeHome(server, VaultwardenMode.plain);
      final key = server.userKey;
      final backend = VaultwardenBackend(vault: kit.vaultStore, session: kit.session, clientFor: (_) => server.newClient());
      await backend.saveCredentials(server.credentials());
      final login = await putUserLogin(server, key, secret: 'KRSXG5CTMVRXEZLU');
      Future<void> sync() => backend.sync(
        target,
        const Lists(accounts: [_github]),
        const ScopeState(known: []),
        now: server.revision + 500,
      );
      await sync();
      // Linked as from the account sheet's "Link to a Vaultwarden login"
      await backend.link(target, _github, login['id']! as String);
      await sync();
      await kit.vault.addAccounts([_github]);
      await kit.save(SyncSettings(vaultwarden: target));
      kit.sync.setScopeStatus(vaultwardenScope, ScopeStatus(lastSyncAt: server.revision));
      await tester.pumpAndSettle();
      await kit.open(tester);
      await tester.ensureVisible(find.text(t('vaultwarden.login.title')));
      await tester.pumpAndSettle();
      await takeScreenshot(tester, 'vaultwarden_login_$name');
      await tester.pumpWidget(const SizedBox());
      kit.container.dispose();
    });
  }
}

/// A key that waits for a touch, and goes on waiting, when it is asked for
/// an assertion.
class _WaitsForTouch extends FakeCtapAuthenticator {
  _WaitsForTouch(this.inner);

  final FakeFidoKey inner;

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) =>
      command == 0x02 ? FakeCtapReply.hang(2) : inner.handle(command, parameters, kind);

  @override
  void poweredUp(DateTime Function() now) => inner.poweredUp(now);
}
