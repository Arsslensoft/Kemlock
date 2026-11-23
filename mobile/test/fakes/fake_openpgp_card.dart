import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as c;
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/crypto/keys/der.dart';
import 'package:kemlock/crypto/keys/openpgp/key_info.dart';
import 'package:kemlock/crypto/keys/openpgp/packets.dart';
import 'package:kemlock/crypto/keys/openpgp/rsa.dart' show rsaPrivate;
import 'package:kemlock/crypto/keys/openpgp/secret_key.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';
import 'package:pointycastle/export.dart' as pc;

import 'fake_security_keys.dart';

/// A key in one of the fake card's places, with what it needs to sign or
/// decipher.
sealed class FakeCardKey {
  const FakeCardKey();

  /// A new key of [algorithm], as the card's GENERATE makes one.
  static Future<FakeCardKey> generate(CardAlgorithm algorithm) async {
    final random = Random.secure();
    Uint8List bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) random.nextInt(256)]);
    switch (algorithm) {
      case RsaAttributes(:final modulusBits):
        return FakeRsaKey(generateRsa(modulusBits));
      case EccAttributes(curve: 'ed25519'):
        return FakeEd25519Key.ofSeed(bytes(32));
      case EccAttributes(curve: 'cv25519'):
        final scalar = bytes(32);
        scalar[0] &= 0xf8;
        scalar[31] = (scalar[31] & 0x7f) | 0x40;
        return FakeX25519Key.ofSecret(scalar);
      case EccAttributes(curve: 'nistp256'):
        return FakeEcKey.random(EcCurve.p256);
      case EccAttributes(curve: 'nistp384'):
        return FakeEcKey.random(EcCurve.p384);
      default:
        throw UnsupportedError('the fake card makes no ${algorithm.name} keys');
    }
  }

  /// The public key template GENERATE answers with (`7F49`).
  Future<Uint8List> publicTemplate();
}

final class FakeRsaKey extends FakeCardKey {
  const FakeRsaKey(this.material);

  final RsaMaterial material;

  int get length => (material.n.bitLength + 7) >> 3;

  @override
  Future<Uint8List> publicTemplate() async =>
      encodeTlv(0x7f49, [...encodeTlv(0x81, bigIntToBytes(material.n)), ...encodeTlv(0x82, bigIntToBytes(material.e))]);
}

final class FakeEd25519Key extends FakeCardKey {
  const FakeEd25519Key(this.seed, this.public);

  static Future<FakeEd25519Key> ofSeed(Uint8List seed) async {
    final pair = await c.Ed25519().newKeyPairFromSeed(seed);
    return FakeEd25519Key(seed, Uint8List.fromList((await pair.extractPublicKey()).bytes));
  }

  final Uint8List seed;
  final Uint8List public;

  @override
  Future<Uint8List> publicTemplate() async => encodeTlv(0x7f49, encodeTlv(0x86, public));
}

final class FakeX25519Key extends FakeCardKey {
  const FakeX25519Key(this.secret, this.public);

  /// [secret] in X25519's own byte order, as the card takes it.
  static Future<FakeX25519Key> ofSecret(Uint8List secret) async {
    final pair = await c.X25519().newKeyPairFromSeed(secret);
    return FakeX25519Key(secret, Uint8List.fromList((await pair.extractPublicKey()).bytes));
  }

  final Uint8List secret;
  final Uint8List public;

  @override
  Future<Uint8List> publicTemplate() async => encodeTlv(0x7f49, encodeTlv(0x86, public));
}

final class FakeEcKey extends FakeCardKey {
  const FakeEcKey(this.curve, this.d, this.point);

  factory FakeEcKey.random(EcCurve curve) {
    final random = Random.secure();
    while (true) {
      final d = Uint8List.fromList([for (var i = 0; i < curve.size; i++) random.nextInt(256)]);
      final scalar = bytesToBigInt(d);
      if (scalar > BigInt.zero && scalar < curve.domain.n) return FakeEcKey.ofScalar(curve, d);
    }
  }

  factory FakeEcKey.ofScalar(EcCurve curve, Uint8List d) {
    final material = ecMaterial(curve, d);
    return FakeEcKey(curve, material.d, material.point);
  }

  final EcCurve curve;
  final Uint8List d;

  /// `04`, x and y.
  final Uint8List point;

  @override
  Future<Uint8List> publicTemplate() async => encodeTlv(0x7f49, encodeTlv(0x86, point));
}

