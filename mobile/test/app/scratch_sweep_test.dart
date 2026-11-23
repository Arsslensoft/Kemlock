import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/app/scratch_sweep.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/i18n/messages.dart';
import 'package:kemlock/vault/vault_controller.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../fakes/fake_unlock_keys.dart';
import '../vault/fast_kdf.dart';

/// The plain copies in the cache go whenever the vault stops being open.
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  late ProviderContainer container;
  late VaultStore vaultStore;
  var sweeps = 0;

  setUp(() async {
    sweeps = 0;
    final store = KeyValueStore.memory();
    final vaults = VaultRegistry(store);
    vaultStore = VaultStore(store, vaults, deriveKey: fastKdf);
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        messageCatalogProvider.overrideWithValue(await MessageCatalog.load()),
        vaultRegistryProvider.overrideWithValue(vaults),
        vaultStoreProvider.overrideWithValue(vaultStore),
        FakeUnlockKeys(available: false).asOverride,
        scratchSweepProvider.overrideWithValue(() async => sweeps++),
      ],
    );
    addTearDown(container.dispose);
    await container.read(vaultControllerProvider.notifier).open(await vaultStore.setupVault('pw'));
    container.read(scratchSweeperProvider);
  });

  VaultController controller() => container.read(vaultControllerProvider.notifier);

  test('an open vault is not swept under', () async {
    await controller().addBackupService('Larkspur', ['1111-2222']);
    expect(sweeps, 0);
  });

  test('locking sweeps, and opening again does not', () async {
    controller().lock();
    expect(sweeps, 1);

    await controller().open(await vaultStore.unlockVault('pw'));
    expect(container.read(vaultControllerProvider).isUnlocked, isTrue);
    expect(sweeps, 1);
  });

  test('deleting the open vault sweeps', () {
    controller().deleteVault();
    expect(container.read(vaultControllerProvider).phase, VaultPhase.setup);
    expect(sweeps, 1);
  });

  test('erasing every vault from the lock screen sweeps again', () {
    controller().lock();
    expect(sweeps, 1);

    controller().wiped();
    expect(container.read(vaultControllerProvider).phase, VaultPhase.setup);
    expect(sweeps, 2);
  });
}
