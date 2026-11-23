/// The commands of a security key's OpenPGP card application (OpenPGP
/// Smart Card Application 3.4, section 7.2), one function each, and what
/// their status words mean (openspec: add-openpgp-card, design decision
/// 1). Long commands and answers are left to [transmitApdu], which
/// chains a command into parts on a link without extended APDUs and
/// fetches an answer in parts with GET RESPONSE.
library;

import 'dart:typed_data';

import '../apdu.dart';
import 'card_data.dart';

// ─── Status words ─────────────────────────────────────────────────────────────

/// The status words the card's commands end with, other than `9000`.
abstract final class CardStatus {
  /// SELECT: the application is in its termination state.
  static const terminated = 0x6285;
  static const wrongLength = 0x6700;

  /// A PIN that was needed was not given in this connection.
  static const securityNotSatisfied = 0x6982;

  /// The PIN has no tries left.
  static const blocked = 0x6983;
  static const conditionsNotSatisfied = 0x6985;
  static const wrongData = 0x6a80;
  static const notFound = 0x6a88;
  static const wrongParameters = 0x6b00;
  static const insNotSupported = 0x6d00;
  static const claNotSupported = 0x6e00;
}

/// Which PIN a command is about.
enum CardPin {
  /// The PIN, for a signature (`81`).
  pinToSign(0x81),

  /// The PIN, for everything else it allows (`82`).
  pin(0x82),

  /// The admin PIN (`83`).
  admin(0x83),

  /// The reset code: given only to RESET RETRY COUNTER.
  resetCode(0x81);

  const CardPin(this.reference);

  /// The reference VERIFY names it by.
  final int reference;
}

/// The card refused a command, or could not do it.
abstract class CardError implements Exception {
  const CardError();
}

/// A PIN was wrong; [triesLeft] are left.
final class CardWrongPin extends CardError {
  const CardWrongPin(this.pin, this.triesLeft);

  final CardPin pin;
  final int triesLeft;

  @override
  String toString() => 'CardWrongPin(${pin.name}, $triesLeft left)';
}

/// A PIN has no tries left.
final class CardPinBlocked extends CardError {
  const CardPinBlocked(this.pin);

  final CardPin pin;

  @override
  String toString() => 'CardPinBlocked(${pin.name})';
}

/// The command needs a PIN that was not given in this connection.
final class CardSecurityNotSatisfied extends CardError {
  const CardSecurityNotSatisfied();
}

/// The card has no such object, or no key where one was needed.
final class CardNotFound extends CardError {
  const CardNotFound();
}

/// The application is in its termination state: a factory reset was left
/// half done.
final class CardTerminated extends CardError {
  const CardTerminated();
}

/// The card does not know the command or its parameters.
final class CardNotSupported extends CardError {
  const CardNotSupported(this.status);

  final int status;
}

/// Any other refusal, with the card's [status].
final class CardRefused extends CardError {
  const CardRefused(this.status);

  final int status;

  @override
  String toString() => 'CardRefused(${status.toRadixString(16).padLeft(4, '0')})';
}

/// The [CardError] for a status word that is not `9000`; [pin] says which
/// PIN a `63Cx` or `6983` is about.
CardError cardError(int status, {CardPin? pin}) {
  if (status & 0xfff0 == 0x63c0) return CardWrongPin(pin ?? CardPin.pin, status & 0x0f);
  return switch (status) {
    CardStatus.blocked => CardPinBlocked(pin ?? CardPin.pin),
    CardStatus.securityNotSatisfied => const CardSecurityNotSatisfied(),
    CardStatus.notFound || swFileNotFound => const CardNotFound(),
    CardStatus.terminated => const CardTerminated(),
    CardStatus.insNotSupported || CardStatus.claNotSupported || CardStatus.wrongParameters || 0x6a86 => CardNotSupported(status),
    _ => CardRefused(status),
  };
}

/// The data of [response], or the [CardError] its status stands for.
Uint8List cardAnswer(ApduResponse response, {CardPin? pin}) {
  if (response.ok) return response.data;
  // A card that has more to say about a warning still did the command
  if (response.sw1 == 0x62 && response.sw != CardStatus.terminated) return response.data;
  throw cardError(response.sw, pin: pin);
}

// ─── Commands ─────────────────────────────────────────────────────────────────

/// SELECT of the OpenPGP application by its identifier.
ApduCommand selectOpenPgp() => selectByName(openPgpAid);

/// GET DATA of the object [tag] (one or two bytes).
ApduCommand getData(int tag) => ApduCommand(ins: 0xca, p1: tag >> 8, p2: tag & 0xff, le: apduShortLe);

/// PUT DATA of [value] into the object [tag].
ApduCommand putData(int tag, List<int> value) => ApduCommand(ins: 0xda, p1: tag >> 8, p2: tag & 0xff, data: value);

/// VERIFY of [pin], the bytes as they are sent (hashed already when the
/// card wants that), for [which].
ApduCommand verifyPin(CardPin which, List<int> pin) => ApduCommand(ins: 0x20, p2: which.reference, data: pin);

/// CHANGE REFERENCE DATA: [current] then [next], for the PIN or the admin
/// PIN.
ApduCommand changePin(CardPin which, List<int> current, List<int> next) {
  if (which != CardPin.pin && which != CardPin.admin) throw ArgumentError.value(which, 'which', 'only the PIN and the admin PIN change');
  return ApduCommand(ins: 0x24, p2: which == CardPin.admin ? 0x83 : 0x81, data: [...current, ...next]);
}

/// RESET RETRY COUNTER of the PIN, to [newPin]: with the [resetCode], or,
/// without one, after the admin PIN was verified.
ApduCommand resetPin(List<int> newPin, {List<int>? resetCode}) =>
    ApduCommand(ins: 0x2c, p1: resetCode == null ? 0x02 : 0x00, p2: 0x81, data: [...?resetCode, ...newPin]);