/// The secret parts of an unprotected vault PGP key, by the card place
/// each would take: its signing primary key, its newest encryption
/// subkey and an authentication subkey, each with its fingerprint and
/// time. For tests that put a key the vault holds onto the fake card.
Future<Map<CardPlace, (FakeCardKey, Uint8List, DateTime)>> fakeCardKeysOf(Uint8List transferableSecretKey) async {
  final key = readTransferableKey(transferableSecretKey);
  final packets = [
    for (final p in key.packets)
      if (p.tag == PgpTag.secretKey || p.tag == PgpTag.secretSubkey) parseKeyPacket(p),
  ];
  final infos = [key.info.primary, ...key.info.subkeys];
  final out = <CardPlace, (FakeCardKey, Uint8List, DateTime)>{};
  for (final (i, packet) in packets.indexed) {
    final info = infos[i];
    final CardPlace place;
    if (i == 0 && info.canSign) {
      place = CardPlace.signature;
    } else if (info.canEncrypt) {
      place = CardPlace.decryption;
    } else if (info.canAuthenticate) {
      place = CardPlace.authentication;
    } else if (info.canSign && !out.containsKey(CardPlace.signature)) {
      place = CardPlace.signature;
    } else {
      continue;
    }
    final FakeCardKey card = switch (unlockSecretKey(packet)) {
      RsaSecret(:final material) => FakeRsaKey(material),
      Ed25519Secret(:final seed) => await FakeEd25519Key.ofSeed(seed),
      X25519Secret(:final secret) => await FakeX25519Key.ofSecret(secret),
      _ => throw ArgumentError('no secret to put on a card'),
    };
    out[place] = (card, packet.fingerprint, info.created);
  }
  return out;
}

const _ed25519Attributes = [0x16, 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01];
const _cv25519Attributes = [0x12, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01];
const _p256 = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
const _p384 = [0x2b, 0x81, 0x04, 0x00, 0x22];

/// What a card of version 3.4 can be set to, by place: what the fake
/// offers when it has an algorithm list.
Map<CardPlace, List<CardAlgorithm>> fakeCardAlgorithms({bool rsa = true, bool curves = true}) => {
  for (final place in CardPlace.values)
    place: [
      if (rsa) ...[RsaAttributes.ofBits(2048), RsaAttributes.ofBits(3072), RsaAttributes.ofBits(4096)],
      if (curves) ...[
        CardAlgorithm.parse(place == CardPlace.decryption ? _cv25519Attributes : _ed25519Attributes),
        EccAttributes.of(place == CardPlace.decryption ? 0x12 : 0x13, _p256),
        EccAttributes.of(place == CardPlace.decryption ? 0x12 : 0x13, _p384),
      ],
    ],
};

/// The attributes of an Ed25519 key in the signature and authentication
/// places, or of a Curve25519 key in the decryption place.
CardAlgorithm fake25519(CardPlace place) => CardAlgorithm.parse(place == CardPlace.decryption ? _cv25519Attributes : _ed25519Attributes);

/// The attributes of a NIST P-256 (or, with [p384], P-384) key for [place].
CardAlgorithm fakeNist(CardPlace place, {bool p384 = false}) =>
    EccAttributes.of(place == CardPlace.decryption ? 0x12 : 0x13, p384 ? _p384 : _p256);

/// An OpenPGP card application in software, written from version 3.4 of
/// the specification (openspec: add-openpgp-card, design decision 2):
/// three places with real keys, PIN counters, the per-signature PIN mode,
/// a reset code, hashed PINs, touch settings, an algorithm list,
/// generation, import, and terminate and activate. Give it to a
/// [FakeKey]'s applets.
///
/// ```dart
/// final card = FakeOpenPgpCard();
/// await card.load(CardPlace.signature, await FakeCardKey.generate(fake25519(CardPlace.signature)));
/// phone.arrive(FakeKey(applets: [card]).device(kinds: {SecurityKeyLinkKind.nfc}));
/// expect(card.log, ['select', 'get 6e', ...]);
/// ```
class FakeOpenPgpCard extends FakeApplet {
  FakeOpenPgpCard({
    this.versionMajor = 3,
    this.versionMinor = 4,
    this.manufacturer = 0xffff,
    this.serial = 0x12345678,
    bool touchSettings = true,
    this.kdfSupported = true,
    Map<CardPlace, List<CardAlgorithm>>? algorithms,
    bool algorithmList = true,
    this.lifeCycle = true,
    this.wrongPinInStatus = false,
    CardAlgorithm? defaultAlgorithm,
  }) : _touchSettings = touchSettings && versionMajor >= 3,
       algorithms = algorithmList && (versionMajor > 3 || (versionMajor == 3 && versionMinor >= 4))
           ? (algorithms ?? fakeCardAlgorithms())
           : null,
       defaultAlgorithm = defaultAlgorithm ?? RsaAttributes.ofBits(2048) {
    _factory();
  }

  final int versionMajor;
  final int versionMinor;
  final int manufacturer;
  final int serial;
  final bool _touchSettings;
  final bool kdfSupported;

  /// What each place can be set to; null for a card without the list.
  final Map<CardPlace, List<CardAlgorithm>>? algorithms;

  /// Whether it can be terminated and activated.
  final bool lifeCycle;

  /// How a wrong PIN, admin PIN or reset code is answered. False, as the
  /// specification's status table has it and GnuPG and Yubico's tools read
  /// it: `6982`, with the tries left to be read from the PIN status, and
  /// `6983` only once none was left before the command. True, as some
  /// cards do: `63Cx` with the tries left, and `6983` with the last one.
  final bool wrongPinInStatus;

