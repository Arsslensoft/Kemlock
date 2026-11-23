/// From the keys a service answered with to the keys the review shows
/// (openspec: add-key-lookup, decision 7): only a key that names the
/// searched address, with only the user IDs that name it, those still in
/// order first.
library;

import '../../../crypto/keys/keys.dart' as crypto;
import '../../keys/key_bridge.dart';
import '../../keys/key_standing.dart';
import 'wkd.dart';

/// Whether [userId] carries [address]: the address inside its `<…>`, or
/// the whole user ID when it is a bare address, equal to [address] with
/// ASCII case ignored.
bool userIdNames(String userId, String address) {
  final carried = userIdAddress(userId);
  return carried != null && asciiLowerCase(carried) == asciiLowerCase(address);
}

/// The keys of [keys], each as `readPublicKeys` gave it, that have a user
/// ID naming [address], each rebuilt with only those user IDs and checked
/// again, so a directory cannot attach "also your bank" to a key the person
/// is about to name. The rest are dropped. They come in order, then
/// expiring, then expired, then revoked, at [now]; keys of one standing
/// keep the answer's order.
Future<List<crypto.PgpPublicKey>> keysForAddress(List<crypto.PgpPublicKey> keys, String address, DateTime now) async {
  bool names(String userId) => userIdNames(userId, address);
  final kept = [
    for (final key in keys)
      if (key.info.userIds.any(names)) await crypto.keepUserIds(key, names),
  ];
  final standing = [for (final key in kept) keyStanding(key.info, now).standing.index];
  final order = List.generate(kept.length, (i) => i)
    ..sort((a, b) {
      final byStanding = standing[a].compareTo(standing[b]);
      return byStanding != 0 ? byStanding : a.compareTo(b);
    });
  return [for (final i in order) kept[i]];
}
