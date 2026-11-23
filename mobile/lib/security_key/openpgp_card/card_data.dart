/// The data objects of a security key's OpenPGP card application, as
/// values read from the card's bytes (openspec: add-openpgp-card, design
/// decision 3). It follows version 3.4 of the OpenPGP Smart Card
/// Application specification and reads version 2 cards, which lack some
/// objects: an object the card does not have is null here, and nothing is
/// guessed in its place.
///
/// Everything here throws [CardFormatError] and nothing else for bytes it
/// cannot read.
library;

import 'dart:typed_data';

import '../../crypto/keys/der.dart' show decodeOid;
import '../../crypto/keys/key_error.dart';

/// The OpenPGP card application's identifier (RID `D276000124`, PIX `01`),
/// as it is selected: the version, maker and serial follow it on the card.
const openPgpAid = [0xd2, 0x76, 0x00, 0x01, 0x24, 0x01];

/// The most bytes an object is taken in: the longest a card answers.
const maxCardObject = 65535;

/// A card's answer that does not read as the object it should be.
class CardFormatError implements Exception {
  const CardFormatError(this.message);

  final String message;

  @override
  String toString() => 'CardFormatError: $message';
}

Never _bad(String message) => throw CardFormatError(message);

void _need(bool condition, String message) {
  if (!condition) _bad(message);
}

/// [bytes] in upper-case hexadecimal, as GnuPG prints card data.
String cardHex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join().toUpperCase();

// ─── BER-TLV ──────────────────────────────────────────────────────────────────

/// One BER-TLV data object: its tag (one or two bytes, as a number) and
/// its value.
class Tlv {
  const Tlv(this.tag, this.value);

  final int tag;
  final Uint8List value;

  /// Whether the value holds more objects.
  bool get constructed => (tag > 0xff ? tag >> 8 : tag) & 0x20 != 0;

  /// The objects inside a constructed object.
  List<Tlv> get children => constructed ? parseTlvs(value) : const [];
}

/// The data objects in [bytes], one after the other. Throws
/// [CardFormatError] for a tag or a length cut short and for a length past
/// the end.
List<Tlv> parseTlvs(List<int> bytes) {
  _need(bytes.length <= maxCardObject + 8, 'object over ${maxCardObject + 8} bytes');
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final out = <Tlv>[];
  var pos = 0;
  while (pos < data.length) {
    // Padding between objects (ISO 7816-4 section 5.2.2)
    if (data[pos] == 0x00 || data[pos] == 0xff) {
      pos++;
      continue;
    }
    var tag = data[pos++];
    if (tag & 0x1f == 0x1f) {
      _need(pos < data.length, 'tag cut short');
      final next = data[pos++];
      _need(next & 0x80 == 0, 'tag of more than two bytes');
      tag = tag << 8 | next;
    }
    _need(pos < data.length, 'length cut short');
    var length = data[pos++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      _need(count >= 1 && count <= 3, 'length of $count bytes');
      _need(pos + count <= data.length, 'length cut short');
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length << 8 | data[pos++];
      }
    }
    _need(length <= data.length - pos, 'value of ${tag.toRadixString(16)} cut short');
    out.add(Tlv(tag, Uint8List.sublistView(data, pos, pos + length)));
    pos += length;
  }
  return out;
}

/// The first object of [tag] among [objects], or inside them, depth first.
Tlv? findTlv(List<Tlv> objects, int tag) {
  for (final object in objects) {
    if (object.tag == tag) return object;
    if (object.constructed) {
      final inner = findTlv(object.children, tag);
      if (inner != null) return inner;
    }
  }
  return null;
}

/// The value of the object [tag] in [bytes], or the bytes themselves when
/// they are that value already: a card may answer GET DATA either way.
Uint8List unwrapTlv(Uint8List bytes, int tag) {
  if (bytes.isEmpty) return bytes;
  try {
    final objects = parseTlvs(bytes);
    if (objects.length == 1 && objects.single.tag == tag) return objects.single.value;
  } on CardFormatError {
    // Not an object: the value as it is
  }
  return bytes;
}

/// The bytes of a data object: [tag], the shortest length, and [value].
Uint8List encodeTlv(int tag, List<int> value) {
  final length = value.length;
  return Uint8List.fromList([
    if (tag > 0xff) tag >> 8,
    tag & 0xff,
    if (length < 0x80)
      length
    else if (length < 0x100) ...[
      0x81,
      length,
    ] else if (length < 0x10000) ...[
      0x82,
      length >> 8,
      length & 0xff,
    ] else ...[
      0x83,
      length >> 16,
      (length >> 8) & 0xff,
      length & 0xff,
    ],
    ...value,
  ]);
}

