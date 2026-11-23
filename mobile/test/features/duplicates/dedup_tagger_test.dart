import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/account/dedup.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/legacy_ids.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/duplicates/dedup_cache.dart';
import 'package:kemlock/features/duplicates/dedup_store.dart';
import 'package:kemlock/features/duplicates/dedup_tagger.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/features/duplicates/duplicate_tags.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../vault/fast_kdf.dart';

const _spaceId = 'team_Alpha-01';
final _spaceKey = List<int>.generate(32, (i) => 200 - i);

Login _login(String id, {String password = 'hunter2', String username = 'sam', int at = 1, String? spaceId}) => Login(
  id: id,
  name: 'Login $id',
  username: username,
  password: password,
  websites: const ['larkspur.example'],
  spaceId: spaceId,
  addedAt: at,
);

Space _space({String id = _spaceId, List<int>? key}) => Space(
  id: id,
  name: 'Team',
  target: SyncTarget(
    dav: const DavAccount(url: 'https://dav.example.com/files/me/Shared/', username: 'me', password: 'pw'),
    file: 'backmycodes-space-$id.json',
    key: b64(key ?? _spaceKey),
  ),
  joinedAt: 0,
);

/// The groups of items that share a tag, each as its sorted ids joined by commas, and the groups sorted:
/// what a matcher would find, in a form that doesn't depend on the order tags were made in.
List<String> _groups(Map<String, Map<String, DedupItemTags>> tags) {
  final byTag = <DuplicateTag, Set<String>>{};
  for (final MapEntry(key: slot, value: items) in tags.entries) {
    for (final MapEntry(key: id, value: item) in items.entries) {
      for (final tag in item.tags) {
        byTag.putIfAbsent(tag, () => {}).add('$slot/$id');
      }
    }
  }
  return {
    for (final ids in byTag.values)
      if (ids.length > 1) (ids.toList()..sort()).join(','),
  }.toList()..sort();
}

DedupItemTags _tagsOf(Map<String, Map<String, DedupItemTags>> tags, String slot, String id) => tags[slot]![id]!;

