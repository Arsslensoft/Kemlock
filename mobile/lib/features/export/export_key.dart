import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault/vault_store.dart';

/// The key an export password gives: scrypt with the vault's parameters, off
/// the UI isolate. The export and import sheets take it from here, so tests
/// can swap in a cheap one, as a widget test's fake time can't wait for an
/// isolate.
final exportDeriveKeyProvider = Provider<DeriveKey>((ref) => deriveVaultKey);
