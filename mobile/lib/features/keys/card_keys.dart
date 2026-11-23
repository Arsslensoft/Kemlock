/// What the vault keeps of a PGP key whose private half is on a security
/// key's OpenPGP card (openspec: add-openpgp-card, design decision 4): the
/// card's application identifier and the fingerprint in each place the
/// key uses, in [VaultKey.card]. Its private half is GnuPG's stub, which
/// holds no secret.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' show cardStubKey, readPgpKeyInfo;
import '../../models/vault_key.dart';
import '../../security_key/openpgp_card/card_data.dart';
import '../../security_key/openpgp_card/card_session.dart';
import '../../vault/vault_controller.dart';

/// The name the vault keeps each place's fingerprint under.
const cardSlotNames = {CardPlace.signature: 'sig', CardPlace.decryption: 'dec', CardPlace.authentication: 'aut'};

/// The `card` object of a key on the card [aid] (32 hexadecimal digits)
/// with [slots], each place's fingerprint in upper-case hexadecimal; a
/// place the key does not use is left out.
Map<String, Object?> cardObject(String aid, Map<CardPlace, String> slots) => {
  'aid': aid.toUpperCase(),
  'slots': {
    for (final place in CardPlace.values)
      if (slots[place] case final fingerprint?) cardSlotNames[place]!: fingerprint.toUpperCase(),
  },
};

/// The application identifier of the card [key] is on, upper-case; null
/// for a key not on a card or one that names none.
String? cardKeyAid(VaultKey key) => switch (key.card?['aid']) {
  final String aid when aid.length == 32 => aid.toUpperCase(),
  _ => null,
};

/// The serial number of the card [key] is on, as people read it:
/// `1234 5678`.
String? cardKeySerial(VaultKey key) {
  final aid = cardKeyAid(key);
  if (aid == null) return null;
  return '${aid.substring(20, 24)} ${aid.substring(24, 28)}';
}

/// The fingerprint [key] keeps for [place], upper-case; null when it uses
/// none there.
String? cardKeySlot(VaultKey key, CardPlace place) {
  final slots = key.card?['slots'];
  if (slots is! Map) return null;
  final fingerprint = slots[cardSlotNames[place]];
  return fingerprint is String ? fingerprint.toUpperCase() : null;
}

/// Every fingerprint [key] keeps for a place on its card.
Iterable<String> cardKeyFingerprints(VaultKey key) => [for (final place in CardPlace.values) ?cardKeySlot(key, place)];

/// The cards read since the vault was opened, by application identifier:
/// the fingerprints each held when it was last read. Kept in memory only,
/// and forgotten when the vault locks, so that a key's sheet can say its
/// card no longer holds it (design decision 13).
class CardsSeen extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() {
    ref.listen(vaultControllerProvider.select((state) => state.session), (_, session) {
      if (session == null) state = const {};
    });
    return const {};
  }

  /// Notes what [snapshot] shows the card holds.
  void seen(CardSnapshot snapshot) => note(snapshot.aid.hex, {
    for (final place in CardPlace.values)
      if (snapshot.data.holdsKey(place)) ?snapshot.fingerprintHex(place),
  });

  /// Notes that the card [aid] holds the keys of [fingerprints].
  void note(String aid, Set<String> fingerprints) => state = {...state, aid.toUpperCase(): fingerprints};
}

final cardsSeenProvider = NotifierProvider<CardsSeen, Map<String, Set<String>>>(CardsSeen.new);

/// Whether the card [key] is on was read since the vault opened without
/// one of the key's fingerprints: it no longer holds the key, as after a
/// factory reset.
bool cardNoLongerHolds(VaultKey key, Map<String, Set<String>> seen) {
  final aid = cardKeyAid(key);
  final held = aid == null ? null : seen[aid];
  if (held == null) return false;
  return !cardKeyFingerprints(key).every(held.contains);
}

/// The places of [snapshot]'s card that hold one of the keys of the
/// transferable key [publicKey], by their fingerprints: none when the card
/// holds none of them.
Map<CardPlace, String> cardPlacesOfKey(Uint8List publicKey, CardSnapshot snapshot) {
  final info = readPgpKeyInfo(publicKey);
  final fingerprints = {
    for (final key in [info.primary, ...info.subkeys]) key.fingerprintHex,
  };
  return {
    for (final place in CardPlace.values)
      if (snapshot.fingerprintHex(place) case final fingerprint? when fingerprints.contains(fingerprint)) place: fingerprint,
  };
}

/// The vault key whose private half is on [snapshot]'s card: [publicKey]
/// as its public half, GnuPG's stub naming the card as its private half,
/// and the card with each place that holds one of its keys (design
/// decision 4). Throws an [ArgumentError] when the card holds none of its
/// keys.
VaultKey cardVaultKey({
  required String id,
  required String name,
  required Uint8List publicKey,
  required CardSnapshot snapshot,
  required String origin,
}) {
  final places = cardPlacesOfKey(publicKey, snapshot);
  if (places.isEmpty) throw ArgumentError('the card holds none of these keys');
  final stub = cardStubKey(
    publicKey,
    cardAid: snapshot.aid.bytes,
    onCard: [
      for (final fingerprint in places.values)
        [for (var i = 0; i < fingerprint.length; i += 2) int.parse(fingerprint.substring(i, i + 2), radix: 16)],
    ],
  );
  return VaultKey(
    id: id,
    name: name,
    kind: KeyKind.pgp,
    algorithm: 'pgp',
    privateKey: b64(stub),
    publicKey: b64(publicKey),
    origin: origin,
    protected: true,
    addedAt: 0,
    card: cardObject(snapshot.aid.hex, places),
  );
}
