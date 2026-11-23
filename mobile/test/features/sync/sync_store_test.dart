// Sync settings and status for the open vault (syncStore.ts), as the sync
// dialogs and the scheduler use them.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../vault/fast_kdf.dart';

const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');

final settings = SyncSettings(
  personal: SyncTarget(dav: dav, file: syncFile, key: 'cGVyc29uYWwta2V5', kdf: newKdf()),
  spaces: [
    const Space(
      id: 'fam',
      name: 'Family',
      target: SyncTarget(dav: dav, file: 'backmycodes-space-fam.json', key: 'c3BhY2Uta2V5'),
      joinedAt: 1700000000000,
    ),
  ],
);

void main() {
  late KeyValueStore kv;
  late ProviderContainer container;
  late VaultSession session;

  VaultStore vault() => VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  SyncNotifier store() => container.read(syncProvider.notifier);
  SyncSnapshot snapshot() => container.read(syncProvider);

  setUp(() async {
    kv = KeyValueStore.memory();
    container = ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(kv)]);
    addTearDown(container.dispose);
    session = await vault().setupVault('pw');
  });

  test('is unloaded until the vault opens', () {
    expect(snapshot().settings, isNull);
    expect(snapshot().status, isEmpty);
    expect(snapshot().running, isFalse);
  });

  test('loads sync as off when nothing is stored', () async {
    await store().load(session);

    expect(snapshot().settings, noSync);
    expect(snapshot().settings?.toJson(), {'personal': null, 'spaces': <Object?>[]});
  });

  test('stores the settings encrypted with the vault, and reads them back', () async {
    await store().load(session);
    final withLater = SyncSettings.fromJson({...settings.toJson(), 'later': 1});
    await store().saveSettings(withLater, session);

    expect(snapshot().settings, withLater);
    final raw = kv.getItem('backmycodes_sync')!;
    expect(raw, contains('kemCT'));
    expect(raw, isNot(contains('app-pw')));
    expect(await vault().loadEncryptedValue('backmycodes_sync', session), withLater.toJson());

    store().unload();
    await store().load(session);
    expect(snapshot().settings, withLater);
    expect(snapshot().settings?.extra, {'later': 1});
  });

  test('reads settings the TypeScript app stored', () async {
    // NO_SYNC, then a space joined, as the dialogs write them
    final json = {
      'personal': null,
      'spaces': [
        {
          'id': 'fam',
          'name': 'Family',
          'target': {'dav': dav.toJson(), 'file': 'backmycodes-space-fam.json', 'key': 'c3BhY2Uta2V5'},
          'joinedAt': 1700000000000,
        },
      ],
    };
    await vault().saveEncryptedValue('backmycodes_sync', json, session);

    await store().load(session);

    expect(snapshot().settings?.personal, isNull);
    expect(snapshot().settings?.spaces.single.name, 'Family');
    expect(snapshot().settings?.toJson(), json);
  });

  test('asks for a sync once new settings are saved', () async {
    await store().load(session);
    var requests = 0;
    final stop = store().onSyncRequest(() => requests++);

    await store().saveSettings(settings, session);
    expect(requests, 1);
    store().requestSync();
    expect(requests, 2);

    stop();
    store().requestSync();
    expect(requests, 2);
  });

  test('loads when each scope last synced, without the problems of last time', () async {
    await store().saveScopeStates({
      personalScope: const ScopeState(known: ['a'], lastSyncAt: 1000),
      'fam': const ScopeState(known: []),
    }, session);

    await store().load(session);

    expect(snapshot().status, {personalScope: const ScopeStatus(lastSyncAt: 1000), 'fam': const ScopeStatus()});
    expect((await store().loadScopeStates(session))[personalScope]?.known, ['a']);
  });

  test('forgets a scope that is gone, so rejoining starts fresh', () async {
    await store().saveScopeStates({
      personalScope: const ScopeState(known: ['a'], lastSyncAt: 1000),
      'fam': const ScopeState(known: ['b'], lastSyncAt: 2000),
    }, session);
    await store().load(session);

    await store().forgetScope('fam', session);

    expect((await store().loadScopeStates(session)).keys, [personalScope]);
    expect(snapshot().status.keys, [personalScope]);
  });

  test('keeps the status of each scope and whether a sync runs', () async {
    await store().load(session);
    var changes = 0;
    container.listen(syncProvider, (_, _) => changes++);

    store().setRunning(true);
    store().setRunning(true);
    expect(snapshot().running, isTrue);
    expect(changes, 1);

    store().setScopeStatus(personalScope, const ScopeStatus(lastSyncAt: 5, problem: SyncProblem.auth));
    store().setScopeStatus('fam', const ScopeStatus(lastSyncAt: 6));
    expect(snapshot().status, {
      personalScope: const ScopeStatus(lastSyncAt: 5, problem: SyncProblem.auth),
      'fam': const ScopeStatus(lastSyncAt: 6),
    });
    expect(snapshot().settings, noSync);
  });

  test('forgets everything when the vault locks', () async {
    await store().saveSettings(settings, session);
    await store().load(session);
    store().setRunning(true);
    store().setScopeStatus(personalScope, const ScopeStatus(lastSyncAt: 5));

    store().unload();

    expect(snapshot().settings, isNull);
    expect(snapshot().status, isEmpty);
    expect(snapshot().running, isFalse);
  });

  test('drops a load that finishes after the vault locked', () async {
    await store().saveSettings(settings, session);
    final loading = store().load(session);
    store().unload();
    await loading;

    expect(snapshot().settings, isNull);
  });

  test('keeps each vault’s settings under its own keys', () async {
    container.read(vaultRegistryProvider).active = 'v2';
    await store().saveSettings(settings, session);
    await store().saveScopeStates({personalScope: const ScopeState(known: [])}, session);

    expect(kv.getItem('backmycodes_sync::v2'), isNotNull);
    expect(kv.getItem('backmycodes_sync_state::v2'), isNotNull);
    expect(kv.getItem('backmycodes_sync'), isNull);
    expect(kv.getItem('backmycodes_sync_state'), isNull);
  });

  test('reads stored state that is not what it expects as none', () async {
    await vault().saveEncryptedValue('backmycodes_sync_state', [1, 2], session);
    expect(await store().loadScopeStates(session), isEmpty);

    await vault().saveEncryptedValue('backmycodes_sync_state', {'personal': 'x', 'fam': <String, Object?>{}}, session);
    expect((await store().loadScopeStates(session)).keys, ['fam']);
  });

  test('fails to load settings it cannot decrypt', () async {
    kv.setItem('backmycodes_sync', 'not json');

    await expectLater(store().load(session), throwsA(anything));
    expect(snapshot().settings, isNull);
  });

  test('names the space an entry belongs to', () async {
    expect(container.read(spaceNameProvider('fam')), isNull);

    await store().load(session);
    await store().saveSettings(settings, session);

    expect(container.read(spaceNameProvider('fam')), 'Family');
    expect(container.read(spaceNameProvider(null)), isNull);
    expect(container.read(spaceNameProvider('')), isNull);
    expect(container.read(spaceNameProvider('gone')), isNull);
    expect(spaceName(settings, 'fam'), 'Family');
    expect(spaceName(null, 'fam'), isNull);
  });
}
