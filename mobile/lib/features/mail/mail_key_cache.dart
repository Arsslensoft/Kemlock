/// The protected PGP keys opened for mail (openspec: add-pgp-mail-provider,
/// decision 13): the passphrase is asked once on the request screen, the
/// key is opened once, and the opened form is kept here, in the main
/// isolate's memory, by vault key id, for the mail requests that follow.
/// Nothing is stored. It is emptied when the vault locks or another vault
/// opens, an entry goes when its key is edited or deleted, and when no
/// approved app may use that key any more. The PGP sheets never read it:
/// they still ask at each use.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/keys/pgp.dart' as pgp;
import '../../models/vault_key.dart';
import '../../vault/vault_controller.dart';
import 'mail_apps.dart';

class MailKeyCache {
  final _opened = <String, ({String privateKey, Uint8List opened})>{};

  /// The opened form of [key], while it is the key that was opened.
  Uint8List? openedOf(VaultKey key) {
    final entry = _opened[key.id];
    return entry != null && entry.privateKey == key.privateKey ? entry.opened : null;
  }

  bool holds(String vaultKeyId) => _opened.containsKey(vaultKeyId);

  void keep(VaultKey key, Uint8List opened) => _opened[key.id] = (privateKey: key.privateKey, opened: opened);

  void clear() => _opened.clear();

  /// Drops the keys that are gone from [keys] or changed in them.
  void keepOnly(List<VaultKey> keys) {
    final current = {for (final key in keys) key.id: key.privateKey};
    _opened.removeWhere((id, entry) => current[id] != entry.privateKey);
  }

  /// Drops the keys no app of [apps] may use.
  void keepAllowed(List<MailApp> apps) {
    final allowed = {for (final app in apps) ...app.keys};
    _opened.removeWhere((id, _) => !allowed.contains(id));
  }
}

final mailKeyCacheProvider = Provider<MailKeyCache>((ref) {
  final cache = MailKeyCache();
  ref.listen(vaultControllerProvider.select((state) => state.session), (previous, next) {
    if (!identical(previous, next)) cache.clear();
  });
  ref.listen(vaultControllerProvider.select((state) => state.keys), (_, keys) => cache.keepOnly(keys));
  ref.listen(mailAppsProvider, (previous, apps) {
    // The empty list a lock or a vault's opening brings is no removal
    if (previous != null && previous.isNotEmpty) cache.keepAllowed(apps);
  });
  return cache;
});

/// Opens a protected key with its passphrase, off the UI isolate; tests
/// put their own. Throws a [pgp.PgpException].
final mailKeyOpenerProvider = Provider<Future<Uint8List> Function(Uint8List secretKey, String passphrase)>(
  (ref) =>
      (secretKey, passphrase) => Isolate.run(() => pgp.openPgpSecretKey(secretKey, passphrase)),
);
