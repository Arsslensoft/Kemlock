/// Moving a vault PGP key's secret parts onto an OpenPGP card (openspec:
/// add-openpgp-card, design decision 12): which part goes to which place,
/// putting each in the form the place's attributes ask for, and proving
/// the card then holds and uses it.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import '../../crypto/keys/der.dart';
import '../../crypto/keys/openpgp/key_info.dart';
import '../../crypto/keys/openpgp/modes.dart' show cipherAes256;
import '../../crypto/keys/openpgp/packets.dart';
import '../../crypto/keys/openpgp/secret_key.dart';
import '../../crypto/keys/openpgp/session_key.dart';
import '../../crypto/keys/openpgp/writer.dart' show cardStubKey;
import 'card_commands.dart';
import 'card_data.dart';
import 'card_operations.dart';
import 'card_session.dart';

/// The attributes a place needs for [key]; null for a kind no card place
/// takes, or whose secret Kemlock cannot take out of its packet: NIST
/// P-256 and P-384, which Kemlock uses on a card but cannot move there.
CardAlgorithm? cardAttributesFor(KeyPacket key, CardPlace place) {
  final CardAlgorithm algorithm;
  switch ((key.algorithm, key.name)) {
    case (1 || 2 || 3, _):
      algorithm = RsaAttributes.ofBits(key.bits ?? 0);
    case (22, 'ed25519'):
      algorithm = CardAlgorithm.parse(const [0x16, 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01]);
    case (18, 'cv25519'):
      algorithm = CardAlgorithm.parse(const [0x12, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01]);
    default:
      return null;
  }
  return algorithm.usable && algorithm.fits(place) ? algorithm : null;
}

/// Whether [a] and [b] are the same kind of key, whatever import form an
/// RSA attribute names.
bool sameCardAlgorithm(CardAlgorithm a, CardAlgorithm b) => switch ((a, b)) {
  (RsaAttributes(modulusBits: final x), RsaAttributes(modulusBits: final y)) => x == y,
  (EccAttributes(id: final i, curve: final c), EccAttributes(id: final j, curve: final d)) => i == j && c == d,
  _ => false,
};

/// Which part of a key goes where, worked out before anything is sent.
class CardMovePlan {
  const CardMovePlan(this.parts, {this.cannotHold});

  /// Each place's part: its key packet and the attributes it needs there.
  final Map<CardPlace, (KeyPacket, CardAlgorithm)> parts;

  /// A place whose part the card cannot hold; then nothing is moved.
  final CardPlace? cannotHold;

  bool get fits => parts.isNotEmpty && cannotHold == null;
}

/// The plan for moving [transferableSecretKey] to the card of [snapshot]
/// at [now] (design decision 12): to the signature place the newest valid
/// signing subkey, else the primary key if it may sign; to the decryption
/// place the newest valid encryption subkey, else the primary key if it
/// may encrypt; to the authentication place the newest valid
/// authentication subkey. A place with no part is left as it is. A part
/// of a kind the card does not list for its place, or Kemlock does not
/// use, gives [CardMovePlan.cannotHold].
CardMovePlan cardMovePlan(Uint8List transferableSecretKey, CardSnapshot snapshot, DateTime now) {
  final key = readTransferableKey(transferableSecretKey);
  final packets = [
    for (final packet in key.packets)
      if (packet.tag == PgpTag.secretKey ||
          packet.tag == PgpTag.secretSubkey ||
          packet.tag == PgpTag.publicKey ||
          packet.tag == PgpTag.publicSubkey)
        parseKeyPacket(packet),
  ];
  final infos = [key.info.primary, ...key.info.subkeys];
  bool valid(PgpKey info) => !info.revoked && (info.expires == null || now.isBefore(info.expires!));
  (KeyPacket, PgpKey)? newest(bool Function(PgpKey info) wanted) {
    (KeyPacket, PgpKey)? best;
    for (var i = 1; i < packets.length; i++) {
      final info = infos[i];
      if (!wanted(info) || !valid(info)) continue;
      if (best == null || info.created.isAfter(best.$2.created)) best = (packets[i], info);
    }
    return best;
  }

  final primary = (packets.first, infos.first);
  final chosen = <CardPlace, KeyPacket>{
    if (newest((info) => info.canSign) ?? (primary.$2.canSign && valid(primary.$2) ? primary : null) case (final packet, _))
      CardPlace.signature: packet,
    if (newest((info) => info.canEncrypt) ?? (primary.$2.canEncrypt && valid(primary.$2) ? primary : null) case (final packet, _))
      CardPlace.decryption: packet,
    if (newest((info) => info.canAuthenticate) case (final packet, _)) CardPlace.authentication: packet,
  };
  final parts = <CardPlace, (KeyPacket, CardAlgorithm)>{};
  for (final MapEntry(key: place, value: packet) in chosen.entries) {
    final wanted = cardAttributesFor(packet, place);
    final list = snapshot.algorithms;
    final listed = list == null || list.of(place).any((a) => wanted != null && sameCardAlgorithm(a, wanted));
    if (wanted == null || !listed) return CardMovePlan(parts, cannotHold: place);
    // An RSA key takes the card's own import form for its size
    final own = list?.of(place).firstWhere((a) => sameCardAlgorithm(a, wanted), orElse: () => wanted);
    parts[place] = (packet, own ?? wanted);
  }
  return CardMovePlan(parts);
}

Uint8List _fixed(BigInt value, int length) => bigIntToBytes(value, length);

