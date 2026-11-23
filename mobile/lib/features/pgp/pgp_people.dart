/// Whom a message is encrypted to and whose signature is checked
/// (openspec: add-pgp-messages, decision 15): what the PGP sheets need of
/// a public key, and where such keys come from.
///
/// Three sources: the vault's own PGP keys, which count as checked; the
/// other people's keys the vault keeps (openspec: add-pgp-contacts), each
/// checked or not as its contact is; and a key given for one action, pasted
/// or chosen as a file, which is not checked and is gone when its sheet
/// closes. The sheets ask this file and nothing else.
library;

import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../models/vault_key.dart';
import '../../vault/vault_controller.dart';
import '../contacts/contact_standing.dart';
import '../keys/key_bridge.dart';
import '../keys/key_standing.dart';

/// A public key the sheets can encrypt to or check a signature with.
@immutable
class PgpPerson {
  const PgpPerson({
    required this.publicKey,
    required this.name,
    this.address,
    required this.fingerprint,
    this.checkedAt,
    this.vaultKeyId,
    this.contactId,
    this.standing = Standing.ok,
    this.canSign = true,
    this.ed25519Signatures = false,
  });

  /// The binary transferable public key.
  final Uint8List publicKey;

  /// The name to show (`Ada Lovelace`): for one of the vault's own keys,
  /// its main user ID's name, else what the vault calls the key; for any
  /// other key, its first user ID's, unless the contact has a name of its
  /// own.
  final String name;

  /// The address of that user ID, when it has one.
  final String? address;

  /// The primary key's fingerprint, in upper-case hexadecimal.
  final String fingerprint;

  /// When the person checked that this key is its owner's; null for "not
  /// checked". Only a contact has one, and only while the key it holds is
  /// the one that was checked.
  final DateTime? checkedAt;

  /// The id of the vault key this is, for one of the vault's own keys.
  final String? vaultKeyId;

  /// The id of the contact this is, for one of the other people's keys the
  /// vault keeps; null for the vault's own keys and for a key given for one
  /// action.
  final String? contactId;

  /// Whether the key is expired or revoked, as its row in the vault says.
  final Standing standing;

  /// Whether the app can sign with the key: false for a primary key of an
  /// algorithm it reads but does not use (ML-DSA-87, SLH-DSA), which is
  /// not offered to sign with.
  final bool canSign;

  /// A key in GnuPG's post-quantum format, whose signatures stay Ed25519
  /// and are not post-quantum.
  final bool ed25519Signatures;

  /// One of the vault's own keys.
  bool get isOwn => vaultKeyId != null;

  /// One of the other people's keys the vault keeps.
  bool get isContact => contactId != null;

  /// Whether the key is known to be its owner's: the vault's own keys,
  /// and keys the person has checked.
  bool get isChecked => isOwn || checkedAt != null;

  /// Whether the key can still be encrypted to and signed with.
  bool get isUsable => !standing.isOver;
}

/// The name part of a user ID: `Ada Lovelace <ada@example.org>` gives
/// `Ada Lovelace`; a bare address gives itself; an empty one gives null.
String? userIdName(String userId) {
  final trimmed = userId.trim();
  if (trimmed.isEmpty) return null;
  final angle = trimmed.indexOf('<');
  if (angle <= 0) {
    // Without the `<` it starts with and the `>` it ends with
    final start = trimmed.startsWith('<') ? 1 : 0;
    final end = trimmed.endsWith('>') && trimmed.length > start ? trimmed.length - 1 : trimmed.length;
    return trimmed.substring(start, end);
  }
  final name = _withoutLastComment(trimmed.substring(0, angle)).trim();
  return name.isEmpty ? trimmed.substring(angle + 1).replaceAll('>', '').trim() : name;
}

/// [text] without the comment in brackets it ends with, which is not part
/// of a name: `Ada (work) ` gives `Ada `. Read from its end, with no
/// pattern, since a user ID is its owner's to write and may be long.
String _withoutLastComment(String text) {
  var end = text.length;
  while (end > 0 && isSpaceUnit(text.codeUnitAt(end - 1))) {
    end--;
  }
  if (end == 0 || text.codeUnitAt(end - 1) != 0x29) return text;
  // The `(` this `)` closes: the first after any `)` before it
  final close = end - 1;
  final earlier = close == 0 ? -1 : text.lastIndexOf(')', close - 1);
  final open = text.indexOf('(', earlier + 1);
  return open >= 0 && open < close ? text.substring(0, open) : text;
}

