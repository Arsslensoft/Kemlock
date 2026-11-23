import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';

/// The vault of test/fixtures/vault-items/card-key-vault.json, which holds a
/// card key (openspec: add-openpgp-card) and is never regenerated.
final _fixture = jsonDecode(File('test/fixtures/vault-items/card-key-vault.json').readAsStringSync()) as Map<String, Object?>;

({KeyValueStore store, VaultStore vault}) _phone() {
  final store = KeyValueStore.memory((_fixture['storage']! as Map<String, Object?>).cast<String, String>());
  return (store: store, vault: VaultStore(store, VaultRegistry(store), unlockKeys: FakeUnlockKeys()));
}

String get _password => _fixture['password']! as String;

Map<String, Object?> get _key => _fixture['key']! as Map<String, Object?>;

void _expectCardKey(List<VaultKey> keys) {
  final key = keys.single;
  expect(key.toJson(), _key, reason: 'byte for byte what was written');
  expect(key.isOnCard, isTrue);
  expect(key.card!['aid'], 'D276000124010304FFFF123456780000');
  expect(key.extra, isEmpty);
  final info = readPgpKeyInfo(unb64(key.privateKey));
  expect(info.protected, isTrue, reason: 'the stub holds no secret');
  expect(info.primary.fingerprintHex, (key.card!['slots']! as Map<String, Object?>)['sig']);
}

void main() {
  test('opens with its password, its card key as it was written', () async {
    final (store: _, :vault) = _phone();

    final session = await vault.unlockAnyVault(_password, mainVault);

    _expectCardKey(await vault.loadKeys(session));
  });

  test('has its key replaced with the card key intact', () async {
    final (:store, :vault) = _phone();
    final old = await vault.unlockAnyVault(_password, mainVault);
    final before = store.getItem('backmycodes_key_data');

    final next = await vault.replaceKeyPair(old, _password);

    expect(store.getItem('backmycodes_key_data'), isNot(before), reason: 'sealed again to the new pair');
    _expectCardKey(await vault.loadKeys(next));
    _expectCardKey(await vault.loadKeys(await vault.unlockAnyVault(_password, mainVault)));
  });
}
