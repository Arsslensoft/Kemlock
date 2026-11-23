import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'rotation_helpers.dart' show newKit, openRaw;

/// A fixture of test/fixtures/vault/rotation, as it was written and frozen.
class _Fixture {
  _Fixture(String name) : json = jsonDecode(File('test/fixtures/vault/rotation/$name').readAsStringSync()) as Map<String, Object?>;

  final Map<String, Object?> json;

  String get password => json['password']! as String;
  Map<String, Object?> get _kit => json['kit']! as Map<String, Object?>;
  String get kitId => _kit['kitId']! as String;
  Uint8List get kitKey => unb64(_kit['key']! as String);
  Map<String, Object?> get values => json['values']! as Map<String, Object?>;
  String get futureKey => (json['future']! as Map<String, Object?>)['key']! as String;
  String get futurePlain => (json['future']! as Map<String, Object?>)['plain']! as String;

  /// A phone holding the fixture's storage, with the real scrypt parameters.
  ({KeyValueStore store, VaultStore vault}) phone() {
    final store = KeyValueStore.memory((json['storage']! as Map<String, Object?>).cast<String, String>());
    return (store: store, vault: VaultStore(store, VaultRegistry(store), unlockKeys: FakeUnlockKeys()));
  }
}

/// Every value the fixture says the vault holds reads back in [session], the
/// newer version's byte for byte, and the item lists parse.
Future<void> _expectValues(_Fixture fixture, KeyValueStore store, VaultStore vault, VaultSession session) async {
  for (final MapEntry(:key, :value) in fixture.values.entries) {
    expect(await vault.loadEncryptedValue(key, session), value, reason: key);
  }
  expect(utf8.decode(await openRaw(store.getItem(fixture.futureKey)!, session.secretKey)), fixture.futurePlain);
  expect(await vault.loadAccounts(session), hasLength(1));
  expect(await vault.loadBackupServices(session), hasLength(1));
  expect(await vault.loadNotes(session), hasLength(1));
  expect(await vault.loadKeys(session), hasLength(1));
  expect(await vault.loadPasskeys(session), hasLength(1));
}

/// No sealed value of the vault opens with [old].
Future<void> _expectNoneOpens(KeyValueStore store, VaultStore vault, Uint8List old) async {
  for (final key in vault.sealedValueKeys(mainVault)) {
    await expectLater(openRaw(store.getItem(key)!, old), throwsA(isA<AesGcmAuthError>()), reason: key);
  }
}

/// The fixtures of a key replacement (openspec: replace-vault-key-pair,
/// task 7.1), which were written once and are never regenerated.
void main() {
  group('before.json', () {
    final fixture = _Fixture('before.json');

    test('opens with its password, every value as written, and is known to be exposed', () async {
      final (:store, :vault) = fixture.phone();

      final session = await vault.unlockAnyVault(fixture.password, mainVault);

      await _expectValues(fixture, store, vault, session);
      expect(await vault.loadKeyInfo(session), const KeyInfo(exposed: true, asked: false));
    });

    test('opens with its Recovery Kit', () async {
      final (:store, :vault) = fixture.phone();

      final session = await vault.unlockWithRecoveryKey(fixture.kitId, fixture.kitKey);

      await _expectValues(fixture, store, vault, session);
    });

    test('has its key replaced, with a new kit, every value kept and the old key opening nothing', () async {
      final (:store, :vault) = fixture.phone();
      final old = await vault.unlockAnyVault(fixture.password, mainVault);
      final kit = newKit(threshold: 2, shares: 3);

      final next = await vault.replaceKeyPair(old, fixture.password, kit: kit);

      expect(store.getItem(keyKeyRotation), isNull);
      expect(store.getItem(keyNativeBio), isNull);
      await _expectValues(fixture, store, vault, next);
      await _expectNoneOpens(store, vault, old.secretKey);
      expect((await vault.unlockAnyVault(fixture.password, mainVault)).secretKey, next.secretKey);
      await expectLater(vault.unlockWithRecoveryKey(fixture.kitId, fixture.kitKey), throwsA(isA<KitNotFoundError>()));
      expect((await vault.unlockWithRecoveryKey(kit.kitId, kit.key)).secretKey, next.secretKey);
    });
  });

  group('after-commit.json', () {
    final fixture = _Fixture('after-commit.json');
    final oldKit = fixture.json['oldKit']! as Map<String, Object?>;

    test('opens with its password, which finishes the replacement', () async {
      final (:store, :vault) = fixture.phone();
      final previous = await _previousKey(fixture);

      final session = await vault.unlockAnyVault(fixture.password, mainVault);

      expect(store.getItem(keyKeyRotation), isNull);
      await _expectValues(fixture, store, vault, session);
      await _expectNoneOpens(store, vault, previous);
      expect((await vault.loadRecoveryKey(session))?.kitId, fixture.kitId);
    });

    test('opens with the new kit, which finishes it too, and not with the old one', () async {
      final (:store, :vault) = fixture.phone();
      await expectLater(
        vault.unlockWithRecoveryKey(oldKit['kitId']! as String, unb64(oldKit['key']! as String)),
        throwsA(isA<KitNotFoundError>()),
      );

      final session = await vault.unlockWithRecoveryKey(fixture.kitId, fixture.kitKey);

      expect(store.getItem(keyKeyRotation), isNull);
      await _expectValues(fixture, store, vault, session);
    });

    test('loads every value before the replacement is finished, by the previous key where needed', () async {
      final (:store, :vault) = fixture.phone();
      // Opening the config alone, without what an unlock does after
      final session = await vault.unlockVault(fixture.password);

      expect(store.getItem(keyKeyRotation), isNotNull);
      for (final MapEntry(:key, :value) in fixture.values.entries) {
        expect(await vault.loadEncryptedValue(key, session), value, reason: key);
      }
    });
  });
}

/// The private key after-commit.json's vault had before its replacement, from
/// before.json, which is the same vault before it.
Future<Uint8List> _previousKey(_Fixture afterCommit) async {
  final (store: _, :vault) = _Fixture('before.json').phone();
  return (await vault.unlockVault(afterCommit.password)).secretKey;
}
