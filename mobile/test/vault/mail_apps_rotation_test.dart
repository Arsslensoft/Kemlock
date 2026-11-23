import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import 'fast_kdf.dart';
import 'rotation_helpers.dart';

const _thunderbird = MailApp(
  package: 'net.thunderbird.android',
  cert: 'aa11',
  name: 'Thunderbird',
  allowedAt: 1794000000000,
  keys: ['k1'],
  unchecked: ['EA29C79D1C6570277907BB485D49D28C8EFC2F98'],
);

/// The approved mail apps go through a replacement of the vault's key pair
/// with the rest of its sealed values (openspec: add-pgp-mail-provider,
/// task 3.2, and replace-vault-key-pair).
void main() {
  late KeyValueStore store;
  late VaultStore vault;

  setUp(() {
    store = KeyValueStore.memory();
    vault = VaultStore(store, VaultRegistry(store), deriveKey: fastKdf, unlockKeys: FakeUnlockKeys());
  });

  test('is one of the values sealed again', () async {
    final old = await vault.setupVault('pw');
    await MailAppsStore(vault).save([_thunderbird], old);
    expect(vault.sealedValueKeys(mainVault), contains(keyMailApps));
  });

  test('reads back under the new key pair, and no longer opens with the old one', () async {
    final old = await vault.setupVault('pw');
    await fillVault(vault, store, keyFuture, old);
    await MailAppsStore(vault).save([_thunderbird], old);

    final next = await vault.replaceKeyPair(old, 'pw');

    expect(await MailAppsStore(vault).load(next), [_thunderbird]);
    expect(await MailAppsStore(vault).load(await vault.unlockAnyVault('pw', mainVault)), [_thunderbird]);
    await expectLater(openRaw(store.getItem(keyMailApps)!, old.secretKey), throwsA(isA<AesGcmAuthError>()));
    await expectEveryItem(vault, next);
  });
}
