import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/account/dedup.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/duplicates/dedup_cache.dart';
import 'package:kemlock/features/duplicates/dedup_store.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/features/duplicates/duplicate_tags.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../crypto/vectors.dart';
import '../../fakes/fake_unlock_keys.dart';
import '../../vault/fast_kdf.dart';
import '../../vault/rotation_helpers.dart';

/// A cache with a new root and one login's two tags under the dedup key that root makes.
({DedupCache cache, List<DuplicateTag> tags, List<int> dedup}) _cacheWithTags({String listHash = 'list'}) {
  final fresh = DedupCache.fresh(listHash);
  final dedup = dedupKey(fresh.root, Owner.user(fresh.rootId), 1);
  final tags = makeTags(const [
    TagInput(TagKind.cred, ['larkspur.example', 'sam', 'hunter2']),
    TagInput(TagKind.account, ['larkspur.example', 'sam']),
  ], dedup);
  final cache = DedupCache(
    root: fresh.root,
    rootId: fresh.rootId,
    listHash: listHash,
    owners: {
      vaultSlot: DedupOwnerTags(version: 1, check: b64urlEncode(dedupTag(dedup, 'check', const [])), items: {'l1': DedupItemTags(5, tags)}),
    },
  );
  return (cache: cache, tags: tags, dedup: dedup);
}

/// Every way a secret of the cache could be written down in the clear.
List<String> _spellings(List<int> bytes) => [toHex(bytes), b64(bytes), b64url(bytes), b64urlEncode(bytes), base64Url.encode(bytes)];

