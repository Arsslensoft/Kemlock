import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/autofill_host.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/core/toasts.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/passkeys/passkey_inbox.dart';
import 'package:kemlock/features/settings/prefs.dart';
import 'package:kemlock/models/passkey.dart';
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
  Future<void> savePasskeys(List<Passkey> passkeys, VaultSession session) =>
      failSaves ? Future.error(Exception('disk full')) : super.savePasskeys(passkeys, session);
}

InboxRecord _record(String credentialId, {String rpId = 'github.com'}) => InboxRecord(
  credentialId: credentialId,
  rpId: rpId,
  userHandle: 'dXNlcg',
  userName: 'octocat@example.com',
  privateKey: b64(newP256KeyPair().toPkcs8()),
  createdAt: 1763200000000,
);

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

  /// The autofill host over an open vault whose passkeys are on, with its inbox key.
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
        // No biometrics the hardware key could use, without the native side
        FakeUnlockKeys(available: false).asOverride,
        autofill.asOverride,
        realDirectory,
      ],
    );
    final session = (await tester.runAsync(() => vaultStore.setupVault('pw')))!;
    await tester.runAsync(() => container.read(vaultControllerProvider.notifier).open(session));
    final inbox = (await tester.runAsync(() => container.read(vaultControllerProvider.notifier).passkeyInbox(create: true)))!;
    container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passkeys: true));
    await settle(tester);
    return inbox;
  }

  String vaultId() => container.read(vaultControllerProvider).vault.id;
  List<Passkey> passkeys() => container.read(vaultControllerProvider).passkeys;

  Future<void> putInbox(WidgetTester tester, P256KeyPair inbox, String name, InboxRecord record) async {
    final file = (await tester.runAsync(() => sealInboxRecord(record, inbox.point)))!;
    (autofill.inbox[vaultId()] ??= {})[name] = file;
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
  }

  testWidgets('takes the passkeys made while the vault was locked, writes the copy, then clears the inbox', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'a.json', _record('cred-a'));
    await putInbox(tester, inbox, 'b.json', _record('cred-b', rpId: 'gitlab.com'));

    await resume(tester);

    expect(passkeys().map((passkey) => passkey.credentialId).toSet(), {'cred-a', 'cred-b'});
    expect(autofill.inbox[vaultId()], isEmpty);
    expect((autofill.copies[vaultId()]!['passkeys']! as List).length, 2);
    // The copy was written before the files went
    final calls = autofill.calls;
    expect(calls.lastIndexWhere((call) => call.startsWith('write')), lessThan(calls.indexWhere((call) => call.startsWith('clearInbox'))));
    expect(container.read(toastsProvider)?.message, t('passkeys.inbox.added', {'count': 2}));
  });

  testWidgets('a vault opened again drains its inbox at unlock', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'a.json', _record('cred-a'));
    final session = container.read(vaultControllerProvider).session!;

    container.read(vaultControllerProvider.notifier).lock();
    await tester.runAsync(() => container.read(vaultControllerProvider.notifier).open(session));
    await settle(tester);

    expect(passkeys().single.credentialId, 'cred-a');
    expect(autofill.inbox[vaultId()], isEmpty);
  });

  testWidgets('draining twice adds nothing twice', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'a.json', _record('cred-a'));
    await resume(tester);

    // The same passkey again, as if the phone hadn't deleted its file
    await putInbox(tester, inbox, 'a-again.json', _record('cred-a'));
    await resume(tester);

    expect(passkeys(), hasLength(1));
    expect(autofill.inbox[vaultId()], isEmpty);
  });

  testWidgets('a failed save clears nothing, and the next try takes the passkey', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'a.json', _record('cred-a'));
    vaultStore.failSaves = true;

    await resume(tester);

    expect(passkeys(), isEmpty);
    expect(autofill.inbox[vaultId()]!.keys, ['a.json']);

    vaultStore.failSaves = false;
    await resume(tester);
    expect(passkeys().single.credentialId, 'cred-a');
    expect(autofill.inbox[vaultId()], isEmpty);
  });

  testWidgets('a file another key sealed is left where it is', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, newP256KeyPair(), 'stranger.json', _record('cred-x'));
    await putInbox(tester, inbox, 'a.json', _record('cred-a'));

    await resume(tester);

    expect(passkeys().single.credentialId, 'cred-a');
    expect(autofill.inbox[vaultId()]!.keys, ['stranger.json']);
  });

  testWidgets('turning passkeys off drains first, then takes them and the inbox key out of the copy', (tester) async {
    final inbox = await open(tester);
    expect(autofill.inboxKeys[vaultId()], b64(inbox.point));
    await putInbox(tester, inbox, 'late.json', _record('cred-late'));

    container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passkeys: false));
    await settle(tester);

    expect(passkeys().single.credentialId, 'cred-late');
    expect(autofill.inbox[vaultId()] ?? const {}, isEmpty);
    expect(autofill.inboxKeys, isEmpty);
    expect(autofill.copies.containsKey(vaultId()), isFalse, reason: 'codes are off too, so the copy goes');
  });

  testWidgets('hiding the vault drains its inbox first, then takes it off the phone', (tester) async {
    final inbox = await open(tester);
    await putInbox(tester, inbox, 'late.json', _record('cred-late'));

    vaults.setListed(vaultId(), false);
    container.read(vaultControllerProvider.notifier).vaultChanged();
    await settle(tester);

    expect(passkeys().single.credentialId, 'cred-late');
    expect(autofill.inbox[vaultId()] ?? const {}, isEmpty);
    expect(autofill.inboxKeys, isEmpty);
    expect(autofill.copies.containsKey(vaultId()), isFalse);
  });

  testWidgets('a vault whose passkeys are off leaves its inbox alone', (tester) async {
    final inbox = await open(tester);
    container.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(passkeys: false));
    await settle(tester);
    await putInbox(tester, inbox, 'a.json', _record('cred-a'));

    await resume(tester);

    expect(passkeys(), isEmpty);
    expect(jsonEncode(autofill.inbox[vaultId()]!.keys.toList()), '["a.json"]');
  });

  // openspec: replace-vault-key-pair, task 4.2
  group('once the vault key is replaced', () {
    Future<void> replaceKey(WidgetTester tester) async {
      var done = false;
      unawaited(container.read(vaultControllerProvider.notifier).replaceKey('pw').then((_) => done = true));
      for (var i = 0; i < 40 && !done; i++) {
        await settle(tester);
      }
      expect(done, isTrue);
      await settle(tester);
    }

    Future<P256KeyPair?> previous(WidgetTester tester) async =>
        tester.runAsync<P256KeyPair?>(() => container.read(vaultControllerProvider.notifier).previousPasskeyInbox());

    testWidgets('hands the phone the new inbox key, and takes a passkey that waited under the old one', (tester) async {
      final old = await open(tester);
      await putInbox(tester, old, 'a.json', _record('cred-a'));

      await replaceKey(tester);

      final current = (await tester.runAsync(() => container.read(vaultControllerProvider.notifier).passkeyInbox()))!;
      expect(current.point, isNot(old.point));
      expect(autofill.inboxKeys[vaultId()], b64(current.point));
      expect(passkeys().map((passkey) => passkey.credentialId), ['cred-a']);
      expect(autofill.inbox[vaultId()], isEmpty);
    });

    testWidgets('takes a passkey made under the new key, and forgets the old key once none waits under it', (tester) async {
      final old = await open(tester);
      await putInbox(tester, old, 'a.json', _record('cred-a'));
      await replaceKey(tester);
      // The old key opened a file at the drain after the replacement, so it is kept until the next one
      expect(await previous(tester), isNotNull);
      final current = (await tester.runAsync(() => container.read(vaultControllerProvider.notifier).passkeyInbox()))!;
      await putInbox(tester, current, 'b.json', _record('cred-b', rpId: 'gitlab.com'));

      await resume(tester);

      expect(passkeys().map((passkey) => passkey.credentialId).toSet(), {'cred-a', 'cred-b'});
      expect(await previous(tester), isNull);
    });

    testWidgets('forgets the old key at once when nothing waits under it', (tester) async {
      await open(tester);

      await replaceKey(tester);

      expect(await previous(tester), isNull);
      expect(await tester.runAsync(() => container.read(vaultControllerProvider.notifier).passkeyInbox()), isNotNull);
    });

    testWidgets('leaves a file neither key opens where it is', (tester) async {
      await open(tester);
      await putInbox(tester, newP256KeyPair(), 'other.json', _record('cred-x'));

      await replaceKey(tester);

      expect(passkeys(), isEmpty);
      expect(autofill.inbox[vaultId()]!.keys, ['other.json']);
    });
  });
}
