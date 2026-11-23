/// An SSH key's fingerprint for the vault list: worked out once per key and
/// unlock, and how it is shortened to fit a row.
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../models/vault_key.dart';
import '../../vault/vault_controller.dart';

/// Works out the `SHA256:` fingerprint of a stored SSH key from its public
/// half. Tests replace it to count the hashings.
final sshFingerprintReaderProvider = Provider<String? Function(Uint8List publicKey)>((ref) => crypto.sshFingerprintOfSpki);

/// The fingerprint of the open vault's SSH key [id], as `ssh-keygen -l`
/// prints it: `SHA256:` and 43 characters of base64. It is hashed once per
/// key and unlock, not on every frame of the list: a stored key's halves
/// never change, so nothing but the key's removal makes it stale. Null for
/// a key of another kind, one that is gone, and one whose public half
/// can't be read.
final sshFingerprintProvider = Provider.family<String?, String>((ref, id) {
  final public = ref.watch(
    vaultControllerProvider.select((state) {
      final key = state.keys.firstWhereOrNull((key) => key.id == id);
      return key != null && key.kind == KeyKind.ssh ? key.publicKey : null;
    }),
  );
  if (public == null) return null;
  try {
    return ref.watch(sshFingerprintReaderProvider)(unb64(public));
  } on crypto.KeyFormatException {
    return null;
  } on FormatException {
    return null;
  }
});

/// [fingerprint] as a row of the vault list shows it: `SHA256:` with the
/// first four and the last four characters of its base64 and an ellipsis
/// between, `SHA256:41s5…AW4`-like. Anything that is not a whole `SHA256:`
/// fingerprint is given back as it is.
String shortSshFingerprint(String fingerprint) {
  const prefix = 'SHA256:';
  if (!fingerprint.startsWith(prefix)) return fingerprint;
  final digest = fingerprint.substring(prefix.length);
  if (digest.length <= 9) return fingerprint;
  return '$prefix${digest.substring(0, 4)}…${digest.substring(digest.length - 4)}';
}
