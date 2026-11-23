import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/autofill_host.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/logins/login_inbox.dart';
import 'package:kemlock/features/passkeys/passkey_inbox.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/platform/autofill.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_autofill.dart';
import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/app_harness.dart' show FakeBiometrics;
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';
import '../backup/backup_test_kit.dart' show realDirectory;

class _FlakyStore extends VaultStore {
  _FlakyStore(super.store, super.vaults) : super(deriveKey: fastKdf);

  bool failSaves = false;

  @override
  Future<void> saveLogins(List<Login> logins, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.saveLogins(logins, session);
}

LoginInboxRecord _saved(String password, {String id = 'p1', String site = 'larkspur.example', int at = 1763200000000}) =>
    LoginInboxRecord.login(id: id, name: 'Larkspur', username: 'ada@example.org', password: password, site: site, at: at);

// openspec: add-passwords, task 4.5
void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;
  late _FlakyStore vaultStore;
  late FakeAutofill autofill;
  late ProviderContainer container;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  /// The autofill host over an open vault whose passwords are on, saving
  /// included, with its inbox key.
  Future<P256KeyPair> open(WidgetTester tester) async {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vaultStore = _FlakyStore(store, vaults);
    autofill = FakeAutofill();
    container = await pumpScreen(
      tester,
      const AutofillHost(child: Scaffold(body: SizedBox())),
      store: store,
      overrides: [
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        biometricsProvider.overrideWithValue(FakeBiometrics(available: false)),
        FakeUnlockKeys(available: false).asOverride,
        autofill.asOverride,
        realDirectory,
      ],
    );
    final session = (await tester.runAsync(() => vaultStore.setupVault('pw')))!;
    await tester.runAsync(() => container.read(vaultControllerProvider.notifier).open(session));
    final inbox = (await tester.runAsync(() => container.read(vaultControllerProvider.notifier).passkeyInbox(create: true)))!;
    container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passwords: true));
    await settle(tester);
    return inbox;
  }

  String vaultId() => container.read(vaultControllerProvider).vault.id;
  List<Login> logins() => container.read(vaultControllerProvider).logins;
  VaultController controller() => container.read(vaultControllerProvider.notifier);
  String? toast() => container.read(toastsProvider)?.message;

  Future<void> putInbox(WidgetTester tester, P256KeyPair inbox, String name, LoginInboxRecord record) async {
    final file = (await tester.runAsync(() => sealLoginRecord(record, inbox.point)))!;
    (autofill.inbox[vaultId()] ??= {})[name] = file;
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
  }

  testWidgets('takes a login saved while the vault was locked, writes the copy, then clears the inbox', (tester) async {
    final inbox = await open(tester);
    expect(autofill.takes[vaultId()], const VaultTakes(logins: true, suggest: true));
    await putInbox(tester, inbox, 'login-a.json', _saved('first'));

    await resume(tester);

    expect(logins().single.id, 'p1');
    expect(logins().single.source, Login.fromAutofill);
    expect(autofill.inbox[vaultId()], isEmpty);
    final copied = (autofill.copies[vaultId()]!['logins']! as List).cast<Map<String, Object?>>();
    expect(copied.single['password'], 'first');
    final calls = autofill.calls;
    expect(calls.lastIndexWhere((call) => call.startsWith('write')), lessThan(calls.indexWhere((call) => call.startsWith('clearInbox'))));
    expect(toast(), t('logins.inbox.added', {'count': 1}));
  });

  testWidgets('updates the password of a login the vault holds, and says so', (tester) async {
    final inbox = await open(tester);
    await tester.runAsync(
      () => controller().addLogin(
        const Login(id: 'l1', name: 'Larkspur', username: 'ada@example.org', password: 'old', websites: ['larkspur.example'], addedAt: 0),
      ),
    );
    await putInbox(tester, inbox, 'login-a.json', _saved('new'));

    await resume(tester);

    expect(logins().single.id, 'l1');
    expect(logins().single.password, 'new');
    expect(logins().single.previousPasswords!.single.password, 'old');
    expect(toast(), t('logins.inbox.updated', {'count': 1}));
  });

  testWidgets('keeps a generated password no save followed, without a toast', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'login-g.json', const LoginInboxRecord.generated(password: 'Xk9-generated', site: 'news.example', at: 7));

    await resume(tester);

    expect(container.read(vaultControllerProvider).generated.single.password, 'Xk9-generated');
    expect(logins(), isEmpty);
    expect(autofill.inbox[vaultId()], isEmpty);
    expect(toast(), isNull);
  });

  testWidgets('takes passkeys and logins from the same inbox', (tester) async {
    final inbox = await open(tester);
    container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passkeys: true));
    await settle(tester);
    await putInbox(tester, inbox, 'login-a.json', _saved('first'));
    final passkey = InboxRecord(
      credentialId: 'cred-a',
      rpId: 'github.com',
      userHandle: 'dXNlcg',
      userName: 'octocat@example.com',
      privateKey: b64(newP256KeyPair().toPkcs8()),
      createdAt: 1763200000000,
    );
    (autofill.inbox[vaultId()]!)['a.json'] = (await tester.runAsync(() => sealInboxRecord(passkey, inbox.point)))!;

    await resume(tester);

    expect(logins(), hasLength(1));
    expect(container.read(vaultControllerProvider).passkeys.single.credentialId, 'cred-a');
    expect(autofill.inbox[vaultId()], isEmpty);
  });

  testWidgets('a failed save clears nothing, and the next try takes the login once', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'login-a.json', _saved('first'));
    vaultStore.failSaves = true;

    await resume(tester);

    expect(logins(), isEmpty);
    expect(autofill.inbox[vaultId()]!.keys, ['login-a.json']);

    vaultStore.failSaves = false;
    await resume(tester);
    await resume(tester);
    expect(logins(), hasLength(1));
    expect(autofill.inbox[vaultId()], isEmpty);
  });

  testWidgets('a login file another key sealed is left where it is', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, newP256KeyPair(), 'login-x.json', _saved('stranger', id: 'px'));
    await putInbox(tester, inbox, 'login-a.json', _saved('first'));

    await resume(tester);

    expect(logins().single.id, 'p1');
    expect(autofill.inbox[vaultId()]!.keys, ['login-x.json']);
  });

  testWidgets('turning saving off drains first, then takes the inbox key out of the copy', (tester) async {
    final inbox = await open(tester);
    expect(autofill.inboxKeys[vaultId()], b64(inbox.point));
    await putInbox(tester, inbox, 'login-late.json', _saved('late'));

    container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passwordSaving: false));
    await settle(tester);

    expect(logins().single.password, 'late');
    expect(autofill.inbox[vaultId()] ?? const {}, isEmpty);
    expect(autofill.inboxKeys, isEmpty);
    expect(autofill.takes[vaultId()], const VaultTakes(suggest: true));
  });
}
