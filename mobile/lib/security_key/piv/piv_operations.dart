/// What Kemlock does to a card's PIV application, each as the commands it
/// takes, inside a [PivSession] that is already open: signing with a
/// slot's key, giving a generated key its certificate or request, storing
/// and removing certificates with the card's identifier objects, making a
/// new management key, and reset (openspec: add-piv-management, design
/// decisions 5 to 9 and 12).
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import '../../crypto/bytes.dart';
import '../../crypto/keys/algorithms.dart';
import '../../crypto/keys/key_error.dart';
import '../../crypto/keys/pkcs8.dart' show writeSpki;
import '../../crypto/keys/x509.dart';
import 'piv_commands.dart';
import 'piv_data.dart';
import 'piv_session.dart';

/// The card returned a signature that does not verify with the slot's
/// public key. Nothing was stored.
class PivBadSignature implements Exception {
  const PivBadSignature();
}

/// A certificate was to go into a slot whose key is another one. Nothing
/// was stored.
class PivKeyMismatch implements Exception {
  const PivKeyMismatch();
}

/// The kind of key in [key], as a card names it; null for one no slot of
/// this app's makes.
PivAlgorithm? pivAlgorithmOf(PublicHalf? key) => switch (key) {
  RsaPublicHalf(:final n) when n.bitLength == 2048 => PivAlgorithm.rsa2048,
  EcPublicHalf(curve: EcCurve.p256) => PivAlgorithm.eccP256,
  EcPublicHalf(curve: EcCurve.p384) => PivAlgorithm.eccP384,
  _ => null,
};

/// What a certificate in [slot] is for.
CertificateUse pivCertificateUse(PivSlot slot) => switch (slot) {
  PivSlot.authentication => CertificateUse.authentication,
  PivSlot.signature => CertificateUse.signature,
  PivSlot.keyManagement => CertificateUse.keyManagement,
  PivSlot.cardAuthentication => CertificateUse.cardAuthentication,
};

/// The certificate in [slot] as read, or null when the slot holds none or
/// something that is not one.
X509Certificate? pivSlotCertificate(PivSlotState slot) {
  final bytes = slot.certificate;
  if (slot.status != PivSlotStatus.certificate || bytes == null) return null;
  try {
    return readCertificate(bytes);
  } on KeyFormatException {
    return null;
  }
}

/// The public key of the key in [slot], as far as Kemlock can know it:
/// from the certificate there, or from what the card reports of the slot.
/// Null when it can know neither.
PublicHalf? pivSlotPublicKey(PivSlotState slot) => pivSlotCertificate(slot)?.publicKey ?? slot.publicKey;