// ─── The three places ─────────────────────────────────────────────────────────

/// One of the card's three key places, with the tags of everything about it.
enum CardPlace {
  signature(crt: 0xb6, attributes: 0xc1, fingerprint: 0xc7, time: 0xce, touch: 0xd6, keyRef: 0x01, letter: 'S'),
  decryption(crt: 0xb8, attributes: 0xc2, fingerprint: 0xc8, time: 0xcf, touch: 0xd7, keyRef: 0x02, letter: 'D'),
  authentication(crt: 0xa4, attributes: 0xc3, fingerprint: 0xc9, time: 0xd0, touch: 0xd8, keyRef: 0x03, letter: 'A');

  const CardPlace({
    required this.crt,
    required this.attributes,
    required this.fingerprint,
    required this.time,
    required this.touch,
    required this.keyRef,
    required this.letter,
  });

  /// The control reference template that names it in GENERATE and import.
  final int crt;

  /// The tag of its algorithm attributes.
  final int attributes;

  /// The tags PUT DATA writes its fingerprint and creation time to.
  final int fingerprint;
  final int time;

  /// The tag of its touch setting (user interaction flag).
  final int touch;

  /// Its key reference in key information.
  final int keyRef;

  /// The letter on its tile.
  final String letter;

  /// Whether it signs (signature and authentication) rather than decrypts.
  bool get signs => this != decryption;

  /// The place whose algorithm attributes have [tag].
  static CardPlace? ofAttributesTag(int tag) => values.where((p) => p.attributes == tag).firstOrNull;
}

// ─── Application identifier ───────────────────────────────────────────────────

/// The full application identifier: version, maker and serial number.
class CardAid {
  CardAid(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    _need(bytes.length == 16, 'application identifier of ${bytes.length} bytes');
    for (var i = 0; i < openPgpAid.length; i++) {
      _need(bytes[i] == openPgpAid[i], 'not an OpenPGP application identifier');
    }
  }

  final Uint8List bytes;

  int get versionMajor => _bcd(bytes[6]);
  int get versionMinor => _bcd(bytes[7]);

  /// `3.4`.
  String get version => '$versionMajor.$versionMinor';

  /// The maker's number (`0006` for Yubico).
  int get manufacturer => bytes[8] << 8 | bytes[9];

  /// The serial number, eight hexadecimal digits.
  String get serial => cardHex(bytes.sublist(10, 14));

  /// The serial in two groups, as the app shows it: `1234 5678`.
  String get groupedSerial => '${serial.substring(0, 4)} ${serial.substring(4)}';

  /// The 32 hexadecimal digits the vault keeps.
  String get hex => cardHex(bytes);

  /// Whether the card is of version 3 or later.
  bool get isV3 => versionMajor >= 3;

  static int _bcd(int b) => (b >> 4) * 10 + (b & 0x0f);
}

/// What a card's maker is called, for the few that are common; null for
/// another, which is shown by its number. Nothing is decided by it.
String? cardMakerName(int manufacturer) => switch (manufacturer) {
  0x0001 => 'PPC Card Systems',
  0x0005 => 'ZeitControl',
  0x0006 => 'Yubico',
  0x000f => 'Nitrokey',
  0x002a => 'Magrathea',
  0xf1d0 => 'CanoKeys',
  0x0000 || 0xffff => 'Test card',
  _ => null,
};

// ─── Algorithm attributes ─────────────────────────────────────────────────────

/// OpenPGP's algorithm numbers as the card uses them.
abstract final class CardAlgorithmId {
  static const rsa = 0x01;
  static const ecdh = 0x12;
  static const ecdsa = 0x13;
  static const eddsa = 0x16;
}

/// The names GnuPG gives the curves, by OID.
const _curveNames = {
  '1.3.6.1.4.1.11591.15.1': 'ed25519',
  '1.3.6.1.4.1.3029.1.5.1': 'cv25519',
  '1.3.101.112': 'ed25519',
  '1.3.101.110': 'cv25519',
  '1.3.101.113': 'ed448',
  '1.3.101.111': 'cv448',
  '1.2.840.10045.3.1.7': 'nistp256',
  '1.3.132.0.34': 'nistp384',
  '1.3.132.0.35': 'nistp521',
  '1.3.36.3.3.2.8.1.1.7': 'brainpoolP256r1',
  '1.3.36.3.3.2.8.1.1.11': 'brainpoolP384r1',
  '1.3.36.3.3.2.8.1.1.13': 'brainpoolP512r1',
  '1.3.132.0.10': 'secp256k1',
};

