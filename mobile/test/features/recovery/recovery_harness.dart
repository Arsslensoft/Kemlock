import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/vault/biometrics.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../fakes/fake_unlock_keys.dart';
import '../../helpers/test_app.dart';
import '../../vault/fast_kdf.dart';

/// Vaults on storage in memory, with cheap key derivation, for the Recovery
/// Kit's sheets to make, read and open kits on.
class RecoveryVaults {
  final KeyValueStore store = KeyValueStore.memory();
  late final VaultRegistry registry = VaultRegistry(store);

  /// No biometrics the hardware key could use, without the native side.
  final FakeUnlockKeys unlockKeys = FakeUnlockKeys(available: false);
  late final VaultStore vaults = VaultStore(store, registry, deriveKey: fastKdf, unlockKeys: unlockKeys);

  /// The vaults, and a phone without biometrics, so opening a vault offers none.
  List<Override> get overrides => [
    vaultRegistryProvider.overrideWithValue(registry),
    vaultStoreProvider.overrideWithValue(vaults),
    biometricsProvider.overrideWithValue(const _NoBiometrics()),
    unlockKeys.asOverride,
  ];
}

class _NoBiometrics implements Biometrics {
  const _NoBiometrics();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// A page with an Open button that runs [open], as Settings or the lock
/// screen opens a sheet, on [vaults]' storage. Pumps the page, then runs
/// [before] (to open the vault, say), taps Open and settles. Returns the
/// provider container.
Future<ProviderContainer> pumpLauncher(
  WidgetTester tester,
  RecoveryVaults vaults,
  Future<void> Function(BuildContext context) open, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.dark,
  Future<void> Function(ProviderContainer container)? before,
}) async {
  final container = await pumpScreen(
    tester,
    Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(onPressed: () => open(context), child: const Text('Open')),
        ),
      ),
    ),
    store: vaults.store,
    brightness: brightness,
    overrides: [...vaults.overrides, ...overrides],
  );
  if (before != null) await before(container);
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return container;
}