/// PUT DATA of the reset code (`D3`); an empty one removes it.
ApduCommand putResetCode(List<int> resetCode) => putData(0xd3, resetCode);

/// PUT DATA of the PIN's validity (`C4`): for every signature, or for as
/// many as one connection makes.
ApduCommand putPinPolicy({required bool everySignature}) => putData(0xc4, [everySignature ? 0x00 : 0x01]);

/// PUT DATA of a place's touch setting.
ApduCommand putTouch(CardPlace place, TouchPolicy policy) => putData(place.touch, [policy.code, 0x20]);

/// PSO: COMPUTE DIGITAL SIGNATURE of [input]: a DigestInfo for RSA, the
/// hash itself for ECDSA and EdDSA.
ApduCommand computeSignature(List<int> input) => ApduCommand(ins: 0x2a, p1: 0x9e, p2: 0x9a, data: input, le: apduShortLe);

/// PSO: DECIPHER of an RSA cryptogram: the padding indicator `00`, then
/// the cryptogram.
ApduCommand decipherRsa(List<int> cryptogram) => ApduCommand(ins: 0x2a, p1: 0x80, p2: 0x86, data: [0x00, ...cryptogram], le: apduShortLe);

/// PSO: DECIPHER for ECDH with the other side's public [point], in the
/// cipher DO the specification gives: `A6 { 7F49 { 86 point } }`.
ApduCommand decipherEcdh(List<int> point) =>
    ApduCommand(ins: 0x2a, p1: 0x80, p2: 0x86, data: encodeTlv(0xa6, encodeTlv(0x7f49, encodeTlv(0x86, point))), le: apduShortLe);

/// INTERNAL AUTHENTICATE with the authentication key over [input]: a
/// DigestInfo for RSA, the hash itself for the curves.
ApduCommand internalAuthenticate(List<int> input) => ApduCommand(ins: 0x88, data: input, le: apduShortLe);

/// GENERATE ASYMMETRIC KEY PAIR: a new key in [place], or with [read] the
/// public key of the one there.
ApduCommand generateKey(CardPlace place, {bool read = false}) =>
    ApduCommand(ins: 0x47, p1: read ? 0x81 : 0x80, data: [place.crt, 0x00], le: apduShortLe);

/// PUT DATA of a key into [place] (odd instruction `DB`, extended header
/// list): [parts] by their tag in the private key template (`91` to `99`),
/// in the order given.
ApduCommand importKey(CardPlace place, List<(int, List<int>)> parts) {
  final template = <int>[
    for (final (tag, value) in parts) ...[tag, ..._berLength(value.length)],
  ];
  final values = <int>[for (final (_, value) in parts) ...value];
  final header = encodeTlv(0x4d, [place.crt, 0x00, ...encodeTlv(0x7f48, template), ...encodeTlv(0x5f48, values)]);
  return ApduCommand(ins: 0xdb, p1: 0x3f, p2: 0xff, data: header);
}

List<int> _berLength(int length) => length < 0x80
    ? [length]
    : length < 0x100
    ? [0x81, length]
    : [0x82, length >> 8, length & 0xff];

/// PUT DATA of a place's fingerprint.
ApduCommand putFingerprint(CardPlace place, List<int> fingerprint) => putData(place.fingerprint, fingerprint);

/// PUT DATA of a place's key creation time, in seconds.
ApduCommand putKeyTime(CardPlace place, DateTime time) {
  final seconds = time.millisecondsSinceEpoch ~/ 1000;
  return putData(place.time, [seconds >> 24 & 0xff, seconds >> 16 & 0xff, seconds >> 8 & 0xff, seconds & 0xff]);
}

/// PUT DATA of a place's algorithm attributes.
ApduCommand putAttributes(CardPlace place, CardAlgorithm algorithm) => putData(place.attributes, algorithm.bytes);

/// PUT DATA of the KDF object.
ApduCommand putKdf(List<int> kdf) => putData(0xf9, kdf);

/// TERMINATE DF: the first half of a factory reset, once both PINs are
/// blocked.
ApduCommand terminate() => ApduCommand(ins: 0xe6);

/// ACTIVATE FILE: the second half, which brings the card back empty.
ApduCommand activate() => ApduCommand(ins: 0x44);

// ─── Public keys ──────────────────────────────────────────────────────────────

/// A public key as GENERATE gives it (`7F49`).
sealed class CardPublicKey {
  const CardPublicKey();

  /// Reads the public key template of a GENERATE answer.
  factory CardPublicKey.parse(List<int> bytes) {
    final objects = parseTlvs(bytes);
    final template = findTlv(objects, 0x7f49);
    if (template == null) throw const CardFormatError('no public key template');
    final inside = template.children;
    final point = findTlv(inside, 0x86)?.value;
    if (point != null) return CardEcPublicKey(Uint8List.fromList(point));
    final n = findTlv(inside, 0x81)?.value;
    final e = findTlv(inside, 0x82)?.value;
    if (n == null || e == null || n.isEmpty || e.isEmpty) throw const CardFormatError('a public key with neither point nor modulus');
    return CardRsaPublicKey(Uint8List.fromList(n), Uint8List.fromList(e));
  }
}

final class CardRsaPublicKey extends CardPublicKey {
  const CardRsaPublicKey(this.modulus, this.exponent);

  final Uint8List modulus;
  final Uint8List exponent;
}

/// A point: for Curve25519 and Ed25519 the 32 bytes of the key, for the
/// NIST curves `04`, x and y.
final class CardEcPublicKey extends CardPublicKey {
  const CardEcPublicKey(this.point);

  final Uint8List point;
}