/// How a place's key is made: its algorithm and size or curve.
sealed class CardAlgorithm {
  const CardAlgorithm(this.bytes);

  /// Reads algorithm attributes as the card gives them.
  factory CardAlgorithm.parse(List<int> bytes) {
    _need(bytes.isNotEmpty, 'empty algorithm attributes');
    final data = Uint8List.fromList(bytes);
    switch (data[0]) {
      case CardAlgorithmId.rsa:
        _need(data.length >= 5 && data.length <= 6, 'RSA attributes of ${data.length} bytes');
        return RsaAttributes._(data);
      case CardAlgorithmId.ecdh || CardAlgorithmId.ecdsa || CardAlgorithmId.eddsa:
        _need(data.length >= 2 && data.length <= 32, 'curve attributes of ${data.length} bytes');
        return EccAttributes._(data);
      default:
        return OtherAttributes._(data);
    }
  }

  /// The attributes as the card holds them, for PUT DATA.
  final Uint8List bytes;

  int get id => bytes[0];

  /// GnuPG's name for it: `rsa2048`, `ed25519`, `cv25519`, `nistp256`,
  /// `brainpoolP256r1`, or `algorithm <n>`.
  String get name;

  /// Whether Kemlock signs or decrypts with a key of this kind (design
  /// decision 7): Ed25519 with Curve25519, RSA from 2048 bits, and NIST
  /// P-256 and P-384.
  bool get usable;

  /// Whether a key of this kind can sit in [place].
  bool fits(CardPlace place);

  @override
  bool operator ==(Object other) => other is CardAlgorithm && _same(bytes, other.bytes);

  @override
  int get hashCode => Object.hashAll(bytes);
}

/// RSA: the modulus and exponent sizes, and the form an imported key takes.
final class RsaAttributes extends CardAlgorithm {
  RsaAttributes._(super.bytes);

  /// The attributes of an RSA key of [bits], with a 32-bit exponent and the
  /// standard import form, as cards are set for RSA.
  factory RsaAttributes.ofBits(int bits) => RsaAttributes._(Uint8List.fromList([1, bits >> 8, bits & 0xff, 0, 32, 0]));

  int get modulusBits => bytes[1] << 8 | bytes[2];
  int get exponentBits => bytes[3] << 8 | bytes[4];

  /// 0: e, p and q; 1: the same and the modulus; 2: the CRT form (e, p, q,
  /// 1/q mod p, d mod p-1, d mod q-1); 3: CRT and the modulus.
  int get importFormat => bytes.length > 5 ? bytes[5] : 0;

  bool get crt => importFormat == 2 || importFormat == 3;
  bool get withModulus => importFormat == 1 || importFormat == 3;

  @override
  String get name => 'rsa$modulusBits';

  @override
  bool get usable => modulusBits >= 2048 && modulusBits <= 4096;

  @override
  bool fits(CardPlace place) => true;
}

/// A key on a curve: ECDH, ECDSA or EdDSA, and the curve's OID.
final class EccAttributes extends CardAlgorithm {
  EccAttributes._(super.bytes);

  /// The attributes for [id] on the curve whose OID content is [oid].
  factory EccAttributes.of(int id, List<int> oid) => EccAttributes._(Uint8List.fromList([id, ...oid]));

  /// Whether an imported key carries its public point too (a trailing
  /// `FF`).
  bool get withPublicKey => bytes.length > 2 && bytes.last == 0xff;

  /// The curve's OID content, without tag or length.
  Uint8List get oid => Uint8List.sublistView(bytes, 1, withPublicKey ? bytes.length - 1 : bytes.length);

  /// The curve's OID in dotted form, or the bytes in hexadecimal when they
  /// are no OID.
  String get oidDotted {
    try {
      return decodeOid(oid);
    } on KeyFormatException {
      return cardHex(oid);
    }
  }

  /// GnuPG's name for the curve.
  String get curve => _curveNames[oidDotted] ?? oidDotted;

  @override
  String get name => curve;

