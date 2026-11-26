// The owner a vault's item ids are made for (docs/crypto.md, "Item bodies", `links`). A link names the lower-case UUID of
// the linked item, which for an entry whose id is not a UUID depends on its owner: the person's Kemlock Server account for
// an entry of the vault's own, the space for an entry of a space. The vault knows its account only when it syncs to a
// Kemlock Server; without one the owner is null, and the core leaves an entry with no item id alone.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/account/encoding.dart' show MalformedException, Owner;
import '../sync/kemlock/km_models.dart' show KemlockTarget;
import '../sync/sync_store.dart' show syncProvider;

/// The user owner of the Kemlock Server account [target] signs in to; null without a target, or for an account id that
/// is not a UUID.
Owner? linkOwnerOf(KemlockTarget? target) {
  if (target == null) {
    return null;
  }
  try {
    return Owner.user(target.accountId);
  } on MalformedException {
    return null;
  }
}

/// The open vault's Kemlock Server account owner, for `account:` of the core's link functions; null when the vault does not
/// sync to a server.
final linkAccountProvider = Provider<Owner?>((ref) => linkOwnerOf(ref.watch(syncProvider.select((sync) => sync.settings?.kemlock))));
