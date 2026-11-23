/// What a PIV card holds and how it writes it (NIST SP 800-73-4, and the
/// additions Yubico made that other makers copy): the four slots and the
/// data object of each one's certificate, the wrapping of a certificate,
/// what "metadata" says of a code or a slot, the serial and version
/// answers, and the two objects a computer knows a PIV card by.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../crypto/keys/algorithms.dart';
import '../../crypto/keys/der.dart' show bytesToBigInt;

/// The identifier of the PIV application.
const pivAid = [0xa0, 0x00, 0x00, 0x03, 0x08];

/// Bytes from a card that are not what PIV says they should be. The
/// readers here throw this and nothing else.
class PivFormatException implements Exception {
  const PivFormatException(this.message);

  final String message;

  @override
  String toString() => 'PivFormatException: $message';
}

void _check(bool condition, String message) {
  if (!condition) throw PivFormatException(message);
}

/// One of the four slots this app shows: the [key] reference commands
/// name it by, and the data [object] that holds its certificate.
enum PivSlot {
  /// 9a, PIV authentication: signing in to a computer.
  authentication(0x9a, 0x5fc105),

  /// 9c, digital signature: signing documents and mail. Wants the PIN
  /// before every signature.
  signature(0x9c, 0x5fc10a),

  /// 9d, key management: opening what was encrypted to the card.
  keyManagement(0x9d, 0x5fc10b),

  /// 9e, card authentication: proving the card is there, with no PIN.
  cardAuthentication(0x9e, 0x5fc101);

  const PivSlot(this.key, this.object);

  final int key;
  final int object;

  /// `9a`, `9c`, `9d` or `9e`, as people and tools name the slot.
  String get id => key.toRadixString(16);

  /// Whether the card wants the PIN before the slot's key signs.
  bool get needsPin => this != cardAuthentication;
}

/// The card holder unique identifier, and the capability container.
const pivChuidObject = 0x5fc102;
const pivCccObject = 0x5fc107;

/// The key references of the three codes.
const pivPinReference = 0x80;
const pivPukReference = 0x81;
const pivManagementKeyReference = 0x9b;

/// The kinds of key this app has a card generate.
enum PivAlgorithm {
  rsa2048(0x07),
  eccP256(0x11),
  eccP384(0x14);

  const PivAlgorithm(this.id);

  /// The algorithm identifier of SP 800-78-4.
  final int id;

  static PivAlgorithm? byId(int id) => values.where((algorithm) => algorithm.id == id).firstOrNull;
}

/// The kinds of management key. The standard's is triple DES; AES is
/// SP 800-78-4's, which newer cards take.
enum PivManagementKeyType {
  tripleDes(0x03, 24, 8, '3des'),
  aes128(0x08, 16, 16, 'aes128'),
  aes192(0x0a, 24, 16, 'aes192'),
  aes256(0x0c, 32, 16, 'aes256');

  const PivManagementKeyType(this.id, this.keyLength, this.blockLength, this.noteName);

  final int id;
  final int keyLength;
  final int blockLength;

  /// `3des` or `aes256`, as the vault's note names the kind.
  final String noteName;

  static PivManagementKeyType? byId(int id) => values.where((type) => type.id == id).firstOrNull;

  static PivManagementKeyType? byName(String name) => values.where((type) => type.noteName == name).firstOrNull;
}

/// The management key every manual prints: 0102030405060708, three times.
final Uint8List pivFactoryManagementKey = Uint8List.fromList([for (var i = 0; i < 24; i++) i % 8 + 1]);

/// The PIN and PUK of a card fresh from its box.
const pivFactoryPin = '123456';
const pivFactoryPuk = '12345678';

// ─── BER-TLV ──────────────────────────────────────────────────────────────────

/// One tag, length and value of a card's data. A tag of several bytes is
/// one number: `0x5fc105`, `0x7f49`.
class PivTlv {
  const PivTlv(this.tag, this.value);

  final int tag;
  final Uint8List value;
}

/// The elements of [bytes], one after another. Throws
/// [PivFormatException] for a length that runs past the end.
List<PivTlv> readPivTlvs(Uint8List bytes) {
  final out = <PivTlv>[];
  var pos = 0;
  while (pos < bytes.length) {
    var tag = bytes[pos++];
    if (tag & 0x1f == 0x1f) {
      var more = true;
      for (var count = 0; more; count++) {
        _check(pos < bytes.length && count < 3, 'tag cut short');
        tag = tag << 8 | bytes[pos];
        more = bytes[pos++] & 0x80 != 0;
      }
    }
    _check(pos < bytes.length, 'no length');
    var length = bytes[pos++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      _check(count >= 1 && count <= 3 && bytes.length - pos >= count, 'length of length');
      length = 0;
      for (var i = 0; i < count; i++) {
        length = length << 8 | bytes[pos++];
      }
    }
    _check(length <= bytes.length - pos, 'length past the end');
    out.add(PivTlv(tag, Uint8List.sublistView(bytes, pos, pos + length)));
    pos += length;
  }
  return out;
}