  @override
  bool get usable => switch ((id, curve)) {
    (CardAlgorithmId.eddsa, 'ed25519') => true,
    (CardAlgorithmId.ecdh, 'cv25519') => true,
    (CardAlgorithmId.ecdsa || CardAlgorithmId.ecdh, 'nistp256' || 'nistp384') => true,
    _ => false,
  };

  @override
  bool fits(CardPlace place) => place == CardPlace.decryption ? id == CardAlgorithmId.ecdh : id != CardAlgorithmId.ecdh;
}

/// An algorithm the specification does not define.
final class OtherAttributes extends CardAlgorithm {
  OtherAttributes._(super.bytes);

  @override
  String get name => 'algorithm ${bytes[0]}';

  @override
  bool get usable => false;

  @override
  bool fits(CardPlace place) => false;
}

/// The name people read for [algorithm]: `RSA 2048`, `Ed25519`,
/// `Curve25519`, `NIST P-256`, `brainpoolP256r1`.
String cardAlgorithmLabel(CardAlgorithm algorithm) => switch (algorithm.name) {
  'ed25519' => 'Ed25519',
  'cv25519' => 'Curve25519',
  'ed448' => 'Ed448',
  'cv448' => 'X448',
  'nistp256' => 'NIST P-256',
  'nistp384' => 'NIST P-384',
  'nistp521' => 'NIST P-521',
  'secp256k1' => 'secp256k1',
  final name when algorithm is RsaAttributes => 'RSA ${name.substring(3)}',
  final name => name,
};

// ─── PIN status ───────────────────────────────────────────────────────────────

/// The PIN status bytes (`C4`): how often the PIN is asked, the longest
/// each PIN may be, and the tries each has left.
class PinStatus {
  PinStatus(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    _need(bytes.length == 7, 'PIN status of ${bytes.length} bytes');
  }

  final Uint8List bytes;

  /// Whether the PIN is good for one signature only (`00`), rather than for
  /// as many as are made in one connection (`01`).
  bool get pinForEverySignature => bytes[0] == 0;

  int get pinMaxLength => bytes[1] & 0x7f;
  int get resetCodeMaxLength => bytes[2];
  int get adminPinMaxLength => bytes[3] & 0x7f;

  int get pinTries => bytes[4];
  int get resetCodeTries => bytes[5];
  int get adminPinTries => bytes[6];

  /// Whether a reset code is set: a card without one has no tries for it.
  bool get resetCodeSet => resetCodeTries > 0;
}

// ─── Key information and touch ────────────────────────────────────────────────

/// Whether a place holds a key and how it got there (key information,
/// `DE`, version 3 cards).
enum CardKeyOrigin { none, generated, imported }

/// Key information: each place's [CardKeyOrigin], by key reference.
class KeyInformation {
  KeyInformation(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    _need(bytes.length.isEven, 'key information of ${bytes.length} bytes');
  }

  final Uint8List bytes;

  CardKeyOrigin? of(CardPlace place) {
    for (var i = 0; i < bytes.length; i += 2) {
      if (bytes[i] == place.keyRef) {
        return switch (bytes[i + 1]) {
          0 => CardKeyOrigin.none,
          1 => CardKeyOrigin.generated,
          2 => CardKeyOrigin.imported,
          _ => null,
        };
      }
    }
    return null;
  }
}

/// A place's touch setting (user interaction flag): whether the card waits
/// for a touch of the key before using it.
enum TouchPolicy {
  off(0x00),
  on(0x01),

  /// On, and cannot be turned off but by a factory reset.
  fixed(0x02),

  /// On, and one touch is good for 15 seconds.
  cached(0x03),

  /// [cached], and cannot be turned off but by a factory reset.
  cachedFixed(0x04);

  const TouchPolicy(this.code);

  final int code;

  bool get permanent => this == fixed || this == cachedFixed;
  bool get needsTouch => this != off;

  static TouchPolicy? ofCode(int code) => values.where((p) => p.code == code).firstOrNull;
}

/// A place's touch setting as the card reports it.
class TouchSetting {
  TouchSetting(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    _need(bytes.length == 2, 'touch setting of ${bytes.length} bytes');
  }

  final Uint8List bytes;

  /// Null for a value the specification does not define.
  TouchPolicy? get policy => TouchPolicy.ofCode(bytes[0]);

  /// The second byte: `20` when the key has a button to touch.
  int get feature => bytes[1];
}

// ─── Hashed PINs (KDF) ────────────────────────────────────────────────────────