  /// What every place is set to when new.
  final CardAlgorithm defaultAlgorithm;

  static const factoryPin = '123456';
  static const factoryAdminPin = '12345678';
  static const maxTries = 3;

  // ─── What the card holds ────────────────────────────────────────────────────

  late String pin;
  late String adminPin;
  String? resetCode;
  late int pinTries;
  late int adminPinTries;
  late int resetCodeTries;
  late bool pinForEverySignature;
  final Map<CardPlace, FakeCardKey> keys = {};
  final Map<CardPlace, Uint8List> fingerprints = {};
  final Map<CardPlace, int> times = {};
  final Map<CardPlace, int> origins = {};
  final Map<CardPlace, CardAlgorithm> attributes = {};
  final Map<CardPlace, TouchPolicy> touch = {};

  /// The KDF object's value as written; `81 01 00` when the PINs are not
  /// hashed.
  late Uint8List kdf;
  bool terminated = false;
  int signatures = 0;
  String cardholder = '';
  String url = '';

  // ─── What this connection was given ─────────────────────────────────────────

  bool _pinToSign = false;
  bool _pinOther = false;
  bool _admin = false;

  // ─── What a test looks at and asks for ──────────────────────────────────────

  /// Each command, by name: `select`, `get 6e`, `verify 82`, `change 81`,
  /// `reset 00`, `put c7`, `sign`, `decipher`, `authenticate`,
  /// `generate b6`, `read b6`, `import b8`, `terminate`, `activate`.
  final List<String> log = [];

  /// Every PIN, admin PIN and reset code value as it arrived.
  final List<Uint8List> pinsSent = [];

  /// Values that must never arrive, as a plain PIN on a card that hashes.
  final Set<String> forbidden = {};

  /// The forbidden values that arrived anyway.
  final List<String> forbiddenSeen = [];

  /// The status the next VERIFY that carries a value ends with, whatever
  /// the value: a card that fails in a way of its own. It spends a try, as
  /// a card may before it fails.
  int? nextVerifyStatus;

  /// Off, a wrong PIN or admin PIN is refused without spending a try, as
  /// a broken or hostile card may.
  bool countsWrongValues = true;

  /// Signatures come back with a byte changed, as a broken card's would.
  bool corruptSignatures = false;

  /// Fingerprints written are taken and not kept, as a failing card's are.
  bool ignoreFingerprints = false;

  /// Called when a command waits for a touch of [CardPlace]'s key; its
  /// future ends the wait, a throw ends the command with that error.
  FutureOr<void> Function(CardPlace place)? onTouch;

  /// How many commands waited for a touch.
  int touches = 0;

  /// Values the card set [kdf] to before: with hashed PINs set up as
  /// another program sets them up.
  void hashPins({required int hashAlgorithm, int count = 0x30000}) {
    final saltPin = Uint8List.fromList(List.generate(8, (i) => 0x10 + i));
    final saltReset = Uint8List.fromList(List.generate(8, (i) => 0x20 + i));
    final saltAdmin = Uint8List.fromList(List.generate(8, (i) => 0x30 + i));
    kdf = Uint8List.fromList([
      ...encodeTlv(0x81, [3]),
      ...encodeTlv(0x82, [hashAlgorithm]),
      ...encodeTlv(0x83, [count >> 24 & 0xff, count >> 16 & 0xff, count >> 8 & 0xff, count & 0xff]),
      ...encodeTlv(0x84, saltPin),
      ...encodeTlv(0x85, saltReset),
      ...encodeTlv(0x86, saltAdmin),
    ]);
  }

  /// Puts [key] into [place], as GnuPG's `keytocard` would, with its
  /// [fingerprint] and [time] written.
  void load(CardPlace place, FakeCardKey key, {Uint8List? fingerprint, DateTime? time, CardAlgorithm? algorithm}) {
    keys[place] = key;
    origins[place] = 2;
    attributes[place] = algorithm ?? _attributesOf(key, place);
    if (fingerprint != null) fingerprints[place] = Uint8List.fromList(fingerprint);
    if (time != null) times[place] = time.millisecondsSinceEpoch ~/ 1000;
  }

  /// Puts each part of an unprotected vault key where it belongs.
  Future<void> loadPgpKey(Uint8List transferableSecretKey) async {
    for (final MapEntry(key: place, value: (key, fingerprint, time)) in (await fakeCardKeysOf(transferableSecretKey)).entries) {
      load(place, key, fingerprint: fingerprint, time: time);
    }
  }

  /// Sets a place's touch setting, as another program would.
  void setTouch(CardPlace place, TouchPolicy policy) => touch[place] = policy;

  /// The bytes of the card's full application identifier.
  Uint8List get fullAid => Uint8List.fromList([
    ...openPgpAid,
    _bcd(versionMajor),
    _bcd(versionMinor),
    manufacturer >> 8,
    manufacturer & 0xff,
    serial >> 24 & 0xff,
    serial >> 16 & 0xff,
    serial >> 8 & 0xff,
    serial & 0xff,
    0,
    0,
  ]);

