/// The messages of Yubico's OATH application (YKOATH,
/// https://developers.yubico.com/OATH/YKOATH_Protocol.html): the commands
/// as bytes and the answers read back (openspec: add-security-key-codes,
/// decision 1). Nothing here talks to a key; `oath_session.dart` does.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import '../apdu.dart';

/// The identifier of the OATH application.
const oathAid = [0xa0, 0x00, 0x00, 0x05, 0x27, 0x21, 0x01];

/// The instructions.
abstract final class OathIns {
  static const put = 0x01;
  static const delete = 0x02;
  static const setCode = 0x03;
  static const reset = 0x04;
  static const list = 0xa1;
  static const calculate = 0xa2;
  static const validate = 0xa3;
  static const calculateAll = 0xa4;
  static const sendRemaining = 0xa5;
}

/// The tags of the values the messages carry.
abstract final class OathTag {
  static const name = 0x71;
  static const nameList = 0x72;
  static const key = 0x73;
  static const challenge = 0x74;
  static const response = 0x75;
  static const truncated = 0x76;
  static const hotp = 0x77;
  static const property = 0x78;
  static const version = 0x79;
  static const imf = 0x7a;
  static const algorithm = 0x7b;
  static const touch = 0x7c;
}

/// The status words the application answers with.
abstract final class OathSw {
  static const noSpace = 0x6a84;
  static const authRequired = 0x6982;
  static const noSuchObject = 0x6984;
  static const wrongSyntax = 0x6a80;
  static const generic = 0x6581;
}

/// The longest name the key takes, in bytes of UTF-8.
const oathNameMax = 64;

/// The shortest secret the key takes; a shorter one is padded with zeros,
/// which an HMAC key is anyway.
const oathSecretMin = 14;

/// What went wrong with the code application.
enum OathFailure {
  /// An answer that is not what the protocol says: this is not Yubico's
  /// OATH application, or the answer was damaged.
  malformed,

  /// The application has a password and it was not proved yet.
  passwordNeeded,

  /// The key refused the proof of the password.
  wrongPassword,

  /// The key accepted the password and its own proof did not check out.
  untrustedKey,

  /// The account needs a touch and none came in time.
  notTouched,

  /// The key has no room for another account.
  full,

  /// The key has no account of that name.
  noSuchAccount,

  /// The key could not read the command.
  wrongSyntax,

  /// Any other refusal; [OathError.sw] says which.
  refused,
}

class OathError implements Exception {
  const OathError(this.failure, {this.sw});

  final OathFailure failure;

  /// The status word behind it, when the key gave one.
  final int? sw;

  @override
  String toString() => 'OathError(${failure.name}${sw == null ? '' : ', ${sw!.toRadixString(16).padLeft(4, '0')}'})';
}

const _malformed = OathError(OathFailure.malformed);

/// Counter-based (RFC 4226) or time-based (RFC 6238).
enum OathType {
  hotp(0x10),
  totp(0x20);

  const OathType(this.bits);

  final int bits;

  static OathType? of(int byte) => switch (byte & 0xf0) {
    0x10 => hotp,
    0x20 => totp,
    _ => null,
  };
}

enum OathAlgorithm {
  sha1(0x01, 'SHA1', 64),
  sha256(0x02, 'SHA256', 64),
  sha512(0x03, 'SHA512', 128);

  const OathAlgorithm(this.bits, this.label, this.blockSize);

  final int bits;

  /// The name an `OtpAccount` gives it.
  final String label;

  /// The block of its hash, in bytes: a longer secret is hashed first.
  final int blockSize;

  hashes.Hash get hash => switch (this) {
    sha1 => hashes.sha1,
    sha256 => hashes.sha256,
    sha512 => hashes.sha512,
  };

  static OathAlgorithm? of(int byte) => switch (byte & 0x0f) {
    0x01 => sha1,
    0x02 => sha256,
    0x03 => sha512,
    _ => null,
  };

  static OathAlgorithm? named(String label) {
    for (final algorithm in values) {
      if (algorithm.label == label) return algorithm;
    }
    return null;
  }
}