/// The private key template's parts of [secret] for a place set to
/// [algorithm]: e, p and q for RSA, with the CRT values and the modulus
/// when the attributes ask for them; the secret for the curves, X25519's
/// in its own byte order.
List<(int, List<int>)> cardImportParts(PgpSecret secret, CardAlgorithm algorithm) {
  switch ((secret, algorithm)) {
    case (RsaSecret(:final material), RsaAttributes(:final modulusBits, :final exponentBits, :final crt, :final withModulus)):
      final half = (modulusBits + 15) ~/ 16;
      return [
        (0x91, _fixed(material.e, (exponentBits + 7) ~/ 8)),
        (0x92, _fixed(material.p, half)),
        (0x93, _fixed(material.q, half)),
        if (crt) ...[(0x94, _fixed(material.qinv, half)), (0x95, _fixed(material.dp, half)), (0x96, _fixed(material.dq, half))],
        if (withModulus) (0x97, _fixed(material.n, (modulusBits + 7) ~/ 8)),
      ];
    case (Ed25519Secret(:final seed), EccAttributes()):
      return [(0x92, seed)];
    case (X25519Secret(secret: final scalar), EccAttributes()):
      return [(0x92, scalar)];
    default:
      throw const CardNotSupported(CardStatus.wrongParameters);
  }
}

/// Puts the parts of [plan], whose secrets [secrets] gives by key packet,
/// on the card of [session], with the admin PIN: each place set to its
/// attributes, its key imported and its fingerprint and time written.
/// Then the card is read again and every fingerprint compared, and each
/// place proved: a signature verified, a session key written to the
/// decryption key opened, the authentication key challenged. Throws
/// [CardIncompleteMove] when the read-back does not show the key.
Future<void> cardImportPlan(OpenPgpCardSession session, CardMovePlan plan, PgpSecret Function(KeyPacket packet) secrets) async {
  for (final MapEntry(key: place, value: (packet, algorithm)) in plan.parts.entries) {
    final current = session.read.data.attributes[place];
    if (current == null || !sameCardAlgorithm(current, algorithm) || current != algorithm) await session.setAlgorithm(place, algorithm);
    await session.putKey(place, cardImportParts(secrets(packet), algorithm));
    await session.putKeyIdentity(place, packet.fingerprint, DateTime.fromMillisecondsSinceEpoch(packet.createdSeconds * 1000, isUtc: true));
  }
  final read = await session.refresh();
  for (final MapEntry(key: place, value: (packet, _)) in plan.parts.entries) {
    if (read.fingerprintHex(place) != cardHex(packet.fingerprint)) throw const CardIncompleteMove();
  }
  final random = Random.secure();
  Uint8List bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) random.nextInt(256)]);
  for (final MapEntry(key: place, value: (packet, _)) in plan.parts.entries) {
    switch (place) {
      case CardPlace.signature:
        await cardSign(session, packet, Uint8List.fromList(hash.sha512.convert(bytes(32)).bytes));
      case CardPlace.decryption:
        final sessionKey = bytes(32);
        final pkesk = await writePkesk3(packet, cipherAes256, sessionKey, bytes(pkeskRandomLength(packet, 32)));
        final opened = await openPkesk(parsePkesk(pkesk), packet, cardSecret(session));
        if (cardHex(opened.key) != cardHex(sessionKey)) throw const CardIncompleteMove();
      case CardPlace.authentication:
        await cardAuthenticate(session, packet);
    }
  }
}

/// The secrets of a plan's parts, taken out of the vault's key before
/// anything is sent to the card.
final class CardMoveSecrets {
  CardMoveSecrets._(this._byFingerprint);

  /// Takes the secret of each part of [plan] out of
  /// [transferableSecretKey], with [passphrase] when the key keeps its own.
  /// Throws the `PgpException` of `unlockSecretKey`: a wrong passphrase,
  /// or a kind whose secret Kemlock cannot take out.
  factory CardMoveSecrets.unlock(Uint8List transferableSecretKey, CardMovePlan plan, {String? passphrase}) {
    final packets = [
      for (final packet in readPackets(transferableSecretKey))
        if (packet.tag == PgpTag.secretKey || packet.tag == PgpTag.secretSubkey) parseKeyPacket(packet),
    ];
    return CardMoveSecrets._({
      for (final (packet, _) in plan.parts.values)
        cardHex(packet.fingerprint): unlockSecretKey(
          packets.firstWhere((p) => cardHex(p.fingerprint) == cardHex(packet.fingerprint)),
          passphrase: passphrase,
        ),
    });
  }

  final Map<String, PgpSecret> _byFingerprint;

  /// The secret of [packet], one of the plan's parts.
  PgpSecret of(KeyPacket packet) => _byFingerprint[cardHex(packet.fingerprint)]!;
}

/// Which fingerprint each place of [plan] gets, in upper-case hexadecimal.
Map<CardPlace, String> cardMovePlaces(CardMovePlan plan) => {
  for (final MapEntry(key: place, value: (packet, _)) in plan.parts.entries) place: cardHex(packet.fingerprint),
};

/// GnuPG's stub of [transferablePublicKey] once [plan] is on the card
/// whose application identifier is [aid]: what the vault keeps in place
/// of the private half of a key moved without a copy.
Uint8List cardMovedStub(Uint8List transferablePublicKey, Uint8List aid, CardMovePlan plan) =>
    cardStubKey(transferablePublicKey, cardAid: aid, onCard: [for (final (packet, _) in plan.parts.values) packet.fingerprint]);

/// The card did not show or use the key after it was put there: the move
/// did not complete, and the vault keeps its copy.
final class CardIncompleteMove extends CardError {
  const CardIncompleteMove();
}