/// The KDF object (`F9`): whether the card wants its PINs hashed before
/// they are sent, and how.
class KdfSetting {
  KdfSetting._(this.bytes, this.algorithm, this.hash, this.count, this.saltPin, this.saltResetCode, this.saltAdmin);

  /// Reads the object's value, or the object itself with its `F9` around
  /// it.
  factory KdfSetting.parse(List<int> bytes) {
    final data = unwrapTlv(Uint8List.fromList(bytes), 0xf9);
    final objects = parseTlvs(data);
    Uint8List? value(int tag) => objects.where((o) => o.tag == tag).firstOrNull?.value;
    final algorithm = value(0x81);
    _need(algorithm != null && algorithm.length == 1, 'KDF object without its algorithm');
    final hash = value(0x82);
    final count = value(0x83);
    _need(hash == null || hash.length == 1, 'KDF hash of ${hash?.length} bytes');
    _need(count == null || count.length == 4, 'KDF count of ${count?.length} bytes');
    return KdfSetting._(
      data,
      algorithm![0],
      hash?[0],
      count == null ? null : (count[0] << 24 | count[1] << 16 | count[2] << 8 | count[3]),
      value(0x84),
      value(0x85),
      value(0x86),
    );
  }

  final Uint8List bytes;

  /// `00` for none, `03` for iterated and salted hashing.
  final int algorithm;

  /// `08` for SHA-256, `0A` for SHA-512.
  final int? hash;

  /// How many bytes are hashed.
  final int? count;
  final Uint8List? saltPin;
  final Uint8List? saltResetCode;
  final Uint8List? saltAdmin;

  /// Whether the PINs are hashed.
  bool get on => algorithm != 0;

  /// Whether Kemlock can hash the way the object says: off, or iterated
  /// and salted SHA-256 or SHA-512 with a count and a salt for the PIN and
  /// the admin PIN. A PIN is never sent to a card whose object this is not.
  bool get readable =>
      !on ||
      (algorithm == 3 &&
          (hash == 0x08 || hash == 0x0a) &&
          count != null &&
          count! > 0 &&
          count! <= 0x10000000 &&
          saltPin != null &&
          saltAdmin != null);
}

// ─── Extended capabilities and the rest ──────────────────────────────────────

/// What the card says it can do (`C0`).
class ExtendedCapabilities {
  ExtendedCapabilities(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    _need(bytes.isNotEmpty && bytes.length <= 10, 'extended capabilities of ${bytes.length} bytes');
  }

  final Uint8List bytes;

  bool get secureMessaging => bytes[0] & 0x80 != 0;
  bool get getChallenge => bytes[0] & 0x40 != 0;
  bool get keyImport => bytes[0] & 0x20 != 0;
  bool get pinStatusChangeable => bytes[0] & 0x10 != 0;
  bool get privateUseObjects => bytes[0] & 0x08 != 0;
  bool get algorithmAttributesChangeable => bytes[0] & 0x04 != 0;
  bool get aes => bytes[0] & 0x02 != 0;
  bool get kdf => bytes[0] & 0x01 != 0;
}

/// The historical bytes (`5F52`), for the life cycle status at their end.
class HistoricalBytes {
  HistoricalBytes(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;

  /// The life cycle status when the bytes end with one (category `00`):
  /// `05` operational, `03` initialisation; null when they give none.
  int? get lifeCycleStatus => bytes.length >= 4 && bytes[0] == 0x00 ? bytes[bytes.length - 3] : null;

  /// Whether the card says it can be terminated and activated again,
  /// which is what a factory reset needs.
  bool get lifeCycleManagement => lifeCycleStatus == 0x05 || lifeCycleStatus == 0x03;
}

/// The application related data (`6E`): everything about the keys that
/// one GET DATA gives.
class ApplicationData {
  ApplicationData._({
    required this.aid,
    required this.pinStatus,
    required this.attributes,
    required this.fingerprints,
    required this.times,
    this.historical,
    this.capabilities,
    this.keyInformation,
  });

