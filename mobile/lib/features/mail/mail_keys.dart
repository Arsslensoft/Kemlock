/// The keys a mail request can name, read from the open vault (openspec:
/// add-pgp-mail-provider, decision 9): its own PGP keys, which count as
/// checked, and its contacts' (add-pgp-contacts). The OpenPGP API names a
/// key by its primary key's ID, a signed 64-bit number.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../models/contact.dart';
import '../../models/vault_key.dart';
import '../../vault/vault_controller.dart';
import '../contacts/contact_keys.dart' show keyAddresses;
import '../contacts/contact_standing.dart';
import '../keys/key_bridge.dart' show userIdAddress;
import '../keys/key_standing.dart';
import '../pgp/pgp_people.dart' show shortKeyId, userIdName;

/// The key ID of [key] as the OpenPGP API passes it: the low 64 bits of a
/// version 4 fingerprint, the high 64 bits of a version 6 one (RFC 9580),
/// as a signed long.
int mailKeyId(crypto.PgpKey key) {
  final f = key.fingerprint;
  final bytes = key.version == 6 ? Uint8List.sublistView(f, 0, 8) : Uint8List.sublistView(f, f.length - 8);
  return ByteData.sublistView(bytes).getInt64(0);
}

/// The key ID 16 hexadecimal digits name, as a signed long.
int mailKeyIdOfHex(String hex) => (int.parse(hex.substring(0, 8), radix: 16) << 32) | int.parse(hex.substring(8, 16), radix: 16);

/// The key ID in upper-case hexadecimal, as a message names its recipients.
String mailKeyIdHex(int id) =>
    (id < 0 ? (BigInt.from(id) + (BigInt.one << 64)) : BigInt.from(id)).toRadixString(16).toUpperCase().padLeft(16, '0');

/// The address of a user ID or an address given alone, in lower case:
/// `Ada <ada@example.org>` and `ada@example.org` give `ada@example.org`.
String? mailAddress(String userId) {
  final inside = userIdAddress(userId);
  if (inside != null) return inside.toLowerCase();
  final bare = userId.trim();
  return bare.contains('@') && !bare.contains(' ') ? bare.toLowerCase() : null;
}

bool _usable(crypto.PgpKey key, DateTime now, bool Function(crypto.PgpKey key) can) =>
    can(key) && !key.revoked && (key.expires == null || now.isBefore(key.expires!));

/// One of the open vault's own PGP keys.
@immutable
class MailOwnKey {
  const MailOwnKey(this.key, this.info, this.standing);

  final VaultKey key;
  final crypto.PgpKeyInfo info;
  final KeyStanding standing;

  int get keyId => mailKeyId(info.primary);
  String get fingerprint => info.primary.fingerprintHex;
  Uint8List get publicKey => unb64(key.publicKey!);
  Set<String> get addresses => keyAddresses(info);
  String? get userId => info.userIds.firstOrNull;

  /// What the vault calls it, or its first user ID's name.
  String get title => key.name.trim().isNotEmpty ? key.name : userIdName(userId ?? '') ?? shortKeyId(fingerprint);

  /// The IDs of the primary key and every subkey, in upper-case hexadecimal,
  /// as an encrypted message names them.
  Set<String> get allKeyIdsHex => {
    for (final k in [info.primary, ...info.subkeys]) mailKeyIdHex(mailKeyId(k)),
  };

  /// Whether its private half is on a security key (openspec:
  /// add-openpgp-card). Only the PGP sheets reach the card, with it at
  /// hand, so for a mail app such a key is encrypted to and checked
  /// against, and never signs or decrypts.
  bool get onCard => key.isOnCard;

  bool canSignAt(DateTime now) =>
      !onCard &&
      !standing.standing.isOver &&
      (_usable(info.primary, now, (k) => k.canSign) || info.subkeys.any((k) => _usable(k, now, (k) => k.canSign)));