  static int _bcd(int n) => (n ~/ 10) << 4 | n % 10;

  void _factory() {
    pin = factoryPin;
    adminPin = factoryAdminPin;
    resetCode = null;
    pinTries = maxTries;
    adminPinTries = maxTries;
    resetCodeTries = 0;
    pinForEverySignature = true;
    keys.clear();
    fingerprints.clear();
    times.clear();
    origins.clear();
    for (final place in CardPlace.values) {
      attributes[place] = place == CardPlace.decryption && defaultAlgorithm is EccAttributes ? fake25519(place) : defaultAlgorithm;
      if (_touchSettings) touch[place] = TouchPolicy.off;
    }
    kdf = Uint8List.fromList([0x81, 0x01, 0x00]);
    signatures = 0;
    cardholder = '';
    url = '';
    _forgetPins();
  }

  void _forgetPins() {
    _pinToSign = false;
    _pinOther = false;
    _admin = false;
  }

  CardAlgorithm _attributesOf(FakeCardKey key, CardPlace place) => switch (key) {
    FakeRsaKey(:final material) => RsaAttributes.ofBits(material.n.bitLength),
    FakeEd25519Key() || FakeX25519Key() => fake25519(place),
    FakeEcKey(:final curve) => fakeNist(place, p384: curve == EcCurve.p384),
  };

  // ─── FakeApplet ─────────────────────────────────────────────────────────────

  @override
  List<int> get aid => openPgpAid;

  @override
  int get selectStatus => terminated ? 0x6285 : 0x9000;

  @override
  void selected() {
    log.add('select');
    _forgetPins();
  }

  @override
  FutureOr<(List<int>, int)> command(int cla, int ins, int p1, int p2, Uint8List data) {
    if (cla & 0xef != 0) return (_none, 0x6e00);
    if (terminated && ins != 0x44) return (_none, 0x6985);
    switch (ins) {
      case 0xca:
        return _getData(p1 << 8 | p2);
      case 0xda:
        return _putData(p1 << 8 | p2, data);
      case 0xdb when p1 == 0x3f && p2 == 0xff:
        return _import(data);
      case 0x20:
        return _verify(p2, data);
      case 0x24:
        return _change(p2, data);
      case 0x2c:
        return _resetRetryCounter(p1, data);
      case 0x2a when p1 == 0x9e && p2 == 0x9a:
        return _sign(data);
      case 0x2a when p1 == 0x80 && p2 == 0x86:
        return _decipher(data);
      case 0x88:
        return _authenticate(data);
      case 0x47:
        return _generate(p1, data);
      case 0xe6:
        log.add('terminate');
        if (!lifeCycle) return (_none, 0x6d00);
        if (!_admin && adminPinTries > 0) return (_none, 0x6982);
        terminated = true;
        _forgetPins();
        return (_none, 0x9000);
      case 0x44:
        log.add('activate');
        if (!lifeCycle) return (_none, 0x6d00);
        if (terminated) {
          terminated = false;
          _factory();
        }
        return (_none, 0x9000);
      default:
        return (_none, 0x6d00);
    }
  }

  // ─── Data objects ───────────────────────────────────────────────────────────

  bool get _v3 => versionMajor >= 3;

  /// The longest PIN the card takes, as its PIN status says.
  int pinMaxLength = 0x7f;

  Uint8List _pinStatus() =>
      Uint8List.fromList([pinForEverySignature ? 0 : 1, pinMaxLength, 0x7f, 0x7f, pinTries, resetCodeTries, adminPinTries]);

  Uint8List _fingerprintBytes() => Uint8List.fromList([for (final place in CardPlace.values) ...(fingerprints[place] ?? Uint8List(20))]);

  Uint8List _timeBytes() => Uint8List.fromList([
    for (final place in CardPlace.values) ...[
      for (final shift in [24, 16, 8, 0]) ((times[place] ?? 0) >> shift) & 0xff,
    ],
  ]);

  Uint8List _capabilities() =>
      Uint8List.fromList([0x7c | (kdfSupported && _v3 ? 0x01 : 0), 0x00, 0x00, 0xff, 0x08, 0x00, 0x00, 0xff, 0x00, 0x00]);

  Uint8List _historical() => Uint8List.fromList([0x00, 0x73, 0x00, 0x00, 0xe0, lifeCycle ? 0x05 : 0x00, 0x90, 0x00]);

  Uint8List _applicationData() => encodeTlv(0x6e, [
    ...encodeTlv(0x4f, fullAid),
    ...encodeTlv(0x5f52, _historical()),
    ...encodeTlv(0x73, [
      ...encodeTlv(0xc0, _capabilities()),
      for (final place in CardPlace.values) ...encodeTlv(place.attributes, attributes[place]!.bytes),
      ...encodeTlv(0xc4, _pinStatus()),
      ...encodeTlv(0xc5, _fingerprintBytes()),
      ...encodeTlv(0xc6, Uint8List(60)),
      ...encodeTlv(0xcd, _timeBytes()),
      if (_v3)
        ...encodeTlv(0xde, [
          for (final place in CardPlace.values) ...[place.keyRef, origins[place] ?? 0],
        ]),
    ]),
  ]);