/// The application's firmware version.
class OathVersion implements Comparable<OathVersion> {
  const OathVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// SHA-512 accounts are taken from 4.3.1.
  bool get takesSha512 => compareTo(const OathVersion(4, 3, 1)) >= 0;

  /// Accounts that need a touch are taken from 4.2.4.
  bool get takesTouch => compareTo(const OathVersion(4, 2, 4)) >= 0;

  /// How many accounts a key of this firmware holds: 32, and 64 from 5.7.
  /// Only for wording the "full" message; the key's own answer is the truth.
  int get capacity => compareTo(const OathVersion(5, 7, 0)) >= 0 ? 64 : 32;

  @override
  int compareTo(OathVersion other) => major != other.major
      ? major.compareTo(other.major)
      : minor != other.minor
      ? minor.compareTo(other.minor)
      : patch.compareTo(other.patch);

  @override
  bool operator ==(Object other) => other is OathVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// What the application says of itself when it is opened.
class OathSelect {
  OathSelect({required this.version, required List<int> id, List<int>? challenge})
    : id = Uint8List.fromList(id),
      challenge = challenge == null ? null : Uint8List.fromList(challenge);

  final OathVersion version;

  /// The application's id, which its password is salted with. It changes
  /// when the application is reset.
  final Uint8List id;

  /// Present when the application has a password: what the proof is made over.
  final Uint8List? challenge;

  bool get hasPassword => challenge != null;

  /// [id] in lowercase hex: how the vault names the key.
  String get device => [for (final byte in id) byte.toRadixString(16).padLeft(2, '0')].join();
}

/// One line of LIST.
class OathListed {
  OathListed({required List<int> name, required this.type, required this.algorithm}) : name = Uint8List.fromList(name);

  /// The account's name on the key, byte for byte.
  final Uint8List name;
  final OathType type;
  final OathAlgorithm algorithm;
}

/// A code as the key gives it: the truncated number and how many digits of it count.
class OathCode {
  const OathCode(this.digits, this.value);

  final int digits;
  final int value;

  /// The digits a person types.
  String get text {
    var modulus = 1;
    for (var i = 0; i < digits && i < 10; i++) {
      modulus *= 10;
    }
    return '${digits >= 10 ? value : value % modulus}'.padLeft(digits, '0');
  }
}

/// One line of CALCULATE ALL: a code, or why there is none.
class OathCalculated {
  OathCalculated({required List<int> name, this.code, this.touch = false, this.hotp = false}) : name = Uint8List.fromList(name);

  final Uint8List name;

