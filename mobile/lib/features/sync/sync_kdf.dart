import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault/vault_store.dart' show DeriveKey, deriveVaultKey;

/// The scrypt a sync passphrase and an invite code go through, in a
/// background isolate, for the sync and spaces sheets. Widget tests
/// override it with a cheap one, as their fake time can't wait for an
/// isolate.
final syncDeriveKeyProvider = Provider<DeriveKey>((ref) => deriveVaultKey);