/// One element: [tag], the shortest length, and [value].
Uint8List pivTlv(int tag, List<int> value) {
  final length = value.length;
  return Uint8List.fromList([
    if (tag > 0xffff) tag >> 16 & 0xff,
    if (tag > 0xff) tag >> 8 & 0xff,
    tag & 0xff,
    if (length < 0x80) length else if (length < 0x100) ...[0x81, length] else ...[0x82, length >> 8, length & 0xff],
    ...value,
  ]);
}

/// The value of the one element with [tag] in [bytes], or null.
Uint8List? _find(List<PivTlv> elements, int tag) => elements.where((element) => element.tag == tag).firstOrNull?.value;

/// The three bytes that name a data object in GET DATA and PUT DATA.
List<int> pivObjectId(int object) => [object >> 16 & 0xff, object >> 8 & 0xff, object & 0xff];

// ─── Certificates ─────────────────────────────────────────────────────────────

/// The contents of a slot's certificate object for [certificate]: the
/// certificate, "not compressed", and the empty error detection code.
/// With no certificate the object is empty, which is how one is removed.
Uint8List wrapPivCertificate(Uint8List? certificate) {
  if (certificate == null || certificate.isEmpty) return Uint8List(0);
  return Uint8List.fromList([
    ...pivTlv(0x70, certificate),
    ...pivTlv(0x71, const [0]),
    ...pivTlv(0xfe, const []),
  ]);
}

/// The most a compressed certificate is unpacked to: ten times the
/// largest object a PIV card holds. A card's few kilobytes of zeros would
/// otherwise ask for as much memory as they unpack to.
const pivCertificateMost = 64 * 1024;

/// The certificate in [object], a slot's data object as GET DATA returns
/// it (`53`, its length, its contents), unpacked when the card says it is
/// compressed, to [pivCertificateMost] at most. Null for an object with
/// nothing in it: an empty slot. Throws [PivFormatException] for anything
/// else.
Uint8List? unwrapPivCertificate(Uint8List object) {
  final contents = pivObjectContents(object);
  if (contents.isEmpty) return null;
  final parts = readPivTlvs(contents);
  final certificate = _find(parts, 0x70);
  if (certificate == null || certificate.isEmpty) return null;
  final info = _find(parts, 0x71);
  if (info == null || info.isEmpty || info[0] & 0x03 == 0) return Uint8List.fromList(certificate);
  // CertInfo's low bits: 1 is gzip. Nothing else is in use.
  _check(info[0] & 0x03 == 1, 'certificate packed in a way that is not gzip');
  final out = OutputMemoryStream();
  final bool whole;
  try {
    // A stream cut short gives false, and one that unpacks past the bound throws
    whole = const GZipDecoder().decodeStream(InputMemoryStream(certificate), out, maxOutputSize: pivCertificateMost);
  } on Object {
    throw const PivFormatException('compressed certificate does not unpack');
  }
  _check(whole, 'compressed certificate cut short');
  return out.getBytes();
}

/// The contents of a data [object] as GET DATA returns it.
Uint8List pivObjectContents(Uint8List object) {
  if (object.isEmpty) return object;
  final outer = readPivTlvs(object);
  _check(outer.length == 1 && outer.single.tag == 0x53, 'not a data object');
  return outer.single.value;
}

// ─── Public keys ──────────────────────────────────────────────────────────────

/// The public key in [data], the parts a card gives after generating a
/// key and in a slot's metadata: `81` modulus and `82` exponent for RSA,
/// `86` point for the curves. [algorithm] is SP 800-78-4's identifier.
/// Null for an algorithm this app does not know.
PublicHalf? readPivPublicKey(int algorithm, Uint8List data) {
  final parts = readPivTlvs(data);
  switch (algorithm) {
    case 0x05 || 0x06 || 0x07 || 0x16:
      final n = _find(parts, 0x81);
      final e = _find(parts, 0x82);
      _check(n != null && e != null && n.isNotEmpty && e.isNotEmpty, 'RSA public key');
      return RsaPublicHalf(bytesToBigInt(n!), bytesToBigInt(e!));
    case 0x11 || 0x14:
      final curve = algorithm == 0x11 ? EcCurve.p256 : EcCurve.p384;
      final point = _find(parts, 0x86);
      _check(point != null && point.length == 1 + 2 * curve.size && point[0] == 4, 'EC public point');
      return EcPublicHalf(curve, Uint8List.fromList(point!));
    default:
      return null;
  }
}

/// The public key in a card's answer to GENERATE ASYMMETRIC KEY PAIR:
/// the parts above inside `7F49`.
PublicHalf readPivGeneratedKey(PivAlgorithm algorithm, Uint8List answer) {
  final outer = readPivTlvs(answer);
  _check(outer.length == 1 && outer.single.tag == 0x7f49, 'not a generated key');
  return readPivPublicKey(algorithm.id, outer.single.value)!;
}

// ─── The maker's answers ──────────────────────────────────────────────────────