  factory ApplicationData.parse(List<int> bytes) {
    final objects = parseTlvs(bytes);
    final root = objects.where((o) => o.tag == 0x6e).firstOrNull;
    final inside = root == null ? objects : root.children;
    Uint8List? value(int tag) => findTlv(inside, tag)?.value;

    final aid = value(0x4f);
    _need(aid != null, 'no application identifier');
    final status = value(0xc4);
    _need(status != null, 'no PIN status');
    final fingerprints = value(0xc5);
    _need(fingerprints != null && fingerprints.length == 60, 'fingerprints of ${fingerprints?.length} bytes');
    final times = value(0xcd);
    _need(times == null || times.length == 12, 'key times of ${times?.length} bytes');
    final historical = value(0x5f52);
    final capabilities = value(0xc0);
    final information = value(0xde);
    return ApplicationData._(
      aid: CardAid(aid!),
      pinStatus: PinStatus(status!),
      attributes: {
        for (final place in CardPlace.values)
          if (value(place.attributes) case final attributes?) place: CardAlgorithm.parse(attributes),
      },
      fingerprints: {
        for (final place in CardPlace.values)
          place: ?_nonZero(Uint8List.sublistView(fingerprints!, place.index * 20, place.index * 20 + 20)),
      },
      times: {
        if (times != null)
          for (final place in CardPlace.values) place: ?_time(Uint8List.sublistView(times, place.index * 4, place.index * 4 + 4)),
      },
      historical: historical == null ? null : HistoricalBytes(historical),
      capabilities: capabilities == null ? null : ExtendedCapabilities(capabilities),
      keyInformation: information == null ? null : KeyInformation(information),
    );
  }

  final CardAid aid;
  final PinStatus pinStatus;

  /// Each place's algorithm attributes; a version 1 card may have none.
  final Map<CardPlace, CardAlgorithm> attributes;

  /// The fingerprint written for each place that holds a key.
  final Map<CardPlace, Uint8List> fingerprints;

  /// When each place's key was made, as written with it.
  final Map<CardPlace, DateTime> times;
  final HistoricalBytes? historical;
  final ExtendedCapabilities? capabilities;
  final KeyInformation? keyInformation;

  /// The same data with [status], read later, in place of the PIN status.
  ApplicationData withPinStatus(PinStatus status) => ApplicationData._(
    aid: aid,
    pinStatus: status,
    attributes: attributes,
    fingerprints: fingerprints,
    times: times,
    historical: historical,
    capabilities: capabilities,
    keyInformation: keyInformation,
  );

  /// Whether [place] holds a key: by key information where the card has
  /// it, else by a fingerprint written for it.
  bool holdsKey(CardPlace place) {
    final origin = keyInformation?.of(place);
    if (origin != null) return origin != CardKeyOrigin.none;
    return fingerprints.containsKey(place);
  }

  static Uint8List? _nonZero(Uint8List bytes) => bytes.every((b) => b == 0) ? null : Uint8List.fromList(bytes);

  static DateTime? _time(Uint8List bytes) {
    final seconds = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
    return seconds == 0 ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }
}

/// The algorithms the card can set each place to (algorithm information,
/// `FA`, version 3.4 cards).
class AlgorithmList {
  AlgorithmList._(this.byPlace);

  factory AlgorithmList.parse(List<int> bytes) {
    var objects = parseTlvs(bytes);
    if (objects.length == 1 && objects.single.tag == 0xfa) objects = objects.single.children;
    final byPlace = <CardPlace, List<CardAlgorithm>>{};
    for (final object in objects) {
      final place = CardPlace.ofAttributesTag(object.tag);
      if (place == null) continue;
      (byPlace[place] ??= []).add(CardAlgorithm.parse(object.value));
    }
    return AlgorithmList._(byPlace);
  }

  final Map<CardPlace, List<CardAlgorithm>> byPlace;

  List<CardAlgorithm> of(CardPlace place) => byPlace[place] ?? const [];
}

/// The cardholder's name (`5B` in the cardholder related data, `65`) as
/// GnuPG writes it, `Last<<First`, turned into `First Last`; null when
/// there is none.
String? cardholderName(List<int> bytes) {
  final name = findTlv(parseTlvs(bytes), 0x5b)?.value;
  if (name == null || name.isEmpty) return null;
  final text = String.fromCharCodes(name).trim();
  if (text.isEmpty) return null;
  final parts = text.split('<<');
  return parts.length == 2 ? '${parts[1].replaceAll('<', ' ')} ${parts[0].replaceAll('<', ' ')}'.trim() : text.replaceAll('<', ' ');
}

/// The signature counter in the security support template (`93` inside
/// `7A`).
int? signatureCounter(List<int> bytes) {
  final counter = findTlv(parseTlvs(bytes), 0x93)?.value;
  if (counter == null) return null;
  _need(counter.length == 3, 'signature counter of ${counter.length} bytes');
  return counter[0] << 16 | counter[1] << 8 | counter[2];
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