  (List<int>, int) _getData(int tag) {
    log.add('get ${tag.toRadixString(16)}');
    final Uint8List? value = switch (tag) {
      0x004f => fullAid,
      0x5f52 => _historical(),
      0x006e => _applicationData(),
      0x00c4 => _pinStatus(),
      0x0065 => encodeTlv(0x65, [...encodeTlv(0x5b, ascii.encode(cardholder)), ...encodeTlv(0x5f2d, ascii.encode('en'))]),
      0x5f50 => Uint8List.fromList(ascii.encode(url)),
      0x007a => encodeTlv(0x7a, encodeTlv(0x93, [signatures >> 16 & 0xff, signatures >> 8 & 0xff, signatures & 0xff])),
      0x00d6 || 0x00d7 || 0x00d8 when _touchSettings => () {
        final place = CardPlace.values.firstWhere((p) => p.touch == tag);
        return Uint8List.fromList([touch[place]!.code, 0x20]);
      }(),
      0x00f9 when kdfSupported && _v3 => kdf,
      0x00fa when algorithms != null => encodeTlv(0xfa, [
        for (final MapEntry(key: place, value: list) in algorithms!.entries)
          for (final algorithm in list) ...encodeTlv(place.attributes, algorithm.bytes),
      ]),
      _ => null,
    };
    if (value == null) return (_none, 0x6a88);
    return (value, 0x9000);
  }

  (List<int>, int) _putData(int tag, Uint8List data) {
    log.add('put ${tag.toRadixString(16)}');
    if (!_admin) return (_none, 0x6982);
    final place = CardPlace.values.where((p) => p.fingerprint == tag || p.time == tag || p.attributes == tag || p.touch == tag).firstOrNull;
    switch (tag) {
      case 0xc7 || 0xc8 || 0xc9:
        if (data.length != 20) return (_none, 0x6700);
        if (!ignoreFingerprints) fingerprints[place!] = Uint8List.fromList(data);
      case 0xce || 0xcf || 0xd0:
        if (data.length != 4) return (_none, 0x6700);
        times[place!] = data[0] << 24 | data[1] << 16 | data[2] << 8 | data[3];
      case 0xc1 || 0xc2 || 0xc3:
        final algorithm = CardAlgorithm.parse(data);
        final allowed = algorithms?[place!] ?? fakeCardAlgorithms()[place!]!;
        if (!allowed.contains(algorithm)) return (_none, 0x6a80);
        if (attributes[place] != algorithm) {
          // A new kind of key in a place takes the old one away
          keys.remove(place);
          origins.remove(place);
          fingerprints.remove(place);
          times.remove(place);
        }
        attributes[place!] = algorithm;
      case 0xc4:
        if (data.length != 1 || data[0] > 1) return (_none, 0x6a80);
        pinForEverySignature = data[0] == 0;
      case 0xd3:
        if (data.isEmpty) {
          resetCode = null;
          resetCodeTries = 0;
        } else {
          final code = _plain(data, _kdfSalt(0x85));
          if (code == null || code.length < 8) return (_none, 0x6a80);
          resetCode = code;
          resetCodeTries = maxTries;
        }
      case 0xd6 || 0xd7 || 0xd8 when _touchSettings:
        if (data.length != 2) return (_none, 0x6700);
        if (touch[place!]!.permanent) return (_none, 0x6985);
        final policy = TouchPolicy.ofCode(data[0]);
        if (policy == null) return (_none, 0x6a80);
        touch[place] = policy;
      case 0xf9 when kdfSupported && _v3:
        kdf = Uint8List.fromList(data);
      case 0x5b:
        cardholder = ascii.decode(data);
      case 0x5f50:
        url = ascii.decode(data);
      default:
        return (_none, 0x6a88);
    }
    return (_none, 0x9000);
  }

  // ─── PINs ───────────────────────────────────────────────────────────────────

  KdfSetting get _kdfSetting => KdfSetting.parse(kdf);

  Uint8List? _kdfSalt(int tag) => switch (tag) {
    0x84 => _kdfSetting.saltPin,
    0x85 => _kdfSetting.saltResetCode ?? _kdfSetting.saltPin,
    _ => _kdfSetting.saltAdmin,
  };

  /// What [value] stands for: a PIN typed as it is, or, when the card
  /// hashes, the PIN of those it knows whose hash it is.
  String? _plain(Uint8List value, Uint8List? salt) {
    pinsSent.add(Uint8List.fromList(value));
    final text = latin1.decode(value);
    if (forbidden.contains(text)) forbiddenSeen.add(text);
    if (!_kdfSetting.on) return utf8.decode(value, allowMalformed: true);
    // The card cannot undo a hash: it knows the values it holds, and the
    // value a test names as the next one
    for (final candidate in {pin, adminPin, ?resetCode, ...nextPins}) {
      if (_same(fakeCardKdf(candidate, _kdfSetting.hash!, _kdfSetting.count!, salt!), value)) return candidate;
    }
    return '\u0000hash';
  }