/// Whether [a] and [b] are the same public key.
bool samePublicKey(PublicHalf a, PublicHalf b) {
  final Uint8List left;
  final Uint8List right;
  try {
    left = writeSpki(a);
    right = writeSpki(b);
  } on Object {
    return false;
  }
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

/// Signs with the key in [slot] of the card of [session]. For RSA the hash
/// is padded here (PKCS#1 v1.5) and the card does the raw operation; for a
/// curve the card is sent the hash and answers a DER signature. The held
/// PIN is given first where the slot wants one: once, unless
/// [pinVerified] says it was given in this session already, and right
/// before every signature in the signature slot.
X509Signer pivSigner(PivSession session, PivSlot slot, PivAlgorithm algorithm, {bool lastTry = false, bool pinVerified = false}) {
  var verified = pinVerified;
  return (toBeSigned) async {
    if (slot.needsPin && (!verified || slot == PivSlot.signature)) {
      await session.verifyPin(lastTry: lastTry);
      verified = true;
    }
    switch (algorithm) {
      case PivAlgorithm.rsa2048:
        return session.card.sign(slot, algorithm, emsaPkcs1(oidSha256, hash.sha256.convert(toBeSigned).bytes, 256));
      case PivAlgorithm.eccP256:
        return session.card.sign(slot, algorithm, hash.sha256.convert(toBeSigned).bytes);
      case PivAlgorithm.eccP384:
        return session.card.sign(slot, algorithm, hash.sha384.convert(toBeSigned).bytes);
    }
  };
}

/// A self-signed certificate for the key in [slot], whose public half is
/// [publicKey], naming [commonName], signed by the slot's key and checked
/// before it is returned. Throws [PivBadSignature] when the check fails.
/// Nothing is stored.
Future<Uint8List> pivSelfSigned(
  PivSession session,
  PivSlot slot,
  PublicHalf publicKey, {
  required String commonName,
  required DateTime notBefore,
  required DateTime notAfter,
  bool lastTry = false,
  bool pinVerified = false,
}) async {
  final algorithm = pivAlgorithmOf(publicKey);
  if (algorithm == null) throw ArgumentError('not a key a slot holds');
  final der = await buildSelfSigned(
    publicKey: publicKey,
    commonName: commonName,
    notBefore: notBefore,
    notAfter: notAfter,
    use: pivCertificateUse(slot),
    sign: pivSigner(session, slot, algorithm, lastTry: lastTry, pinVerified: pinVerified),
  );
  try {
    if (!verifyOwnSignature(readCertificate(der))) throw const PivBadSignature();
  } on KeyFormatException {
    throw const PivBadSignature();
  }
  return der;
}

/// A certificate request for the key in [slot], signed by it and checked.
Future<Uint8List> pivRequest(
  PivSession session,
  PivSlot slot,
  PublicHalf publicKey, {
  required String commonName,
  bool lastTry = false,
  bool pinVerified = false,
}) async {
  final algorithm = pivAlgorithmOf(publicKey);
  if (algorithm == null) throw ArgumentError('not a key a slot holds');
  final der = await buildRequest(
    publicKey: publicKey,
    commonName: commonName,
    sign: pivSigner(session, slot, algorithm, lastTry: lastTry, pinVerified: pinVerified),
  );
  try {
    if (!readCertificateRequest(der).verifies) throw const PivBadSignature();
  } on KeyFormatException {
    throw const PivBadSignature();
  }
  return der;
}

/// Stores [certificate] in [slot], or with null removes the one there.
/// Needs the management key.
///
/// With a certificate it also sees to the two objects computers know a
/// PIV card by: a capability container is written when the card has
/// none, and the card holder identifier is written afresh every time,
/// which is what makes a Mac read the slots again.
Future<void> pivStoreCertificate(
  PivSession session,
  PivSlot slot,
  Uint8List? certificate, {
  Uint8List Function(int length) random = randomBytes,
}) async {
  await session.card.putData(slot.object, wrapPivCertificate(certificate));
  if (certificate == null) return;
  await pivEnsureCardId(session, random: random);
  await session.card.putData(pivChuidObject, buildPivChuid(random(16)));
}

/// Stores [certificate], one a person brought, in [slot], after checking
/// it is for the slot's key where the card lets that be known: from the
/// certificate there now, or from the slot's metadata. Throws
/// [PivKeyMismatch] for a certificate of another key, with nothing sent.
Future<void> pivImportCertificate(
  PivSession session,
  PivSlot slot,
  X509Certificate certificate, {
  Uint8List Function(int length) random = randomBytes,
}) async {
  final slotState = session.state.slots[slot];
  final slotKey = slotState == null ? null : pivSlotPublicKey(slotState);
  final newKey = certificate.publicKey;
  if (slotKey != null && (newKey == null || !samePublicKey(slotKey, newKey))) throw const PivKeyMismatch();
  await pivStoreCertificate(session, slot, certificate.encoded, random: random);
}

/// Writes a capability container with a fresh card identifier on a card
/// that has none, and returns the card's identifier either way. Needs the
/// management key.
Future<String> pivEnsureCardId(PivSession session, {Uint8List Function(int length) random = randomBytes}) async {
  final held = session.state.cardId;
  if (held != null) return held;
  final container = buildPivCcc(random(14));
  await session.card.putData(pivCccObject, container);
  final id = readPivCccId(pivTlv(0x53, container))!;
  session.state = session.state.withCardId(id);
  return id;
}

/// A new random management key of [type]. A triple DES key gets odd
/// parity, and one a card may refuse as weak is never returned.
Uint8List newPivManagementKey(PivManagementKeyType type, {Uint8List Function(int length) random = randomBytes}) {
  if (type != PivManagementKeyType.tripleDes) return random(type.keyLength);
  while (true) {
    final key = withOddParity(random(type.keyLength));
    if (!isWeakTripleDesKey(key)) return key;
  }
}

/// A management key typed or pasted as hex, spaces, colons, dashes and
/// case ignored. Null when it is not hex of a length a management key
/// has.
Uint8List? parsePivManagementKey(String text) {
  final clean = text.replaceAll(RegExp(r'[\s:\-]'), '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(clean) || !const {32, 48, 64}.contains(clean.length)) return null;
  return Uint8List.fromList([for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)]);
}

/// [key] in hex, in groups of four, as a person reads it.
String formatPivManagementKey(List<int> key) {
  final hex = [for (final byte in key) byte.toRadixString(16).padLeft(2, '0')].join().toUpperCase();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4 > hex.length ? hex.length : i + 4)].join(' ');
}

