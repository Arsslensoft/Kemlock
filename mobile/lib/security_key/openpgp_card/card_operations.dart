/// The private steps of a PGP key on an OpenPGP card (openspec:
/// add-openpgp-card, design decision 6): signing, the card's half of
/// opening a session key, and proving the authentication key, each
/// checked against the key's public half before anything is given out;
/// and the OpenPGP key packets of the keys a card holds, built from what
/// the card reports.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import '../../crypto/keys/der.dart';
import '../../crypto/keys/openpgp/key_info.dart';
import '../../crypto/keys/openpgp/packets.dart';
import '../../crypto/keys/openpgp/rsa.dart' show hashOids;
import '../../crypto/keys/openpgp/secret_key.dart';
import '../../crypto/keys/openpgp/signatures.dart' show mpiOfBytes, verifySignatureMaterial;
import 'card_commands.dart';
import 'card_data.dart';
import 'card_session.dart';

/// The card connected does not hold the key in the place it is needed in:
/// another card is wanted. Nothing was sent to it for the key.
final class CardWrongCard extends CardError {
  const CardWrongCard();
}

/// What the card answered is not a good signature by the key: nothing is
/// given out.
final class CardBadSignature extends CardError {
  const CardBadSignature();
}

/// SHA-512, the hash every signature Kemlock makes uses.
const _sha512 = 10;

String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join().toUpperCase();

/// The place of [snapshot] that holds [key], by its fingerprint: the
/// signature or the authentication place for a key that [signs], the
/// decryption place for one that decrypts; null when none does.
CardPlace? cardPlaceOf(CardSnapshot snapshot, KeyPacket key, {required bool signs}) {
  final fingerprint = _hex(key.fingerprint);
  for (final place in signs ? const [CardPlace.signature, CardPlace.authentication] : const [CardPlace.decryption]) {
    if (snapshot.fingerprintHex(place) == fingerprint) return place;
  }
  return null;
}

/// What the card signs for [key] over [digest], made with [hashAlgorithm]:
/// the DigestInfo for RSA, which the card pads, and the digest itself for
/// ECDSA and EdDSA.
Uint8List cardSignInput(KeyPacket key, List<int> digest, {int hashAlgorithm = _sha512}) {
  if (key.algorithm != 1 && key.algorithm != 3) return Uint8List.fromList(digest);
  return derSequence([
    derSequence([derOid(hashOids[hashAlgorithm]!), derNull()]),
    derOctetString(digest),
  ]);
}

/// The signature MPIs of [key] in the card's [answer]: one for RSA, r and
/// s (R and S for EdDSA), each half of the answer, for the curves.
Uint8List cardSignatureMpis(KeyPacket key, Uint8List answer) {
  if (key.algorithm == 1 || key.algorithm == 3) return mpiOfBytes(answer);
  if (answer.isEmpty || answer.length.isOdd) throw const CardBadSignature();
  final half = answer.length ~/ 2;
  return Uint8List.fromList([...mpiOfBytes(answer.sublist(0, half)), ...mpiOfBytes(answer.sublist(half))]);
}

/// Has the card of [session] sign [digest] with [signer], in the place
/// that holds it, and gives the signature's MPIs once they are checked.
/// Throws [CardWrongCard] before any PIN for a card that does not hold
/// the key, [CardBadSignature] when the answer does not verify, and what
/// the session throws ([CardPinNeeded] for a PIN not given yet).
Future<Uint8List> cardSign(OpenPgpCardSession session, KeyPacket signer, Uint8List digest, {int hashAlgorithm = _sha512}) async {
  final place = cardPlaceOf(session.read, signer, signs: true);
  if (place == null) throw const CardWrongCard();
  final input = cardSignInput(signer, digest, hashAlgorithm: hashAlgorithm);
  final answer = place == CardPlace.signature ? await session.sign(input) : await session.authenticate(input);
  final mpis = cardSignatureMpis(signer, answer);
  if (!await verifySignatureMaterial(signer, hashAlgorithm, digest, mpis)) throw const CardBadSignature();
  return mpis;
}

/// Has the card of [session] do its half of opening a session key to
/// [recipient]: [input] is what the PKESK carries, the RSA cryptogram or
/// the ECDH ephemeral point. Gives the session key's encoding for RSA,
/// and the shared secret, an x coordinate, for ECDH. Throws
/// [CardWrongCard] before any PIN for a card without the key.
Future<Uint8List> cardDecipher(OpenPgpCardSession session, KeyPacket recipient, Uint8List input) async {
  if (cardPlaceOf(session.read, recipient, signs: false) == null) throw const CardWrongCard();
  switch (recipient.algorithm) {
    case 1 || 2:
      // The cryptogram as long as the modulus, as the card wants it
      final modulus = recipient.bits ?? input.length * 8;
      final length = (modulus + 7) >> 3;
      final cryptogram = input.length >= length ? input : (Uint8List(length)..setAll(length - input.length, input));
      return session.decipherRsa(cryptogram);
    case 18:
      // Curve25519's point without its 0x40, as GnuPG sends it; a NIST point as it is
      final point = input.length == 33 && input[0] == 0x40 ? Uint8List.sublistView(input, 1) : input;
      return cardSharedSecret(await session.decipherEcdh(point));
    default:
      throw const CardNotSupported(CardStatus.insNotSupported);
  }
}

