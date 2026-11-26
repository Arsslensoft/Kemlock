/// What the app knows about a contact right now: whether its fingerprint
/// was checked, whether its key may still be used, and whether a message
/// can be encrypted to it (openspec: add-pgp-contacts). The list, the
/// contact's sheet and the recipients of a message all read this and
/// nothing else, so they never disagree. It is worked out each time from
/// the stored key and the clock, and never stored.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../models/contact.dart';
import '../../vault/vault_controller.dart';
import '../keys/key_standing.dart';
import 'contact_keys.dart' show keyAddresses;

/// A contact's standing at one moment.
@immutable
class ContactStanding {
  const ContactStanding({
    required this.checked,
    this.checkedOn,
    this.confirmedAddresses = const {},
    required this.key,
    required this.canEncrypt,
    this.info,
  });

  /// Whether the fingerprint of the key the contact holds is the one that
  /// was compared with its owner.
  final bool checked;

  /// The addresses of the key's user IDs, in lower case, that the check
  /// covers: those the key carried when it was compared. Comparing a
  /// fingerprint proves whose key it is; the addresses in it are what its
  /// owner says, so one added since is not checked. Empty when not
  /// [checked].
  final Set<String> confirmedAddresses;

  /// The addresses of the key's user IDs that the check does not cover:
  /// all of them when not [checked].
  Set<String> get uncheckedAddresses => keyAddresses(info).difference(confirmedAddresses);

  /// When it was compared, in local time; null when not [checked].
  final DateTime? checkedOn;

  /// Whether the key is in order, expiring soon, expired or revoked.
  final KeyStanding key;

  /// Whether the key holds an encryption key that is neither expired nor
  /// revoked, under a primary key that is neither. A contact without one
  /// is not offered as a recipient.
  final bool canEncrypt;

  /// What the key holds; null when it can't be read.
  final crypto.PgpKeyInfo? info;

  /// The key's fingerprint, upper-case hexadecimal; null when it can't be read.
  String? get fingerprint => info?.primary.fingerprintHex;
}

/// What the key of [contact] holds, or null when it can't be read or it has no key.
crypto.PgpKeyInfo? contactKeyInfo(Contact contact) {
  // A person with no key has nothing to read
  if (!contact.hasKey) return null;
  try {
    return crypto.readPgpKeyInfo(unb64(contact.publicKey));
  } on crypto.KeyFormatException {
    return null;
  } on FormatException {
    return null;
  }
}

/// The standing of [contact] at [now]. [info] is what its key holds when
/// the caller has read it already; without it the key is read here. A key
/// that can't be read is not checked and can't be encrypted to.
ContactStanding contactStanding(Contact contact, DateTime now, {crypto.PgpKeyInfo? info}) {
  final key = info ?? contactKeyInfo(contact);
  if (key == null) return const ContactStanding(checked: false, key: KeyStanding.ok, canEncrypt: false);
  final standing = keyStanding(key, now);
  final checkedAt = contact.checkedAt;
  final checked = contact.checkedFingerprint != null && contact.checkedFingerprint!.toUpperCase() == key.primary.fingerprintHex;
  final addresses = keyAddresses(key);
  // A check that kept no addresses, until the vault next opens and writes them down, covers the key as it is
  final covered = contact.checkedAddresses;
  final confirmed = !checked
      ? const <String>{}
      : covered == null
      ? addresses
      : addresses.intersection({for (final address in covered) address.toLowerCase()});
  bool usable(crypto.PgpKey k) => k.canEncrypt && !k.revoked && (k.expires == null || now.isBefore(k.expires!));
  return ContactStanding(
    checked: checked,
    checkedOn: checked && checkedAt != null ? DateTime.fromMillisecondsSinceEpoch(checkedAt) : null,
    confirmedAddresses: confirmed,
    key: standing,
    canEncrypt: !standing.standing.isOver && (usable(key.primary) || key.subkeys.any(usable)),
    info: key,
  );
}

/// What the key of the open vault's contact [id] holds. It is read once
/// per stored key, not on every frame of the list; null for a contact that
/// is gone or whose key can't be read.
final contactKeyInfoProvider = Provider.family<crypto.PgpKeyInfo?, String>((ref, id) {
  final public = ref.watch(vaultControllerProvider.select((state) => state.contacts.firstWhereOrNull((c) => c.id == id)?.publicKey));
  if (public == null || public.isEmpty) return null;
  try {
    return crypto.readPgpKeyInfo(unb64(public));
  } on crypto.KeyFormatException {
    return null;
  } on FormatException {
    return null;
  }
});
