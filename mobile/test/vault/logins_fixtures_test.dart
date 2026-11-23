// The fixtures of test/fixtures/logins, written once when logins joined the
// vault, its exports and sync (openspec: add-passwords, task 7.7), and never
// regenerated: this version, and the versions from before logins, must open
// them and keep every login in them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../compat/before_logins/export_payload.dart';
import '../compat/before_logins/sync_merge.dart' as before_logins;
import '../fakes/fake_unlock_keys.dart';
import 'logins_fixture_inputs.dart';

typedef _Json = Map<String, Object?>;

String _read(String name) => File('test/fixtures/logins/$name').readAsStringSync();

List<_Json> _json(List<Login> logins) => [for (final login in logins) login.toJson()];

final _all = [loginsFixtureMail, loginsFixtureApp, loginsFixtureShared];

void main() {
  group('the exports', () {
    test('the encrypted one opens with its password, every login as it was written', () async {
      final payload = await importVault(_read('export-with-logins.json'), loginsFixturePassword);

      expect(_json(payload.logins), _json(_all));
      expect(payload.logins.first.extra['later'], {'what': 'a key a later version writes', 'kept': true});
      expect(payload.accounts.single.id, loginsFixtureAccount.id);
    });

    test('the plain one reads the same, and a phone from before logins reads its codes', () {
      final text = _read('export-with-logins-plain.json');

      expect(_json(importVaultPlaintext(text).logins), _json(_all));
      expect(payloadBeforeLogins(jsonDecode(text) as _Json).accounts.single.id, loginsFixtureAccount.id);
    });
  });

  group('the sync files', () {
    final fixture = jsonDecode(_read('sync-with-logins.json')) as _Json;
    Future<SyncDoc> open(String which) {
      final part = fixture[which]! as _Json;
      return decryptSyncFile(part['file']! as String, unb64(part['key']! as String));
    }

    test('open with their keys, every login and the deletion as written', () async {
      final own = await open('own');
      expect(_json(own.logins), _json([loginsFixtureMail, loginsFixtureApp]));
      expect(own.deleted.single.toJson(), loginsFixtureDeleted);
      expect(own.extra, isEmpty);

      final space = await open('space');
      expect(_json(space.logins), _json([loginsFixtureShared]));
      expect(space.logins.single.spaceId, 'fam');
    });

    test('this version keeps every login and the deletion through a merge', () async {
      final own = await open('own');

      final merged = mergeScope(
        const Lists(accounts: [loginsFixtureAccount]),
        [loginsFixtureAccount.id],
        own,
        now: loginsFixtureWrittenAt.millisecondsSinceEpoch,
      );

      expect(_json(merged.doc.logins), _json([loginsFixtureApp, loginsFixtureMail]), reason: 'by id, as the merge sorts them');
      expect(merged.doc.deleted.map((tomb) => tomb.id), [loginsFixtureDeleted['id']]);
    });

    test('a phone from before logins writes them back as they were', () async {
      final plain = jsonDecode(jsonEncode((await open('own')).toJson())) as _Json;
      final remote = before_logins.SyncDoc.fromJson(plain);

      final merged = before_logins.mergeScope(
        before_logins.Lists(accounts: const [loginsFixtureAccount]),
        [loginsFixtureAccount.id],
        remote,
        now: loginsFixtureWrittenAt.millisecondsSinceEpoch,
      );

      final written = jsonDecode(jsonEncode(merged.doc.toJson())) as _Json;
      expect(written['logins'], plain['logins']);
      expect(written['deleted'], plain['deleted']);
    });
  });

  group('the vault', () {
    final fixture = jsonDecode(_read('vault-with-logins.json')) as _Json;
    ({KeyValueStore store, VaultStore vault}) phone() {
      final store = KeyValueStore.memory((fixture['storage']! as _Json).cast<String, String>());
      return (store: store, vault: VaultStore(store, VaultRegistry(store), unlockKeys: FakeUnlockKeys()));
    }

    test('opens with its password, its logins and generated password as written', () async {
      final (store: _, :vault) = phone();

      final session = await vault.unlockAnyVault(loginsFixturePassword, mainVault);

      expect(_json(await vault.loadLogins(session)), _json(_all));
      expect(await vault.loadGenerated(session), [loginsFixtureGenerated]);
    });

    test('has its key replaced with its logins intact', () async {
      final (:store, :vault) = phone();
      final old = await vault.unlockAnyVault(loginsFixturePassword, mainVault);
      final before = store.getItem('backmycodes_login_data');

      final next = await vault.replaceKeyPair(old, loginsFixturePassword);

      expect(store.getItem('backmycodes_login_data'), isNot(before), reason: 'sealed again to the new pair');
      expect(_json(await vault.loadLogins(next)), _json(_all));
      expect(await vault.loadGenerated(next), [loginsFixtureGenerated]);
    });
  });
}
