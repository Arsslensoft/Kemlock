import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../platform/unlock_keys.dart';
import 'biometrics.dart';
import 'vault_registry.dart';
import 'vault_store.dart';

/// The vaults on this device and which one is active.
final vaultRegistryProvider = Provider<VaultRegistry>((ref) => VaultRegistry(ref.watch(keyValueStoreProvider)));

/// The vault registry, rebuilding the calling provider whenever another
/// vault becomes the active one, so it reads that vault's keys.
///
/// ```dart
/// final notesProvider = Provider<String?>((ref) {
///   final key = watchActiveVault(ref).vaultKey('backmycodes_notes');
///   watchKeys(ref, [key]);
///   return ref.watch(keyValueStoreProvider).getItem(key);
/// });
/// ```
VaultRegistry watchActiveVault(Ref ref) {
  final vaults = ref.watch(vaultRegistryProvider);
  ref.onDispose(vaults.listen(ref.invalidateSelf));
  return vaults;
}

/// The vault's store, on the app's storage and registry and the phone's
/// hardware keys. Tests override it with one that derives keys cheaply.
final vaultStoreProvider = Provider<VaultStore>(
  (ref) => VaultStore(
    ref.watch(keyValueStoreProvider),
    ref.watch(vaultRegistryProvider),
    unlockKeys: ref.watch(unlockKeysProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// The system's biometric prompt. Tests override it with a fake.
final biometricsProvider = Provider<Biometrics>((ref) => LocalAuthBiometrics());