/// The two sealed values (openspec: the add-duplicate-cleaner plan, tasks 3.1 and 3.2).
void main() {
  late KeyValueStore store;
  late VaultRegistry vaults;
  late VaultStore vault;
  late DedupStore dedup;

  setUp(() {
    store = KeyValueStore.memory();
    vaults = VaultRegistry(store);
    vault = VaultStore(store, vaults, deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
    dedup = DedupStore(vault);
  });

  group('the cache', () {
    test('is made with a new root at the first match, and a vault that never matched holds none', () async {
      final session = await vault.setupVault('pw');
      expect(store.getItem(keyDedup), isNull);
      expect(store.getItem(keyDedupAnswers), isNull);

      final first = await dedup.loadCache(session, listHash: 'list');

      expect(first.root, hasLength(32));
      expect(isUuidText(first.rootId), isTrue);
      expect(first.owners, isEmpty);
      // Made now, not stored until something is tagged
      expect(store.getItem(keyDedup), isNull);
      expect((await dedup.loadCache(session, listHash: 'list')).root, isNot(first.root));
    });

    test('is read back as it was saved, root, tags and all', () async {
      final session = await vault.setupVault('pw');
      final made = _cacheWithTags();

      await dedup.saveCache(made.cache, session);
      final read = await dedup.loadCache(session, listHash: 'list');

      expect(read.root, made.cache.root);
      expect(read.rootId, made.cache.rootId);
      expect(read.toJson(), made.cache.toJson());
      expect(read.owners[vaultSlot]!.items['l1']!.tags, made.tags);
      expect(read.owners[vaultSlot]!.items['l1']!.at, 5);
    });

    test('is made again, with a new root, when it can’t be read', () async {
      final session = await vault.setupVault('pw');
      final made = _cacheWithTags();
      // Another vault's key pair, which this one's value can be sealed to by mistake
      final elsewhere = KeyValueStore.memory();
      final stranger = await VaultStore(
        elsewhere,
        VaultRegistry(elsewhere),
        deriveKey: fastKdf,
        unlockKeys: FakeUnlockKeys(),
      ).setupVault('other');

      for (final damage in <Future<void> Function()>[
        // Not JSON
        () async => store.setItem(keyDedup, 'not json'),
        // Sealed, but to another key pair
        () async => store.setItem(keyDedup, await sealRaw(Uint8List.fromList(utf8.encode('{}')), stranger.publicKey)),
        // Opens, but is no cache this version reads
        () => vault.saveEncryptedValue(keyDedup, {'v': 2, 'root': 'x'}, session),
        () => vault.saveEncryptedValue(keyDedup, {...made.cache.toJson(), 'root': b64urlEncode(List.filled(8, 1))}, session),
        () => vault.saveEncryptedValue(keyDedup, {...made.cache.toJson(), 'rootId': 'not a uuid'}, session),
        () => vault.saveEncryptedValue(keyDedup, {
          ...made.cache.toJson(),
          'owners': {
            vaultSlot: {
              'version': 1,
              'check': 'c',
              'items': {
                'l1': {
                  'at': 5,
                  'tags': ['cred:AAAA'],
                },
              },
            },
          },
        }, session),
      ]) {
        await dedup.saveCache(made.cache, session);
        await damage();
        final read = await dedup.loadCache(session, listHash: 'list');

        expect(read.root, isNot(made.cache.root));
        expect(read.owners, isEmpty);
      }
    });

    test('keeps its root and drops its tags when the Public Suffix List changed', () async {
      final session = await vault.setupVault('pw');
      final made = _cacheWithTags(listHash: 'old list');
      await dedup.saveCache(made.cache, session);

      final read = await dedup.loadCache(session, listHash: 'new list');

      expect(read.root, made.cache.root);
      expect(read.rootId, made.cache.rootId);
      expect(read.listHash, 'new list');
      expect(read.owners, isEmpty);
    });

    test('is dropped whole by clearCache', () async {
      final session = await vault.setupVault('pw');
      await dedup.saveCache(_cacheWithTags().cache, session);

      dedup.clearCache();

      expect(store.getItem(keyDedup), isNull);
    });
  });

  group('the answers', () {
    test('are empty at first and not stored while empty', () async {
      final session = await vault.setupVault('pw');

      expect((await dedup.loadAnswers(session)).isEmpty, isTrue);
      await dedup.saveAnswers(const DedupAnswers(), session);
      expect(store.getItem(keyDedupAnswers), isNull);
    });

    test('are read back as saved, keys of a newer version too, and removed once empty again', () async {
      final session = await vault.setupVault('pw');
      const answers = DedupAnswers(
        dismissed: [
          {
            'ids': ['a', 'b'],
          },
        ],
        merges: [
          {'kept': 'a', 'at': 1},
        ],
        extra: {'future': 1},
      );

      await dedup.saveAnswers(answers, session);
      final read = await dedup.loadAnswers(session);

      expect(read.toJson(), answers.toJson());
      expect(read.extra, {'future': 1});
      await dedup.saveAnswers(const DedupAnswers(), session);
      expect(store.getItem(keyDedupAnswers), isNull);
    });

    test('that can’t be opened throw, instead of reading as empty and being saved over', () async {
      final session = await vault.setupVault('pw');
      store.setItem(keyDedupAnswers, 'not json');

      await expectLater(dedup.loadAnswers(session), throwsA(isA<FormatException>()));
    });
  });

  group('storage', () {
    test('a locked vault holds no tag, root or key outside a sealed value', () async {
      final session = await vault.setupVault('pw');
      final made = _cacheWithTags();
      await dedup.saveCache(made.cache, session);
      await dedup.saveAnswers(
        const DedupAnswers(
          dismissed: [
            {
              'ids': ['a', 'b'],
            },
          ],
        ),
        session,
      );

      // The vault is locked: nothing but storage is left to read
      final secrets = [
        ..._spellings(made.cache.root),
        ..._spellings(made.dedup),
        for (final tag in made.tags) ..._spellings(tag.bytes),
        made.cache.rootId,
      ];
      for (final key in store.storedKeys()) {
        final raw = store.getItem(key) ?? '';
        for (final secret in secrets) {
          expect(raw, isNot(contains(secret)), reason: '$key holds $secret');
        }
      }
      // Both values are the sealed shape and nothing else
      for (final key in [keyDedup, keyDedupAnswers]) {
        expect((jsonDecode(store.getItem(key)!) as Map<String, Object?>).keys.toSet(), {'kemCT', 'nonce', 'ct'});
      }
    });

    test('both values are among those a key-pair replacement seals again, and read back under the new key pair', () async {
      final old = await vault.setupVault('pw');
      await fillVault(vault, store, keyFuture, old);
      final made = _cacheWithTags();
      const answers = DedupAnswers(
        merges: [
          {'kept': 'a', 'at': 1},
        ],
      );
      await dedup.saveCache(made.cache, old);
      await dedup.saveAnswers(answers, old);
      expect(vault.sealedValueKeys(mainVault), containsAll([keyDedup, keyDedupAnswers]));

      final next = await vault.replaceKeyPair(old, 'pw');

      expect((await dedup.loadCache(next, listHash: 'list')).toJson(), made.cache.toJson());
      expect((await dedup.loadAnswers(next)).toJson(), answers.toJson());
      for (final key in [keyDedup, keyDedupAnswers]) {
        await expectLater(openRaw(store.getItem(key)!, old.secretKey), throwsA(isA<AesGcmAuthError>()), reason: key);
      }
      await expectEveryItem(vault, next);
    });

    test('deleting the vault deletes both, and leaves another vault’s', () async {
      final session = await vault.setupVault('pw');
      await dedup.saveCache(_cacheWithTags().cache, session);
      await dedup.saveAnswers(
        const DedupAnswers(
          merges: [
            {'kept': 'a'},
          ],
        ),
        session,
      );
      final other = await vault.createVault('Work', 'work pw', listed: true);
      vaults.active = other;
      final otherSession = await vault.unlockVault('work pw');
      await dedup.saveCache(_cacheWithTags().cache, otherSession);
      await dedup.saveAnswers(
        const DedupAnswers(
          merges: [
            {'kept': 'w'},
          ],
        ),
        otherSession,
      );

      vaults.removeVaultData(mainVault);

      expect(store.getItem(keyDedup), isNull);
      expect(store.getItem(keyDedupAnswers), isNull);
      expect(store.getItem(vaults.vaultKey(keyDedup, other)), isNotNull);
      expect(store.getItem(vaults.vaultKey(keyDedupAnswers, other)), isNotNull);
    });

    test('an export holds neither value, nor a tag, nor the root', () async {
      final session = await vault.setupVault('pw');
      final made = _cacheWithTags();
      await dedup.saveCache(made.cache, session);
      await dedup.saveAnswers(
        const DedupAnswers(
          merges: [
            {'kept': 'a'},
          ],
        ),
        session,
      );
      const login = Login(id: 'l1', name: 'Larkspur', username: 'sam', password: 'hunter2', websites: ['larkspur.example'], addedAt: 5);

      final export = exportVaultPlaintext(const [], const [], logins: const [login]);

      expect(export, isNot(contains('dedup')));
      expect(export, isNot(contains(made.cache.rootId)));
      for (final secret in [..._spellings(made.cache.root), for (final tag in made.tags) ..._spellings(tag.bytes)]) {
        expect(export, isNot(contains(secret)));
      }
    });
  });
}