  /// PINs a test is about to set, for a card that hashes: it can only tell
  /// a new hashed PIN by trying the values it is told of.
  final Set<String> nextPins = {};

  (List<int>, int) _verify(int reference, Uint8List data) {
    log.add('verify ${reference.toRadixString(16)}');
    final admin = reference == 0x83;
    if (reference != 0x81 && reference != 0x82 && !admin) return (_none, 0x6a86);
    if (data.isEmpty) {
      final given = admin ? _admin : (reference == 0x81 ? _pinToSign : _pinOther);
      return (_none, given ? 0x9000 : 0x63c0 | (admin ? adminPinTries : pinTries));
    }
    if ((admin ? adminPinTries : pinTries) == 0) return (_none, 0x6983);
    final typed = _plain(data, _kdfSalt(admin ? 0x86 : 0x84));
    if (nextVerifyStatus case final status?) {
      nextVerifyStatus = null;
      if (admin) {
        adminPinTries--;
      } else {
        pinTries--;
      }
      return (_none, status);
    }
    if (typed != (admin ? adminPin : pin)) {
      if (admin) {
        if (countsWrongValues) adminPinTries--;
        _admin = false;
        return (_none, _wrongStatus(adminPinTries));
      }
      if (countsWrongValues) pinTries--;
      _pinToSign = _pinOther = false;
      return (_none, _wrongStatus(pinTries));
    }
    if (admin) {
      adminPinTries = maxTries;
      _admin = true;
    } else {
      pinTries = maxTries;
      if (reference == 0x81) _pinToSign = true;
      if (reference == 0x82) _pinOther = true;
    }
    return (_none, 0x9000);
  }

  int _hashLength() => _kdfSetting.hash == 0x0a ? 64 : 32;

  (List<int>, int) _change(int reference, Uint8List data) {
    log.add('change ${reference.toRadixString(16)}');
    final admin = reference == 0x83;
    if (reference != 0x81 && !admin) return (_none, 0x6a86);
    if ((admin ? adminPinTries : pinTries) == 0) return (_none, 0x6983);
    final current = admin ? adminPin : pin;
    final split = _kdfSetting.on ? _hashLength() : utf8.encode(current).length;
    if (data.length <= split) {
      pinsSent.add(Uint8List.fromList(data));
      return _wrong(admin);
    }
    final salt = _kdfSalt(admin ? 0x86 : 0x84);
    final old = _plain(Uint8List.sublistView(data, 0, split), salt);
    if (old != current) return _wrong(admin);
    final next = _plain(Uint8List.sublistView(data, split), salt);
    if (next == null || next.length < (admin ? 8 : 6)) return (_none, 0x6a80);
    if (admin) {
      adminPin = next;
      adminPinTries = maxTries;
    } else {
      pin = next;
      pinTries = maxTries;
    }
    return (_none, 0x9000);
  }

  /// The status of a wrong value that left [tries]; see [wrongPinInStatus].
  int _wrongStatus(int tries) {
    if (!wrongPinInStatus) return 0x6982;
    return tries == 0 ? 0x6983 : 0x63c0 | tries;
  }

  (List<int>, int) _wrong(bool admin) {
    if (admin) {
      adminPinTries--;
      _admin = false;
      return (_none, _wrongStatus(adminPinTries));
    }
    pinTries--;
    _pinToSign = _pinOther = false;
    return (_none, _wrongStatus(pinTries));
  }

  (List<int>, int) _resetRetryCounter(int p1, Uint8List data) {
    log.add('reset ${p1.toRadixString(16).padLeft(2, '0')}');
    String? next;
    if (p1 == 0x02) {
      if (!_admin) return (_none, 0x6982);
      next = _plain(data, _kdfSalt(0x84));
    } else if (p1 == 0x00) {
      final code = resetCode;
      if (code == null || resetCodeTries == 0) return (_none, 0x6983);
      final split = _kdfSetting.on ? _hashLength() : utf8.encode(code).length;
      if (data.length <= split || _plain(Uint8List.sublistView(data, 0, split), _kdfSalt(0x85)) != code) {
        resetCodeTries--;
        return (_none, _wrongStatus(resetCodeTries));
      }
      resetCodeTries = maxTries;
      next = _plain(Uint8List.sublistView(data, split), _kdfSalt(0x84));
    } else {
      return (_none, 0x6a86);
    }
    if (next == null || next.length < 6) return (_none, 0x6a80);
    pin = next;
    pinTries = maxTries;
    return (_none, 0x9000);
  }

  // ─── Private operations ─────────────────────────────────────────────────────

  Future<void> _touch(CardPlace place) async {
    final policy = touch[place];
    if (policy == null || !policy.needsTouch) return;
    touches++;
    await onTouch?.call(place);
  }