/// The kinds a typed management key of [length] bytes may be on a card
/// whose management key is of [known] kind, or of a kind the card does
/// not say: the ones to try, in order.
List<PivManagementKeyType> pivKeyTypesFor(int length, PivManagementKeyType? known) => [
  if (known != null && known.keyLength == length) known,
  for (final type in PivManagementKeyType.values)
    if (type.keyLength == length && type != known) type,
];

/// Proves the management [key] to the card of [session], trying each kind
/// a key of its length may be, the one the card reports first. Returns
/// the kind the card took; throws [PivManagementKeyRefused] when it took
/// none.
Future<PivManagementKeyType> pivAuthenticate(PivSession session, List<int> key, {PivManagementKeyType? type}) async {
  final known = session.state.managementKey != null ? session.state.managementKeyType : type;
  for (final kind in pivKeyTypesFor(key.length, known)) {
    try {
      await session.card.authenticate(kind, key);
      return kind;
    } on PivManagementKeyRefused {
      // The next kind, if any.
    }
  }
  throw const PivManagementKeyRefused();
}

/// Erases the PIV application of the card of [session]: every key and
/// certificate, with the PIN, the PUK and the management key back to the
/// factory ones. The maker's reset is taken only once the PIN and the PUK
/// are both blocked, so wrong ones are sent until each counter is at
/// zero, and then the reset. [session] is read again afterwards.
///
/// Call it only on a card that answered the maker's commands
/// ([PivState.makerCommands]): any other would be left with both codes
/// blocked and no reset.
Future<void> pivReset(PivSession session) async {
  if (!session.state.makerCommands) throw const PivNotSupported();
  // Two wrong codes: if the first happens to be the right one, the second is not.
  const wrongPins = ['00000000', '11111111'];
  const wrongPuks = ['00000000', '11111111'];
  var pin = 0;
  var puk = 0;
  var pinBlocked = false;
  // A PIN or PUK has 255 tries at most; this is far more than the two counters together.
  for (var i = 0; i < 600; i++) {
    if (!pinBlocked) {
      try {
        await session.card.verifyPin(wrongPins[pin].codeUnits);
        // It was the PIN: the counter is full again, and the other code is wrong.
        pin = 1 - pin;
      } on PivWrongCode {
        // One try fewer.
      } on PivBlocked {
        pinBlocked = true;
      }
      continue;
    }
    try {
      await session.card.unblockPin(wrongPuks[puk].codeUnits, wrongPins[pin].codeUnits);
      // It was the PUK: the PIN is unblocked again and set to a code that is then sent wrong.
      puk = 1 - puk;
      pin = 1 - pin;
      pinBlocked = false;
    } on PivWrongCode {
      // One try fewer.
    } on PivBlocked {
      await session.card.reset();
      await session.refresh();
      return;
    }
  }
  throw const PivRefused(0x6985);
}