  /// Null for an account that needs a touch and for a counter-based one.
  final OathCode? code;
  final bool touch;
  final bool hotp;
}

/// One tag, length and value.
typedef OathTlv = ({int tag, Uint8List value});

/// [tag], the length of [value] and [value].
Uint8List oathTlv(int tag, List<int> value) {
  final length = value.length;
  if (length > 0xffff) throw ArgumentError.value(length, 'value', 'too long');
  return Uint8List.fromList([
    tag,
    if (length < 0x80) length else if (length < 0x100) ...[0x81, length] else ...[0x82, length >> 8, length & 0xff],
    ...value,
  ]);
}

/// The values of [data], one after another. Throws [OathError] with
/// [OathFailure.malformed] when a length runs past the end, so a damaged
/// answer never reads as a shorter one.
List<OathTlv> readOathTlvs(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  final out = <OathTlv>[];
  var offset = 0;
  while (offset < bytes.length) {
    if (offset + 2 > bytes.length) throw _malformed;
    final tag = bytes[offset++];
    var length = bytes[offset++];
    if (length == 0x81) {
      if (offset + 1 > bytes.length) throw _malformed;
      length = bytes[offset++];
    } else if (length == 0x82) {
      if (offset + 2 > bytes.length) throw _malformed;
      length = bytes[offset] << 8 | bytes[offset + 1];
      offset += 2;
    } else if (length >= 0x80) {
      throw _malformed;
    }
    if (offset + length > bytes.length) throw _malformed;
    out.add((tag: tag, value: Uint8List.sublistView(bytes, offset, offset + length)));
    offset += length;
  }
  return out;
}

/// Reads the answer to SELECT.
OathSelect parseOathSelect(List<int> answer) {
  OathVersion? version;
  Uint8List? id;
  Uint8List? challenge;
  for (final (:tag, :value) in readOathTlvs(answer)) {
    switch (tag) {
      case OathTag.version when value.length == 3:
        version = OathVersion(value[0], value[1], value[2]);
      case OathTag.name when value.isNotEmpty:
        id = value;
      case OathTag.challenge when value.isNotEmpty:
        challenge = value;
      case OathTag.version || OathTag.name || OathTag.challenge:
        throw _malformed;
    }
  }
  if (version == null || id == null) throw _malformed;
  return OathSelect(version: version, id: id, challenge: challenge);
}

/// Reads the answer to LIST: every account, or an error. Never part of them.
List<OathListed> parseOathList(List<int> answer) {
  final out = <OathListed>[];
  for (final (:tag, :value) in readOathTlvs(answer)) {
    final type = value.isEmpty ? null : OathType.of(value[0]);
    final algorithm = value.isEmpty ? null : OathAlgorithm.of(value[0]);
    if (tag != OathTag.nameList || value.length < 2 || type == null || algorithm == null) throw _malformed;
    out.add(OathListed(name: Uint8List.sublistView(value, 1), type: type, algorithm: algorithm));
  }
  return out;
}

OathCode _truncatedCode(Uint8List value) {
  if (value.length != 5) throw _malformed;
  return OathCode(value[0], (value[1] & 0x7f) << 24 | value[2] << 16 | value[3] << 8 | value[4]);
}

/// Reads the answer to CALCULATE: a truncated code, or a whole HMAC that
/// is truncated here as RFC 4226 says.
OathCode parseOathCalculate(List<int> answer) {
  final values = readOathTlvs(answer);
  if (values.length != 1) throw _malformed;
  final (:tag, :value) = values.single;
  if (tag == OathTag.truncated) return _truncatedCode(value);
  if (tag != OathTag.response || value.length < 21) throw _malformed;
  final offset = value.last & 0x0f;
  return _truncatedCode(Uint8List.fromList([value[0], ...value.sublist(1 + offset, 5 + offset)]));
}

/// Reads the answer to CALCULATE ALL: a name, then its code or the reason
/// it has none, for every account.
List<OathCalculated> parseOathCalculateAll(List<int> answer) {
  final values = readOathTlvs(answer);
  if (values.length.isOdd) throw _malformed;
  final out = <OathCalculated>[];
  for (var i = 0; i < values.length; i += 2) {
    final name = values[i];
    final result = values[i + 1];
    if (name.tag != OathTag.name || name.value.isEmpty) throw _malformed;
    out.add(switch (result.tag) {
      OathTag.truncated => OathCalculated(name: name.value, code: _truncatedCode(result.value)),
      OathTag.response => OathCalculated(name: name.value, code: parseOathCalculate(oathTlv(result.tag, result.value))),
      OathTag.touch => OathCalculated(name: name.value, touch: true),
      OathTag.hotp => OathCalculated(name: name.value, hotp: true),
      _ => throw _malformed,
    });
  }
  return out;
}

/// Reads the answer to VALIDATE: the key's own proof.
Uint8List parseOathValidate(List<int> answer) {
  final values = readOathTlvs(answer);
  if (values.length != 1 || values.single.tag != OathTag.response || values.single.value.isEmpty) throw _malformed;
  return values.single.value;
}

/// A time step or a counter as the eight bytes a code is made over.
Uint8List oathChallenge(int counter) {
  final bytes = Uint8List(8);
  var rest = counter;
  for (var i = 7; i >= 0; i--) {
    bytes[i] = rest & 0xff;
    rest >>= 8;
  }
  return bytes;
}

/// [secret] as the key stores it: hashed when longer than the hash's
/// block, padded with zeros to [oathSecretMin] bytes when shorter, as
/// Yubico's apps do. An HMAC with either is the HMAC with [secret].
Uint8List oathSecret(List<int> secret, OathAlgorithm algorithm) {
  final key = secret.length > algorithm.blockSize ? algorithm.hash.convert(secret).bytes : secret;
  if (key.length >= oathSecretMin) return Uint8List.fromList(key);
  return Uint8List(oathSecretMin)..setAll(0, key);
}

ApduCommand oathListCommand() => ApduCommand(ins: OathIns.list, le: apduShortLe);

/// CALCULATE for the account [name], over [challenge], answered truncated.
ApduCommand oathCalculateCommand(List<int> name, List<int> challenge) => ApduCommand(
  ins: OathIns.calculate,
  p2: 0x01,
  data: [...oathTlv(OathTag.name, name), ...oathTlv(OathTag.challenge, challenge)],
  le: apduShortLe,
);

/// CALCULATE ALL over [challenge], answered truncated.
ApduCommand oathCalculateAllCommand(List<int> challenge) =>
    ApduCommand(ins: OathIns.calculateAll, p2: 0x01, data: oathTlv(OathTag.challenge, challenge), le: apduShortLe);

/// PUT: a new account, or a new secret for the name. [secret] is the raw
/// secret; [counter] is where a counter-based account starts.
ApduCommand oathPutCommand({
  required List<int> name,
  required OathType type,
  required OathAlgorithm algorithm,
  required int digits,
  required List<int> secret,
  bool touch = false,
  int counter = 0,
}) => ApduCommand(
  ins: OathIns.put,
  data: [
    ...oathTlv(OathTag.name, name),
    ...oathTlv(OathTag.key, [type.bits | algorithm.bits, digits, ...oathSecret(secret, algorithm)]),
    // The property is a tag and one byte, with no length.
    if (touch) ...[OathTag.property, 0x02],
    if (type == OathType.hotp && counter > 0)
      ...oathTlv(OathTag.imf, [counter >> 24 & 0xff, counter >> 16 & 0xff, counter >> 8 & 0xff, counter & 0xff]),
  ],
);

ApduCommand oathDeleteCommand(List<int> name) => ApduCommand(ins: OathIns.delete, data: oathTlv(OathTag.name, name));

/// SET CODE: [accessKey] becomes what proves the password, with a
/// [challenge] of this side's and the [response] to it made with the key.
ApduCommand oathSetCodeCommand(List<int> accessKey, List<int> challenge, List<int> response) => ApduCommand(
  ins: OathIns.setCode,
  data: [
    ...oathTlv(OathTag.key, [OathType.totp.bits | OathAlgorithm.sha1.bits, ...accessKey]),
    ...oathTlv(OathTag.challenge, challenge),
    ...oathTlv(OathTag.response, response),
  ],
);

/// SET CODE with an empty key: the password is removed.
ApduCommand oathClearCodeCommand() => ApduCommand(ins: OathIns.setCode, data: oathTlv(OathTag.key, const []));

/// VALIDATE: the [response] to the key's challenge, and a [challenge] for
/// the key to answer.
ApduCommand oathValidateCommand(List<int> response, List<int> challenge) => ApduCommand(
  ins: OathIns.validate,
  data: [...oathTlv(OathTag.response, response), ...oathTlv(OathTag.challenge, challenge)],
  le: apduShortLe,
);

/// RESET: every account and the password go.
ApduCommand oathResetCommand() => ApduCommand(ins: OathIns.reset, p1: 0xde, p2: 0xad);

/// The proof of knowing [accessKey], made over [challenge].
Uint8List oathProof(List<int> accessKey, List<int> challenge) =>
    Uint8List.fromList(hashes.Hmac(hashes.sha1, accessKey).convert(challenge).bytes);

/// A name as the bytes the key keeps.
Uint8List oathNameBytes(String name) => Uint8List.fromList(utf8.encode(name));