  Future<(List<int>, int)> _sign(Uint8List input) async {
    log.add('sign');
    if (!_pinToSign) return (_none, 0x6982);
    final key = keys[CardPlace.signature];
    if (key == null) return (_none, 0x6a88);
    await _touch(CardPlace.signature);
    if (pinForEverySignature) _pinToSign = false;
    signatures++;
    return (_corrupt(await _signWith(key, input)), 0x9000);
  }

  Future<(List<int>, int)> _authenticate(Uint8List input) async {
    log.add('authenticate');
    if (!_pinOther) return (_none, 0x6982);
    final key = keys[CardPlace.authentication];
    if (key == null) return (_none, 0x6a88);
    await _touch(CardPlace.authentication);
    return (_corrupt(await _signWith(key, input)), 0x9000);
  }

  List<int> _corrupt(List<int> signature) {
    if (!corruptSignatures) return signature;
    final out = Uint8List.fromList(signature);
    out[out.length ~/ 2] ^= 0x01;
    return out;
  }

  Future<List<int>> _signWith(FakeCardKey key, Uint8List input) async {
    switch (key) {
      case FakeRsaKey(:final material, :final length):
        // The card pads the DigestInfo it is given (PKCS#1 v1.5, type 1)
        if (input.length > length - 11) throw ArgumentError('input too long');
        final block = Uint8List(length)
          ..[1] = 1
          ..fillRange(2, length - input.length - 1, 0xff)
          ..setAll(length - input.length, input);
        return bigIntToBytes(rsaPrivate(material, bytesToBigInt(block)), length);
      case FakeEd25519Key(:final seed):
        final algorithm = c.Ed25519();
        return (await algorithm.sign(input, keyPair: await algorithm.newKeyPairFromSeed(seed))).bytes;
      case FakeEcKey(:final curve, :final d):
        final signer = pc.ECDSASigner(null, pc.HMac(pc.SHA256Digest(), 64))
          ..init(true, pc.PrivateKeyParameter<pc.ECPrivateKey>(pc.ECPrivateKey(bytesToBigInt(d), curve.domain)));
        final signature = signer.generateSignature(input) as pc.ECSignature;
        return [...bigIntToBytes(signature.r, curve.size), ...bigIntToBytes(signature.s, curve.size)];
      case FakeX25519Key():
        throw ArgumentError('an X25519 key does not sign');
    }
  }

  Future<(List<int>, int)> _decipher(Uint8List data) async {
    log.add('decipher');
    if (!_pinOther) return (_none, 0x6982);
    final key = keys[CardPlace.decryption];
    if (key == null) return (_none, 0x6a88);
    await _touch(CardPlace.decryption);
    switch (key) {
      case FakeRsaKey(:final material, :final length):
        if (data.isEmpty || data[0] != 0x00) return (_none, 0x6a80);
        final cipher = bytesToBigInt(Uint8List.sublistView(data, 1));
        if (cipher >= material.n) return (_none, 0x6a80);
        final block = bigIntToBytes(rsaPrivate(material, cipher), length);
        final end = block.indexOf(0, 2);
        if (block[0] != 0 || block[1] != 2 || end < 10) return (_none, 0x6a80);
        return (Uint8List.sublistView(block, end + 1), 0x9000);
      case FakeX25519Key(:final secret):
        final point = _ecdhPoint(data);
        if (point == null) return (_none, 0x6a80);
        final public = point.length == 33 && point[0] == 0x40 ? Uint8List.sublistView(point, 1) : point;
        if (public.length != 32) return (_none, 0x6a80);
        final shared = await c.X25519().sharedSecretKey(
          keyPair: await c.X25519().newKeyPairFromSeed(secret),
          remotePublicKey: c.SimplePublicKey(public, type: c.KeyPairType.x25519),
        );
        return (await shared.extractBytes(), 0x9000);
      case FakeEcKey(:final curve, :final d):
        final point = _ecdhPoint(data);
        if (point == null) return (_none, 0x6a80);
        final pc.ECPoint? decoded;
        try {
          decoded = curve.domain.curve.decodePoint(point);
        } on Object {
          return (_none, 0x6a80);
        }
        final shared = decoded == null ? null : decoded * bytesToBigInt(d);
        if (shared == null || shared.isInfinity) return (_none, 0x6a80);
        // The whole point, as libgcrypt gives it: 04, x and y
        return (shared.getEncoded(false), 0x9000);
      case FakeEd25519Key():
        return (_none, 0x6a80);
    }
  }

  static Uint8List? _ecdhPoint(Uint8List data) {
    try {
      return findTlv(parseTlvs(data), 0x86)?.value;
    } on CardFormatError {
      return null;
    }
  }

  // ─── Making and putting keys ────────────────────────────────────────────────