  bool canEncryptAt(DateTime now) =>
      !standing.standing.isOver &&
      (_usable(info.primary, now, (k) => k.canEncrypt) || info.subkeys.any((k) => _usable(k, now, (k) => k.canEncrypt)));
}

/// One of the open vault's contacts whose key reads.
@immutable
class MailContactKey {
  const MailContactKey(this.contact, this.standing);

  final Contact contact;
  final ContactStanding standing;

  crypto.PgpKeyInfo get info => standing.info!;
  int get keyId => mailKeyId(info.primary);
  String get fingerprint => info.primary.fingerprintHex;
  Uint8List get publicKey => unb64(contact.publicKey);
  Set<String> get addresses => keyAddresses(info);

  /// Whether its fingerprint was compared: what a key named by its ID needs.
  bool get checked => standing.checked;

  /// Whether the check covers [address], lower case: whether the key carried
  /// it when it was compared. Its owner can put any address in it since, so
  /// a key found by an address is checked only for those.
  bool confirms(String address) => standing.confirmedAddresses.contains(address);

  /// The addresses the check covers.
  Set<String> get confirmedAddresses => standing.confirmedAddresses;
  bool get canEncrypt => standing.canEncrypt;
}

/// What the open vault holds for mail, at one moment.
@immutable
class MailKeys {
  const MailKeys({required this.own, required this.contacts, required this.now});

  final List<MailOwnKey> own;
  final List<MailContactKey> contacts;
  final DateTime now;

  /// The own key with [keyId]; ask [sharesId] first.
  MailOwnKey? ownById(int keyId) => own.where((k) => k.keyId == keyId).firstOrNull;

  MailOwnKey? ownByVaultId(String id) => own.where((k) => k.key.id == id).firstOrNull;

  /// The contact's key with [keyId]; ask [sharesId] first.
  MailContactKey? contactById(int keyId) => contacts.where((k) => k.keyId == keyId).firstOrNull;

  /// Whether keys of more than one fingerprint have [keyId], own keys and
  /// contacts' together. Sixty-four bits are few enough for anyone to make
  /// a key with another's ID, so a request that names such an ID is not
  /// answered with one key picked among them.
  bool sharesId(int keyId) =>
      {
        for (final k in own)
          if (k.keyId == keyId) k.fingerprint,
        for (final k in contacts)
          if (k.keyId == keyId) k.fingerprint,
      }.length >
      1;

  /// The keys that can be encrypted to for [address]: own keys and contacts
  /// with that address in a user ID, neither expired nor revoked; checked
  /// for it or not, as [MailContactKey.confirms] tells.
  ({List<MailOwnKey> own, List<MailContactKey> contacts}) recipientsFor(String address) => (
    own: [
      for (final k in own)
        if (k.addresses.contains(address) && k.canEncryptAt(now)) k,
    ],
    contacts: [
      for (final k in contacts)
        if (k.addresses.contains(address) && k.canEncrypt) k,
    ],
  );

  /// Every public key a signature is checked against.
  List<Uint8List> get verifiers => [for (final k in own) k.publicKey, for (final k in contacts) k.publicKey];
}

/// Reads a provider: `Ref.read` or `WidgetRef.read`.
typedef MailRead = T Function<T>(ProviderListenable<T> provider);

/// The open vault's keys for mail, read now with [read].
MailKeys readMailKeys(MailRead read) {
  final state = read(vaultControllerProvider);
  final now = read(clockProvider)();
  final own = <MailOwnKey>[];
  for (final key in state.keys) {
    if (key.kind != KeyKind.pgp || key.publicKey == null) continue;
    final info = read(pgpKeyInfoProvider(key.id));
    if (info == null) continue;
    own.add(MailOwnKey(key, info, keyStanding(info, now)));
  }
  final contacts = <MailContactKey>[];
  for (final contact in state.contacts) {
    final info = read(contactKeyInfoProvider(contact.id));
    if (info == null) continue;
    contacts.add(MailContactKey(contact, contactStanding(contact, now, info: info)));
  }
  return MailKeys(own: own, contacts: contacts, now: now);
}