/// What a card says of a code or a slot when asked for its metadata.
class PivMetadata {
  const PivMetadata({this.algorithm, this.isDefault, this.totalTries, this.triesLeft, this.generated, this.publicKey});

  /// Reads a metadata answer. Parts it does not know are skipped.
  factory PivMetadata.parse(Uint8List answer) {
    final parts = readPivTlvs(answer);
    final algorithm = _find(parts, 0x01);
    final origin = _find(parts, 0x03);
    final public = _find(parts, 0x04);
    final isDefault = _find(parts, 0x05);
    final tries = _find(parts, 0x06);
    _check(tries == null || tries.length == 2, 'tries in metadata');
    return PivMetadata(
      algorithm: algorithm == null || algorithm.isEmpty ? null : algorithm[0],
      isDefault: isDefault == null || isDefault.isEmpty ? null : isDefault[0] != 0,
      totalTries: tries?[0],
      triesLeft: tries?[1],
      generated: origin == null || origin.isEmpty ? null : origin[0] == 1,
      publicKey: algorithm == null || algorithm.isEmpty || public == null ? null : readPivPublicKey(algorithm[0], public),
    );
  }

  /// SP 800-78-4's identifier of the key's kind: of the management key, or
  /// of a slot's key (`0xff` for the PIN and the PUK).
  final int? algorithm;

  /// Whether a code is still the factory one.
  final bool? isDefault;

  /// How many tries a PIN or PUK has when full, and how many are left.
  final int? totalTries;
  final int? triesLeft;

  /// Whether a slot's key was made on the card.
  final bool? generated;

  /// A slot's public key.
  final PublicHalf? publicKey;
}

/// The firmware version a card gives: three bytes.
({int major, int minor, int patch}) readPivVersion(Uint8List answer) {
  _check(answer.length == 3, 'version');
  return (major: answer[0], minor: answer[1], patch: answer[2]);
}

/// The serial number a card gives: four bytes, big-endian.
int readPivSerial(Uint8List answer) {
  _check(answer.length == 4, 'serial number');
  return answer[0] << 24 | answer[1] << 16 | answer[2] << 8 | answer[3];
}

// ─── The card's identifier objects ────────────────────────────────────────────

/// The contents of a card holder unique identifier with the 16-byte
/// [guid]: a FASC-N that names no agency, the identifier, an expiry date
/// in 2030, and no signature. It is the template the maker's own tools
/// write; computers read only the identifier.
Uint8List buildPivChuid(Uint8List guid) {
  if (guid.length != 16) throw ArgumentError.value(guid.length, 'guid', 'must be 16 bytes');
  return Uint8List.fromList([
    ...pivTlv(0x30, const [
      0xd4, 0xe7, 0x39, 0xda, 0x73, 0x9c, 0xed, 0x39, 0xce, 0x73, 0x9d, 0x83, 0x68, //
      0x58, 0x21, 0x08, 0x42, 0x10, 0x84, 0x21, 0xc8, 0x42, 0x10, 0xc3, 0xeb,
    ]),
    ...pivTlv(0x34, guid),
    ...pivTlv(0x35, '20300101'.codeUnits),
    ...pivTlv(0x3e, const []),
    ...pivTlv(0xfe, const []),
  ]);
}

/// The identifier in a card holder unique identifier [object] as GET DATA
/// returns it, in hex; null when the object is empty or has none.
String? readPivChuidGuid(Uint8List object) {
  final contents = pivObjectContents(object);
  if (contents.isEmpty) return null;
  final guid = _find(readPivTlvs(contents), 0x34);
  if (guid == null || guid.isEmpty) return null;
  return [for (final byte in guid) byte.toRadixString(16).padLeft(2, '0')].join();
}

/// The contents of a capability container whose card identifier ends in
/// the 14 bytes of [id], as the maker's own tools write it.
Uint8List buildPivCcc(Uint8List id) {
  if (id.length != 14) throw ArgumentError.value(id.length, 'id', 'must be 14 bytes');
  return Uint8List.fromList([
    ...pivTlv(0xf0, [0xa0, 0x00, 0x00, 0x01, 0x16, 0xff, 0x02, ...id]),
    ...pivTlv(0xf1, const [0x21]),
    ...pivTlv(0xf2, const [0x21]),
    ...pivTlv(0xf3, const []),
    ...pivTlv(0xf4, const [0x00]),
    ...pivTlv(0xf5, const [0x10]),
    for (final tag in const [0xf6, 0xf7, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe]) ...pivTlv(tag, const []),
  ]);
}

/// The card identifier in a capability container [object] as GET DATA
/// returns it, in hex: the 14 bytes that are the card's own, after the
/// maker's seven. Null when the object is empty or has none.
String? readPivCccId(Uint8List object) {
  final contents = pivObjectContents(object);
  if (contents.isEmpty) return null;
  final id = _find(readPivTlvs(contents), 0xf0);
  if (id == null || id.isEmpty) return null;
  return [for (final byte in id.length > 14 ? id.sublist(id.length - 14) : id) byte.toRadixString(16).padLeft(2, '0')].join();
}