  Future<(List<int>, int)> _generate(int p1, Uint8List data) async {
    if (data.length != 2 || data[1] != 0) return (_none, 0x6a80);
    final place = CardPlace.values.where((p) => p.crt == data[0]).firstOrNull;
    if (place == null) return (_none, 0x6a80);
    if (p1 == 0x81) {
      log.add('read ${data[0].toRadixString(16)}');
      final key = keys[place];
      if (key == null) return (_none, 0x6a88);
      return (await key.publicTemplate(), 0x9000);
    }
    if (p1 != 0x80) return (_none, 0x6a86);
    log.add('generate ${data[0].toRadixString(16)}');
    if (!_admin) return (_none, 0x6982);
    final key = await FakeCardKey.generate(attributes[place]!);
    keys[place] = key;
    origins[place] = 1;
    fingerprints.remove(place);
    times.remove(place);
    return (await key.publicTemplate(), 0x9000);
  }

  Future<(List<int>, int)> _import(Uint8List data) async {
    final CardPlace? place;
    final Map<int, Uint8List> parts = {};
    try {
      final header = findTlv(parseTlvs(data), 0x4d);
      if (header == null || header.value.length < 2) return (_none, 0x6a80);
      place = CardPlace.values.where((p) => p.crt == header.value[0]).firstOrNull;
      final inside = parseTlvs(Uint8List.sublistView(header.value, 2));
      final template = inside.where((o) => o.tag == 0x7f48).firstOrNull?.value;
      final values = inside.where((o) => o.tag == 0x5f48).firstOrNull?.value;
      if (template == null || values == null) return (_none, 0x6a80);
      var t = 0;
      var v = 0;
      while (t < template.length) {
        final tag = template[t++];
        var length = template[t++];
        if (length == 0x81) {
          length = template[t++];
        } else if (length == 0x82) {
          length = template[t] << 8 | template[t + 1];
          t += 2;
        }
        if (v + length > values.length) return (_none, 0x6a80);
        parts[tag] = Uint8List.sublistView(values, v, v + length);
        v += length;
      }
    } on CardFormatError {
      return (_none, 0x6a80);
    } on RangeError {
      return (_none, 0x6a80);
    }
    log.add('import ${place?.crt.toRadixString(16)}');
    if (place == null) return (_none, 0x6a80);
    if (!_admin) return (_none, 0x6982);
    final algorithm = attributes[place]!;
    final FakeCardKey key;
    switch (algorithm) {
      case RsaAttributes(:final modulusBits):
        final e = parts[0x91], p = parts[0x92], q = parts[0x93];
        if (e == null || p == null || q == null) return (_none, 0x6a80);
        final pp = bytesToBigInt(p), qq = bytesToBigInt(q), ee = bytesToBigInt(e);
        final n = pp * qq;
        if (n.bitLength != modulusBits) return (_none, 0x6a80);
        final d = ee.modInverse((pp - BigInt.one) * (qq - BigInt.one));
        if (algorithm.crt) {
          final u = parts[0x94], dp = parts[0x95], dq = parts[0x96];
          if (u == null || dp == null || dq == null) return (_none, 0x6a80);
          if (bytesToBigInt(u) != qq.modInverse(pp) || bytesToBigInt(dp) != d % (pp - BigInt.one)) return (_none, 0x6a80);
        }
        if (algorithm.withModulus && bytesToBigInt(parts[0x97] ?? Uint8List(0)) != n) return (_none, 0x6a80);
        key = FakeRsaKey(RsaMaterial.fromPrimes(n: n, e: ee, d: d, p: pp, q: qq));
      case EccAttributes(:final curve):
        final secret = parts[0x92];
        if (secret == null) return (_none, 0x6a80);
        switch (curve) {
          case 'ed25519':
            if (secret.length != 32) return (_none, 0x6a80);
            key = await FakeEd25519Key.ofSeed(Uint8List.fromList(secret));
          case 'cv25519':
            if (secret.length != 32) return (_none, 0x6a80);
            key = await FakeX25519Key.ofSecret(Uint8List.fromList(secret));
          case 'nistp256' || 'nistp384':
            final ec = curve == 'nistp256' ? EcCurve.p256 : EcCurve.p384;
            if (secret.length != ec.size) return (_none, 0x6a80);
            key = FakeEcKey.ofScalar(ec, Uint8List.fromList(secret));
          default:
            return (_none, 0x6a80);
        }
      case OtherAttributes():
        return (_none, 0x6a80);
    }
    keys[place] = key;
    origins[place] = 2;
    fingerprints.remove(place);
    times.remove(place);
    return (_none, 0x9000);
  }
}

/// A PIN hashed as the KDF object asks (OpenPGP card 3.4, section 4.3.2):
/// the salt and the PIN repeated until [count] bytes have been hashed with
/// SHA-256 (`08`) or SHA-512 (`0A`). Written here from the specification,
/// apart from the app's code.
Uint8List fakeCardKdf(String pin, int hashAlgorithm, int count, List<int> salt) {
  final unit = [...salt, ...utf8.encode(pin)];
  final total = count < unit.length ? unit.length : count;
  final data = Uint8List(total);
  for (var i = 0; i < total; i++) {
    data[i] = unit[i % unit.length];
  }
  return Uint8List.fromList((hashAlgorithm == 0x0a ? hash.sha512 : hash.sha256).convert(data).bytes);
}

const _none = <int>[];

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