/// Tags kept current by change time (the add-duplicate-cleaner plan, task 3.2).
void main() {
  group('refreshTags', () {
    test('tags each item once, and not again until its change time moves', () {
      final cache = DedupCache.fresh('list');
      final items = dedupItems(
        logins: [
          _login('a'),
          _login('b', username: 'other'),
        ],
      );

      final first = refreshTags(cache, items, dedupOwners(cache, const []));
      final again = refreshTags(first.cache, items, dedupOwners(first.cache, const []));

      expect(first.changed, isTrue);
      expect(first.cache.owners[vaultSlot]!.items.keys, {'a', 'b'});
      expect(again.changed, isFalse);
      expect(again.cache.toJson(), first.cache.toJson());
    });

    test('makes new cred tags for an edited password, and keeps the account tag', () {
      final cache = DedupCache.fresh('list');
      final before = refreshTags(cache, dedupItems(logins: [_login('a')]), dedupOwners(cache, const []));

      final after = refreshTags(
        before.cache,
        dedupItems(logins: [_login('a', password: 'correct horse', at: 2)]),
        dedupOwners(before.cache, const []),
      );

      final oldTags = before.cache.owners[vaultSlot]!.items['a']!.tags;
      final newTags = after.cache.owners[vaultSlot]!.items['a']!.tags;
      expect(after.changed, isTrue);
      expect(newTags.map((tag) => tag.kind), [TagKind.cred, TagKind.account]);
      expect(newTags[0], isNot(oldTags[0]));
      expect(newTags[1], oldTags[1]);
    });

    test('drops the tags of an item that is gone', () {
      final cache = DedupCache.fresh('list');
      final before = refreshTags(cache, dedupItems(logins: [_login('a'), _login('b')]), dedupOwners(cache, const []));

      final after = refreshTags(before.cache, dedupItems(logins: [_login('a')]), dedupOwners(before.cache, const []));

      expect(after.changed, isTrue);
      expect(after.cache.owners[vaultSlot]!.items.keys, {'a'});
    });

    test('tags the vault’s items under the root and a space’s under its own key, with their own owner bytes', () {
      final cache = DedupCache.fresh('list');
      final items = dedupItems(
        logins: [
          _login('v'),
          _login('s', spaceId: _spaceId),
        ],
      );
      final owners = dedupOwners(cache, [(id: _spaceId, key: Uint8List.fromList(_spaceKey))]);

      final result = refreshTags(cache, items, owners);

      final vaultKey = dedupKey(cache.root, Owner(OwnerType.user, uuidBytes(cache.rootId)), 1);
      final spaceKey = dedupKey(_spaceKey, Owner.space(spaceUuid(_spaceId)), 1);
      final vaultCred = result.cache.owners[vaultSlot]!.items['v']!.tags.first;
      final spaceCred = result.cache.owners[spaceSlot(_spaceId)]!.items['s']!.tags.first;
      expect(vaultCred.bytes, dedupTag(vaultKey, 'cred', ['larkspur.example', 'sam', 'hunter2']));
      expect(spaceCred.bytes, dedupTag(spaceKey, 'cred', ['larkspur.example', 'sam', 'hunter2']));
      // One login in the vault and in a space gives different tags
      expect(vaultCred, isNot(spaceCred));
      expect(Owner(OwnerType.user, uuidBytes(cache.rootId)).bytes.first, 1);
      expect(Owner.space(spaceUuid(_spaceId)).bytes.first, 2);
    });

    test('drops an owner that is gone, which is what leaving a space is, and tags nothing in it', () {
      final cache = DedupCache.fresh('list');
      final items = dedupItems(
        logins: [
          _login('v'),
          _login('s', spaceId: _spaceId),
        ],
      );
      final inSpace = refreshTags(cache, items, dedupOwners(cache, [(id: _spaceId, key: Uint8List.fromList(_spaceKey))]));
      expect(inSpace.cache.owners.keys, {vaultSlot, spaceSlot(_spaceId)});

      final left = refreshTags(inSpace.cache, items, dedupOwners(inSpace.cache, const []));

      expect(left.changed, isTrue);
      expect(left.cache.owners.keys, {vaultSlot});
      expect(left.cache.owners[vaultSlot]!.items.keys, {'v'});
    });

    test('makes an owner’s tags again when its key changes, and when its version does', () {
      final cache = DedupCache.fresh('list');
      final items = dedupItems(logins: [_login('s', spaceId: _spaceId)]);
      final first = refreshTags(cache, items, dedupOwners(cache, [(id: _spaceId, key: Uint8List.fromList(_spaceKey))]));
      final oldTag = first.cache.owners[spaceSlot(_spaceId)]!.items['s']!.tags.first;

      final newKey = List<int>.generate(32, (i) => i);
      final rekeyed = refreshTags(first.cache, items, dedupOwners(first.cache, [(id: _spaceId, key: Uint8List.fromList(newKey))]));
      final newTag = rekeyed.cache.owners[spaceSlot(_spaceId)]!.items['s']!.tags.first;

      expect(rekeyed.changed, isTrue);
      expect(newTag, isNot(oldTag));
      expect(newTag.bytes, dedupTag(dedupKey(newKey, Owner.space(spaceUuid(_spaceId)), 1), 'cred', ['larkspur.example', 'sam', 'hunter2']));

      final owners = dedupOwners(rekeyed.cache, [(id: _spaceId, key: Uint8List.fromList(newKey))]);
      final bumped = refreshTags(rekeyed.cache, items, [
        for (final owner in owners) DedupOwner(slot: owner.slot, owner: owner.owner, key: owner.key, version: 2),
      ]);
      expect(bumped.changed, isTrue);
      expect(bumped.cache.owners[spaceSlot(_spaceId)]!.version, 2);
      expect(bumped.cache.owners[spaceSlot(_spaceId)]!.items['s']!.tags.first, isNot(newTag));
    });

    test('tags nothing in a space with no key, or with an id no UUID can stand for', () {
      final cache = DedupCache.fresh('list');
      final items = dedupItems(
        logins: [
          _login('s', spaceId: _spaceId),
          _login('t', spaceId: 'not an id!'),
        ],
      );

      final result = refreshTags(cache, items, dedupOwners(cache, [(id: 'not an id!', key: Uint8List.fromList(_spaceKey))]));

      expect(result.cache.owners.keys, {vaultSlot});
      expect(result.cache.owners[vaultSlot]!.items, isEmpty);
    });

    test('a fresh cache gives the same groups as the one it replaces', () {
      final items = dedupItems(
        logins: [
          _login('a'),
          _login('b', at: 2),
          _login('c', username: 'other'),
        ],
        accounts: const [
          OtpAccount(id: 'x', issuer: 'Google', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1),
          OtpAccount(id: 'y', issuer: 'google.com', label: 'me', secret: 'jbsw y3dp ehpk 3pxp', addedAt: 1),
        ],
      );
      Map<String, Map<String, DedupItemTags>> tagsOf(DedupCache cache) => {
        for (final MapEntry(:key, :value) in refreshTags(cache, items, dedupOwners(cache, const [])).cache.owners.entries) key: value.items,
      };

      final first = DedupCache.fresh('list');
      final second = DedupCache.fresh('list');

      expect(second.root, isNot(first.root));
      expect(_groups(tagsOf(second)), _groups(tagsOf(first)));
      expect(_groups(tagsOf(first)), ['vault/a,vault/b', 'vault/x,vault/y']);
    });
  });

  group('DedupStore.refresh', () {
    late KeyValueStore store;
    late VaultStore vault;
    late DedupStore dedup;

    setUp(() {
      store = KeyValueStore.memory();
      vault = VaultStore(store, VaultRegistry(store), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
      dedup = DedupStore(vault);
    });

    test('makes the root and saves the tags at the first match, and writes nothing when nothing changed', () async {
      final session = await vault.setupVault('pw');
      final items = dedupItems(logins: [_login('a'), _login('b')]);

      final first = await dedup.refresh(session, items: items, spaces: const [], listHash: 'list');
      final saved = store.getItem(keyDedup);
      final again = await dedup.refresh(session, items: items, spaces: const [], listHash: 'list');

      expect(saved, isNotNull);
      expect(store.getItem(keyDedup), saved);
      expect(_groups(first), ['vault/a,vault/b']);
      expect(_groups(again), _groups(first));
    });

    test('gives new cred tags for an edited password, kept across a cache read', () async {
      final session = await vault.setupVault('pw');
      final first = await dedup.refresh(
        session,
        items: dedupItems(logins: [_login('a')]),
        spaces: const [],
        listHash: 'list',
      );

      final second = await dedup.refresh(
        session,
        items: dedupItems(logins: [_login('a', password: 'new password', at: 2)]),
        spaces: const [],
        listHash: 'list',
      );

      final oldTags = _tagsOf(first, vaultSlot, 'a').tags;
      final newTags = _tagsOf(second, vaultSlot, 'a').tags;
      expect(newTags[0], isNot(oldTags[0]));
      expect(newTags[1], oldTags[1]);
      expect(_tagsOf(second, vaultSlot, 'a').at, 2);
    });

    test('drops a space’s tags when the vault leaves it, and uses the space’s own key', () async {
      final session = await vault.setupVault('pw');
      final items = dedupItems(
        logins: [
          _login('v'),
          _login('s', spaceId: _spaceId),
        ],
      );

      final inSpace = await dedup.refresh(session, items: items, spaces: [_space()], listHash: 'list');
      final spaceKey = dedupKey(_spaceKey, Owner.space(spaceUuid(_spaceId)), 1);
      expect(
        _tagsOf(inSpace, spaceSlot(_spaceId), 's').tags.first.bytes,
        dedupTag(spaceKey, 'cred', ['larkspur.example', 'sam', 'hunter2']),
      );

      final left = await dedup.refresh(
        session,
        items: dedupItems(logins: [_login('v')]),
        spaces: const [],
        listHash: 'list',
      );

      expect(left.keys, [vaultSlot]);
      final stored = await dedup.loadCache(session, listHash: 'list');
      expect(stored.owners.keys, [vaultSlot]);
    });

    test('a cleared cache gives the same groups, from a new root', () async {
      final session = await vault.setupVault('pw');
      final items = dedupItems(
        logins: [
          _login('a'),
          _login('b', at: 2),
          _login('c', username: 'other'),
        ],
      );
      final first = await dedup.refresh(session, items: items, spaces: const [], listHash: 'list');
      final root = (await dedup.loadCache(session, listHash: 'list')).root;

      dedup.clearCache();
      final second = await dedup.refresh(session, items: items, spaces: const [], listHash: 'list');

      expect((await dedup.loadCache(session, listHash: 'list')).root, isNot(root));
      expect(_tagsOf(second, vaultSlot, 'a').tags, isNot(_tagsOf(first, vaultSlot, 'a').tags));
      expect(_groups(second), _groups(first));
    });

    test('makes every tag again when the Public Suffix List changed, under the same root', () async {
      final session = await vault.setupVault('pw');
      final items = dedupItems(logins: [_login('a')]);
      await dedup.refresh(session, items: items, spaces: const [], listHash: 'old');
      final root = (await dedup.loadCache(session, listHash: 'old')).root;

      await dedup.refresh(session, items: items, spaces: const [], listHash: 'new');

      final stored = await dedup.loadCache(session, listHash: 'new');
      expect(stored.root, root);
      expect(stored.listHash, 'new');
      expect(stored.owners[vaultSlot]!.items.keys, {'a'});
    });
  });
}