/// A fingerprint in groups of four, as people compare it: `1FCD A135 ...`.
String groupedFingerprint(String fingerprint) =>
    [for (var i = 0; i < fingerprint.length; i += 4) fingerprint.substring(i, i + 4 > fingerprint.length ? fingerprint.length : i + 4)]
        .join(' ');

/// The end of a fingerprint, to name a key that has no user ID.
String shortKeyId(String fingerprint) => fingerprint.length <= 16 ? fingerprint : fingerprint.substring(fingerprint.length - 16);

/// A key given for one action as a person: not checked, not kept.
/// [unnamed] names a key without a user ID.
PgpPerson personOfGivenKey(pgp.PgpPublicKey key, {required String unnamed}) => PgpPerson(
  publicKey: key.transferableKey,
  name: userIdName(key.userId) ?? unnamed,
  address: userIdAddress(key.userId),
  fingerprint: key.fingerprintHex,
);

/// The vault's own PGP keys as people, in the vault's order, each named by
/// its main user ID (openspec: add-pgp-key-editing) and with its standing
/// at the clock's time.
final pgpOwnPeopleProvider = Provider<List<PgpPerson>>((ref) {
  final keys = ref.watch(vaultControllerProvider.select((state) => state.keys));
  final now = ref.watch(clockProvider)();
  final people = <PgpPerson>[];
  for (final key in keys) {
    if (key.kind != KeyKind.pgp) continue;
    final public = key.publicKey;
    final info = ref.watch(pgpKeyInfoProvider(key.id));
    if (public == null || info == null) continue;
    final userId = info.mainUserId ?? '';
    people.add(
      PgpPerson(
        publicKey: unb64(public),
        name: userIdName(userId) ?? key.name,
        address: userIdAddress(userId),
        fingerprint: info.primary.fingerprintHex,
        vaultKeyId: key.id,
        standing: keyStanding(info, now).standing,
        canSign: info.primary.usable,
        ed25519Signatures: pgpIsGnupgFormat(info),
      ),
    );
  }
  return people;
});

/// The other people's keys the vault keeps as people, by name: every
/// contact whose key can be read, whatever its standing, because a
/// signature made while a key was good still checks against it. Which of
/// them may be encrypted to is `contactRecipientsProvider`'s to say.
final pgpContactPeopleProvider = Provider<List<PgpPerson>>((ref) {
  final contacts = ref.watch(vaultControllerProvider.select((state) => state.contacts));
  final now = ref.watch(clockProvider)();
  final people = <PgpPerson>[];
  for (final contact in contacts) {
    final info = ref.watch(contactKeyInfoProvider(contact.id));
    if (info == null) continue;
    final standing = contactStanding(contact, now, info: info);
    final userId = info.userIds.firstOrNull ?? '';
    final fingerprint = info.primary.fingerprintHex;
    people.add(
      PgpPerson(
        publicKey: unb64(contact.publicKey),
        name: contact.name.trim().isNotEmpty ? contact.name : userIdName(userId) ?? shortKeyId(fingerprint),
        address: userIdAddress(userId),
        fingerprint: fingerprint,
        checkedAt: standing.checkedOn,
        contactId: contact.id,
        standing: standing.key.standing,
      ),
    );
  }
  return people..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

/// Everyone whose key is at hand without being given: the people a
/// recipient is chosen from, and the keys every signature is checked
/// against. The vault's own keys, then the other people's keys it keeps.
final pgpPeopleProvider = Provider<List<PgpPerson>>((ref) => [...ref.watch(pgpOwnPeopleProvider), ...ref.watch(pgpContactPeopleProvider)]);

/// Reads a public key that was pasted or chosen as a file, off the UI
/// isolate; tests replace it with one that needs no isolate. Throws a
/// [pgp.PgpException].
final pgpPublicKeyReaderProvider = Provider<Future<pgp.PgpPublicKey> Function(Object input)>(
  (ref) =>
      (input) => Isolate.run(() => pgp.readPgpPublicKey(input)),
);

/// Says why a key may not be encrypted to now, or null when it may, off
/// the UI isolate; tests replace it.
final pgpKeyTroubleProvider = Provider<Future<pgp.PgpException?> Function(Uint8List publicKey, DateTime now)>(
  (ref) =>
      (publicKey, now) => Isolate.run(() => pgp.pgpKeyTrouble(publicKey, now)),
);
