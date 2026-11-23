/// The transferable public key of the keys an OpenPGP card holds, built
/// from what the card reports (openspec: add-openpgp-card, design
/// decisions 5 and 11): each place's public key read, its key packet built
/// with the time the card stores for it, checked to give the fingerprint
/// the card stores, and certified for a user ID with the card's own
/// signature key. The signature place's key is the primary key; the
/// decryption and authentication places' keys are its subkeys.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/bytes.dart';
import '../../crypto/keys/openpgp/key_info.dart';
import '../../crypto/keys/openpgp/packets.dart';
import '../../crypto/keys/openpgp/writer.dart';
import 'card_commands.dart';
import 'card_data.dart';
import 'card_operations.dart';
import 'card_session.dart';

/// The card's keys are not all set up: a place without the key's
/// fingerprint or time, or with another fingerprint than its key gives, or
/// no signature key to certify with.
final class CardIncomplete extends CardError {
  const CardIncomplete();
}

/// The key flags each place's key carries.
int cardPlaceFlags(CardPlace place) => switch (place) {
  CardPlace.signature => PgpKeyFlag.certify | PgpKeyFlag.sign,
  CardPlace.decryption => PgpKeyFlag.encryptCommunications | PgpKeyFlag.encryptStorage,
  CardPlace.authentication => PgpKeyFlag.authenticate,
};

/// The key packets of the places of [session]'s card that hold a key. A
/// place whose fingerprint and time are missing gets [missingTime], and,
/// with [writeMissing], has them written (with the admin PIN), as at the
/// end of generating; otherwise it throws [CardIncomplete], as it does
/// for a fingerprint that is not the key's.
Future<Map<CardPlace, KeyPacket>> cardKeyPackets(
  OpenPgpCardSession session, {
  required DateTime missingTime,
  bool writeMissing = false,
}) async {
  final snapshot = session.read;
  final packets = <CardPlace, KeyPacket>{};
  for (final place in CardPlace.values) {
    if (!snapshot.data.holdsKey(place)) continue;
    final algorithm = snapshot.data.attributes[place];
    if (algorithm == null) throw const CardIncomplete();
    final public = await session.readPublicKey(place);
    final stored = snapshot.data.times[place];
    final missing = stored == null || snapshot.data.fingerprints[place] == null;
    if (missing && !writeMissing) throw const CardIncomplete();
    final time = missing ? missingTime : stored;
    final packet = cardKeyPacket(
      cardKeyPacketBody(algorithm, public, time),
      tag: place == CardPlace.signature ? PgpTag.publicKey : PgpTag.publicSubkey,
    );
    if (missing) {
      await session.putKeyIdentity(place, packet.fingerprint, time);
    } else if (cardHex(packet.fingerprint) != snapshot.fingerprintHex(place)) {
      throw const CardIncomplete();
    }
    packets[place] = packet;
  }
  if (writeMissing) await session.refresh();
  return packets;
}

/// The transferable public key of [packets], certified for [userId] at
/// [now] by the card's signature key, with the card's PIN: what a card's
/// keys are added to the vault as when no copy of their public key is at
/// hand. Throws [CardIncomplete] without a signature key, and what
/// signing throws.
Future<Uint8List> cardTransferablePublicKey(
  OpenPgpCardSession session,
  Map<CardPlace, KeyPacket> packets, {
  required String userId,
  required DateTime now,
}) async {
  final primary = packets[CardPlace.signature];
  if (primary == null) throw const CardIncomplete();
  final subkeys = [
    for (final place in [CardPlace.decryption, CardPlace.authentication])
      if (packets[place] case final packet?) (packet, cardPlaceFlags(place)),
  ];
  final uid = utf8.encode(userId);
  final (:certification, :bindings) = await pgpSelfSignatures(
    primary: primary,
    userId: uid,
    primaryFlags: cardPlaceFlags(CardPlace.signature),
    subkeys: subkeys,
    time: now.millisecondsSinceEpoch ~/ 1000,
    sign: (digest) => cardSign(session, primary, Uint8List.fromList(digest)),
  );
  return concatBytes([
    writePacket(PgpTag.publicKey, primary.publicBody, oldFormat: true),
    writePacket(PgpTag.userId, uid, oldFormat: true),
    writePacket(PgpTag.signature, certification, oldFormat: true),
    for (final (i, (subkey, _)) in subkeys.indexed) ...[
      writePacket(PgpTag.publicSubkey, subkey.publicBody, oldFormat: true),
      writePacket(PgpTag.signature, bindings[i], oldFormat: true),
    ],
  ]);
}
