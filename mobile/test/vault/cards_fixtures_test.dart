// The fixtures of test/fixtures/cards, written once by
// cards_fixtures_generator_test.dart for the add-cards-identities-and-websites
// plan and never regenerated: this version must open them and keep every card
// and identity in them. A fixture that hasn't been generated yet skips its
// tests, and says so.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/vault/vault_export.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../compat/before_cards/export_payload.dart';
import '../compat/before_cards/sync_merge.dart' as before_cards;
import '../fakes/fake_unlock_keys.dart';
import 'cards_fixture_inputs.dart';

typedef _Json = Map<String, Object?>;

File _file(String name) => File('test/fixtures/cards/$name');

String? _missing(String name) => _file(name).existsSync() ? null : '$name is written by the generator in the single pass after merging';

List<_Json> _cards(List<PaymentCard> cards) => [for (final card in cards) card.toJson()];

List<_Json> _identities(List<Identity> identities) => [for (final identity in identities) identity.toJson()];

final _allCards = [cardsFixtureVisa, cardsFixtureMinimal, cardsFixtureShared];
final _allIdentities = [cardsFixtureMe, cardsFixtureWork, cardsFixtureFamily];

void main() {
  group('the exports', () {
    const encrypted = 'export-with-cards.json';
    const plain = 'export-with-cards-plain.json';

    test('the encrypted one opens with its password, every card and identity as written', () async {
      final payload = await importVault(_file(encrypted).readAsStringSync(), cardsFixturePassword);

      expect(_cards(payload.cards), _cards(_allCards));
      expect(_identities(payload.identities), _identities(_allIdentities));
      expect(payload.cards.first.extra['later'], {'what': 'a key a later version writes', 'kept': true});
      expect(payload.identities.first.documents!.last.type, 'residencePermit');
      expect(payload.accounts.single.id, cardsFixtureAccount.id);
    }, skip: _missing(encrypted));

    test('the plain one reads the same, and a phone from before cards reads its codes and logins', () {
      final text = _file(plain).readAsStringSync();

      expect(_cards(importVaultPlaintext(text).cards), _cards(_allCards));
      expect(_identities(importVaultPlaintext(text).identities), _identities(_allIdentities));
      expect(payloadBeforeCards(jsonDecode(text) as _Json).accounts.single.id, cardsFixtureAccount.id);
    }, skip: _missing(plain));
  });

  group('the sync files', () {
    const name = 'sync-with-cards.json';
    final skip = _missing(name);
    late _Json fixture;
    if (skip == null) fixture = jsonDecode(_file(name).readAsStringSync()) as _Json;

    Future<SyncDoc> open(String which) {
      final part = fixture[which]! as _Json;
      return decryptSyncFile(part['file']! as String, unb64(part['key']! as String));
    }

    test('open with their keys, every card, identity and the deletion as written', () async {
      final own = await open('own');
      expect(_cards(own.cards), _cards([cardsFixtureVisa, cardsFixtureMinimal]));
      expect(_identities(own.identities), _identities([cardsFixtureMe, cardsFixtureWork]));
      expect(own.deleted.single.toJson(), cardsFixtureDeleted);
      expect(own.extra, isEmpty);

      final space = await open('space');
      expect(_cards(space.cards), _cards([cardsFixtureShared]));
      expect(_identities(space.identities), _identities([cardsFixtureFamily]));
      expect(space.cards.single.spaceId, 'fam');
    }, skip: skip);

    test('this version keeps every card and identity through a merge', () async {
      final own = await open('own');

      final merged = mergeScope(
        const Lists(accounts: [cardsFixtureAccount]),
        [cardsFixtureAccount.id],
        own,
        now: cardsFixtureWrittenAt.millisecondsSinceEpoch,
      );

      expect(_cards(merged.doc.cards), _cards([cardsFixtureVisa, cardsFixtureMinimal]), reason: 'by id, as the merge sorts them');
      expect(_identities(merged.doc.identities), _identities([cardsFixtureMe, cardsFixtureWork]));
      expect(merged.doc.deleted.map((tomb) => tomb.id), [cardsFixtureDeleted['id']]);
    }, skip: skip);

    test('a phone from before cards writes them back as they were', () async {
      final plain = jsonDecode(jsonEncode((await open('own')).toJson())) as _Json;
      final remote = before_cards.SyncDoc.fromJson(plain);

      final merged = before_cards.mergeScope(
        before_cards.Lists(accounts: const [cardsFixtureAccount]),
        [cardsFixtureAccount.id],
        remote,
        now: cardsFixtureWrittenAt.millisecondsSinceEpoch,
      );

      final written = jsonDecode(jsonEncode(merged.doc.toJson())) as _Json;
      expect(written['cards'], plain['cards']);
      expect(written['identities'], plain['identities']);
      expect(written['deleted'], plain['deleted']);
    }, skip: skip);
  });

  group('the vault', () {
    const name = 'vault-with-cards.json';
    final skip = _missing(name);
    late _Json fixture;
    if (skip == null) fixture = jsonDecode(_file(name).readAsStringSync()) as _Json;

    ({KeyValueStore store, VaultStore vault}) phone() {
      final store = KeyValueStore.memory((fixture['storage']! as _Json).cast<String, String>());
      return (store: store, vault: VaultStore(store, VaultRegistry(store), unlockKeys: FakeUnlockKeys()));
    }

    test('opens with its password, its cards and identities as written', () async {
      final (store: _, :vault) = phone();

      final session = await vault.unlockAnyVault(cardsFixturePassword, mainVault);

      expect(_cards(await vault.loadCards(session)), _cards(_allCards));
      expect(_identities(await vault.loadIdentities(session)), _identities(_allIdentities));
      expect((await vault.loadCards(session)).first.extra['later'], {'what': 'a key a later version writes', 'kept': true});
      expect((await vault.loadIdentities(session)).first.documents!.last.type, 'residencePermit');
    }, skip: skip);

    test('has its key replaced with its cards and identities intact', () async {
      final (:store, :vault) = phone();
      final old = await vault.unlockAnyVault(cardsFixturePassword, mainVault);
      final before = (store.getItem('backmycodes_card_data'), store.getItem('backmycodes_identity_data'));

      final next = await vault.replaceKeyPair(old, cardsFixturePassword);

      expect(store.getItem('backmycodes_card_data'), isNot(before.$1), reason: 'sealed again to the new pair');
      expect(store.getItem('backmycodes_identity_data'), isNot(before.$2), reason: 'sealed again to the new pair');
      expect(_cards(await vault.loadCards(next)), _cards(_allCards));
      expect(_identities(await vault.loadIdentities(next)), _identities(_allIdentities));
    }, skip: skip);
  });
}
