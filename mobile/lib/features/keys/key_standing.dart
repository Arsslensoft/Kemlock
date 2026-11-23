/// Whether a PGP key may still be used: in order, expiring soon, expired or
/// revoked (openspec: add-key-expiry-warnings). It is worked out from the
/// key's own self-signatures and the clock each time it is asked for, and
/// never stored: it changes with the date, and a stored copy would go stale.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../models/vault_key.dart';
import '../../vault/vault_controller.dart';

/// A key is expiring soon when it expires in this long or less.
const expiringSoonWithin = Duration(days: 30);

/// What a key's expiry and revocation come to.
enum Standing {
  /// No expiry, or one further away than [expiringSoonWithin].
  ok,
  expiringSoon,
  expired,

  /// The key revoked itself. It wins over the others.
  revoked;

  /// Whether the key can no longer be used.
  bool get isOver => this == expired || this == revoked;
}

/// The standing of a PGP key, or of one of its subkeys.
@immutable
class KeyStanding {
  const KeyStanding({required this.standing, this.expires, this.daysLeft, this.subkeys = const []});

  /// In order, with no expiry: what a key that can't be read is given, and
  /// a key of a kind that has no expiry.
  static const ok = KeyStanding(standing: Standing.ok);

  final Standing standing;

  /// When the key expires or expired; null if never.
  final DateTime? expires;

  /// The calendar days from today to the day it expires, in the time zone
  /// of the clock asked: 0 on its last day. Null without an expiry ahead.
  final int? daysLeft;

  /// The standing of each subkey, in the key's order. Empty for a subkey.
  final List<KeyStanding> subkeys;

  /// What is wrong with a subkey of a key that is itself still usable:
  /// [Standing.revoked] or [Standing.expired], or null when no subkey is
  /// either. Such a key's row has no tag; its sheet explains.
  Standing? get subkeyProblem {
    if (standing.isOver) return null;
    if (subkeys.any((subkey) => subkey.standing == Standing.expired)) return Standing.expired;
    if (subkeys.any((subkey) => subkey.standing == Standing.revoked)) return Standing.revoked;
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is KeyStanding &&
      other.standing == standing &&
      other.expires == expires &&
      other.daysLeft == daysLeft &&
      const ListEquality<KeyStanding>().equals(other.subkeys, subkeys);

  @override
  int get hashCode => Object.hash(standing, expires, daysLeft, const ListEquality<KeyStanding>().hash(subkeys));

  @override
  String toString() => 'KeyStanding(${standing.name}, expires: $expires, daysLeft: $daysLeft, subkeys: $subkeys)';
}

/// The standing of the key [info] describes at [now], from its primary
/// key's revocation and expiry, with the same for each subkey. A key that
/// could not be read ([info] null) is in order: it is listed as before.
///
/// The days left are counted on the calendar of [now]: local days for a
/// local time, as the phone's clock gives, and UTC days for a UTC one.
KeyStanding keyStanding(crypto.PgpKeyInfo? info, DateTime now) {
  if (info == null) return KeyStanding.ok;
  final primary = _standingOf(info.primary, now);
  return KeyStanding(
    standing: primary.standing,
    expires: primary.expires,
    daysLeft: primary.daysLeft,
    subkeys: [for (final subkey in info.subkeys) _standingOf(subkey, now)],
  );
}

KeyStanding _standingOf(crypto.PgpKey key, DateTime now) {
  final expires = key.expires;
  if (key.revoked) return KeyStanding(standing: Standing.revoked, expires: expires);
  if (expires == null) return KeyStanding.ok;
  if (!now.isBefore(expires)) return KeyStanding(standing: Standing.expired, expires: expires);
  final soon = expires.difference(now) <= expiringSoonWithin;
  final days = daysUntil(expires, now);
  return KeyStanding(
    standing: soon ? Standing.expiringSoon : Standing.ok,
    expires: expires,
    // A clock change on the way can stretch 30 days over 31 dates
    daysLeft: soon && days > expiringSoonWithin.inDays ? expiringSoonWithin.inDays : days,
  );
}

/// The calendar days from the date of [now] to the date of [when], on the
/// calendar [now] is on (local or UTC).
int daysUntil(DateTime when, DateTime now) {
  final there = now.isUtc ? when.toUtc() : when.toLocal();
  // Dates as UTC midnights, so a day the clocks change is still one day
  return DateTime.utc(there.year, there.month, there.day).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
}

/// Reads what a stored PGP key holds from its transferable public key.
/// Tests replace it to count the readings.
final pgpKeyInfoReaderProvider = Provider<crypto.PgpKeyInfo Function(Uint8List publicKey)>((ref) => crypto.readPgpKeyInfo);

/// What the open vault's PGP key [id] holds, read from its public half,
/// which carries the same self-signatures as its secret half and no secret.
/// It is read once per key and unlock, not on every frame of the list, and
/// again only when the key's public half changes: a PGP key's halves grow
/// when it is changed (openspec: add-pgp-key-editing), and its new expiry
/// shows at once. A rename does not read it again. Null for a key of
/// another kind, one that is gone, and one whose public half can't be read.
final pgpKeyInfoProvider = Provider.family<crypto.PgpKeyInfo?, String>((ref, id) {
  final public = ref.watch(
    vaultControllerProvider.select((state) {
      final key = state.keys.firstWhereOrNull((key) => key.id == id);
      return key != null && key.kind == KeyKind.pgp ? key.publicKey : null;
    }),
  );
  if (public == null) return null;
  try {
    return ref.watch(pgpKeyInfoReaderProvider)(unb64(public));
  } on crypto.KeyFormatException {
    return null;
  } on FormatException {
    return null;
  }
});

/// The standing of [key] at [now], or null for a key that isn't a PGP key:
/// SSH, signing, exchange and unknown keys have no expiry, and show no
/// tag, expiry line or warning. [infoOf] is `pgpKeyInfoProvider` read or
/// watched.
KeyStanding? vaultKeyStanding(VaultKey key, DateTime now, crypto.PgpKeyInfo? Function(String id) infoOf) =>
    key.kind == KeyKind.pgp ? keyStanding(infoOf(key.id), now) : null;
