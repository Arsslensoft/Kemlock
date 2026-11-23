import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';

/// A `keyUnlock` no version reads: a version number from the future and
/// members whose JSON a careless rewrite would change.
const _unknown = r'{"v":99,"mode":"later","salt":"AAAA","keys":[{"id":"00ff","name":"café","n":1.0}],"more":{"a":[1,2,3]}}';

// openspec: add-security-key-unlock, task 1.2. The config's writers spread
// the config they read, so a key they do not know is kept as it is.
void main() {
  late KeyValueStore store;
  late VaultStore vault;
  late VaultSession session;

  /// The stored config's text, with `keyUnlock` put in after its last member.
  void plant() {
    final raw = store.getItem(keyConfig)!;
    store.setItem(keyConfig, '${raw.substring(0, raw.length - 1)},"keyUnlock":$_unknown}');
  }

  setUp(() async {
    store = KeyValueStore.memory();
    vault = VaultStore(store, VaultRegistry(store), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
    session = await vault.setupVault('pw');
    plant();
  });

  void expectKept() {
    final raw = store.getItem(keyConfig)!;
    expect(raw, contains('"keyUnlock":$_unknown'));
    expect(jsonEncode((jsonDecode(raw) as Map<String, Object?>)['keyUnlock']), _unknown);
  }

  RecoveryKey kit(String id) =>
      RecoveryKey(kitId: id, key: Uint8List.fromList(List.filled(32, 7)), threshold: 1, shares: 1, createdAt: '2026-11-16T00:00:00.000Z');

  test('changing the password keeps an unknown keyUnlock', () async {
    await vault.changePassword(session, 'another password');
    expectKept();
    expect((await vault.unlockVault('another password')).secretKey, session.secretKey);
  });

  test('renaming the vault keeps it', () {
    vault.renameVault(mainVault, 'Personal');
    expectKept();
    vault.renameVault(mainVault, '');
    expectKept();
  });

  test('making and deleting a Recovery Kit keep it', () async {
    await vault.setRecoveryKey(session, kit('kit-1'));
    expectKept();
    vault.removeRecoveryKey();
    expectKept();
  });

  test('replacing the key pair keeps it, with a new kit and without one', () async {
    final next = await vault.replaceKeyPair(session, 'pw');
    expectKept();
    await vault.setRecoveryKey(next, kit('kit-1'));
    final third = await vault.replaceKeyPair(next, 'pw', kit: kit('kit-2'));
    expectKept();
    await vault.replaceKeyPair(third, 'pw', dropKit: true);
    expectKept();
  });
}