/// The shared secret in what a card answers to an ECDH: the x coordinate
/// of a whole point (`04`, x, y), a Curve25519 secret without its `40`,
/// or the answer itself.
Uint8List cardSharedSecret(Uint8List answer) {
  if (answer.length > 1 && answer.length.isOdd && answer[0] == 0x04) return Uint8List.sublistView(answer, 1, 1 + answer.length ~/ 2);
  if (answer.length == 33 && answer[0] == 0x40) return Uint8List.sublistView(answer, 1);
  return answer;
}

/// Proves the card of [session] holds the authentication key [key]: it
/// signs the SHA-256 of 32 fresh random bytes, and the answer is checked.
/// Throws [CardBadSignature] when it does not verify.
Future<void> cardAuthenticate(OpenPgpCardSession session, KeyPacket key) async {
  final random = Random.secure();
  final challenge = Uint8List.fromList(hash.sha256.convert([for (var i = 0; i < 32; i++) random.nextInt(256)]).bytes);
  if (session.read.fingerprintHex(CardPlace.authentication) != _hex(key.fingerprint)) throw const CardWrongCard();
  final answer = await session.authenticate(cardSignInput(key, challenge, hashAlgorithm: 8));
  if (!await verifySignatureMaterial(key, 8, challenge, cardSignatureMpis(key, answer))) throw const CardBadSignature();
}

/// A private step on the card of a session with the key of a packet.
typedef CardKeyStep = Future<Uint8List> Function(OpenPgpCardSession session, KeyPacket key);

/// The key packet whose bytes [keyPacket] a PGP job hands over for a card
/// step, and its fingerprint in upper-case hexadecimal.
(KeyPacket, String) cardStepKey(Uint8List keyPacket) {
  final packet = parseKeyPacket(readPackets(keyPacket).single);
  return (packet, _hex(packet.fingerprint));
}

/// The private step of the card of [session], for the message code.
DelegatedSecret cardSecret(OpenPgpCardSession session) =>
    DelegatedSecret(sign: (key, digest) => cardSign(session, key, digest), decipher: (key, input) => cardDecipher(session, key, input));

// ─── Key packets of a card's keys ─────────────────────────────────────────────

const _oidEd25519 = [0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01];
const _oidCurve25519 = [0x2b, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01];

/// The body of the version 4 public key packet of the key in a place set
/// to [algorithm], whose public part the card gave as [public], made at
/// [created]: EdDSA on Ed25519, ECDH on Curve25519 (SHA-256 and AES-128,
/// as GnuPG sets it), ECDSA and ECDH on NIST P-256 and P-384 (SHA-256 and
/// AES-128, or SHA-384 and AES-192), or RSA. Throws [CardNotSupported]
/// for another kind.
Uint8List cardKeyPacketBody(CardAlgorithm algorithm, CardPublicKey public, DateTime created) {
  final seconds = created.millisecondsSinceEpoch ~/ 1000;
  final head = [4, seconds >> 24 & 0xff, seconds >> 16 & 0xff, seconds >> 8 & 0xff, seconds & 0xff];
  Never unsupported() => throw const CardNotSupported(CardStatus.insNotSupported);
  switch ((algorithm, public)) {
    case (RsaAttributes(), CardRsaPublicKey(:final modulus, :final exponent)):
      return Uint8List.fromList([...head, 1, ...mpiOfBytes(modulus), ...mpiOfBytes(exponent)]);
    case (EccAttributes(:final curve, :final id, :final oid), CardEcPublicKey(:final point)):
      switch ((id, curve)) {
        case (CardAlgorithmId.eddsa, 'ed25519'):
          if (point.length != 32) unsupported();
          return Uint8List.fromList([
            ...head,
            22,
            _oidEd25519.length,
            ..._oidEd25519,
            ...mpiOfBytes([0x40, ...point]),
          ]);
        case (CardAlgorithmId.ecdh, 'cv25519'):
          if (point.length != 32) unsupported();
          return Uint8List.fromList([
            ...head,
            18,
            _oidCurve25519.length,
            ..._oidCurve25519,
            ...mpiOfBytes([0x40, ...point]),
            3,
            1,
            8,
            7,
          ]);
        case (CardAlgorithmId.ecdsa || CardAlgorithmId.ecdh, 'nistp256' || 'nistp384'):
          final kdf = curve == 'nistp256' ? [3, 1, 8, 7] : [3, 1, 9, 8];
          final bits = point.length * 8 - 5;
          return Uint8List.fromList([
            ...head,
            id,
            oid.length,
            ...oid,
            bits >> 8,
            bits & 0xff,
            ...point,
            if (id == CardAlgorithmId.ecdh) ...kdf,
          ]);
        default:
          unsupported();
      }
    default:
      unsupported();
  }
}

/// The key packet, of [tag], of [body].
KeyPacket cardKeyPacket(Uint8List body, {int tag = PgpTag.publicKey}) =>
    parseKeyPacket(readPackets(writePacket(tag, body, oldFormat: true)).single);
