import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';

import '../fakes/fake_fido_key.dart';
import '../fakes/fake_security_keys.dart';

export '../fakes/fake_fido_key.dart' show FakeSupport;

/// A credential a [SoftKey] made that is not discoverable: it is in no
/// list the key gives, and takes none of its passkey places.
class SoftCredential {
  SoftCredential({
    required this.id,
    required this.rpId,
    required this.withUv,
    required this.withoutUv,
    this.credProtect,
    required this.hmacSecret,
    this.discoverable = false,
    this.userId,
  });

  final Uint8List id;
  final String rpId;

  /// The secret used when the key verified its owner, and the one used
  /// when it did not. A CTAP 2.0 key has one secret: the two are the same.
  final Uint8List withUv;
  final Uint8List withoutUv;
  final int? credProtect;
  final bool hmacSecret;

  /// Whether an assertion with no allow list finds it, as a passkey is found, and names its [userId].
  final bool discoverable;
  final Uint8List? userId;
}

/// A FIDO2 key in software that makes credentials and gives secrets:
/// [FakeFidoKey] with `authenticatorMakeCredential` and
/// `authenticatorGetAssertion` and the `hmac-secret` and `credProtect`
/// extensions, written from the CTAP 2.1 text (sections 6.1, 6.2, 12.1 and
/// 12.5), with a switch for what a CTAP 2.0 key does instead: one secret
/// per credential, PIN protocol 1 and the older token. A CTAP 2.1 key
/// spends a PIN token on the first credential or read the owner was
/// present for, so each needs a token of its own.
///
/// ```dart
/// final soft = SoftKey(pin: '123456');
/// phone.arrive(FakeKey(productName: 'Example Key', ctap: soft).device(kinds: {SecurityKeyLinkKind.nfc}));
/// final old = SoftKey.ctap20(pin: '123456');     // gives its secret on a touch
/// soft.hmacSecret = false;                        // a key that cannot give a secret
/// ```
class SoftKey extends FakeFidoKey {
  SoftKey({super.pin, super.pinProtocols, super.fingerprintReader, this.credProtect = true, this.hmacSecret = true}) : ctap20 = false {
    _advertise();
  }

  /// A key from before CTAP 2.1.
  SoftKey.ctap20({super.pin, this.credProtect = false, this.hmacSecret = true})
    : ctap20 = true,
      super(
        versions: ['U2F_V2', 'FIDO_2_0'],
        aaguid: List.filled(16, 0x20),
        pinProtocols: [1],
        pinUvAuthToken: false,
        credentialManagement: FakeSupport.preview,
      ) {
    _advertise();
  }

  /// One secret per credential, whether or not the owner was verified.
  final bool ctap20;

  /// Whether the key has each extension. Change them with [set].
  bool credProtect;
  bool hmacSecret;

  /// Leaves the credential out of an assertion when it was asked for one
  /// only, as the standard allows.
  bool omitsLoneCredential = false;

  /// Answers assertions without the "owner verified" flag, whatever was
  /// sent: a key that is wrong about itself.
  bool forgetsUvFlag = false;

  /// Gives a different secret at every read: a key that is not steady.
  bool unsteady = false;

  /// The credentials made that are not discoverable.
  final List<SoftCredential> made = [];

  /// The parameters of every `makeCredential` and `getAssertion` received.
  final List<Map<int, Object?>> makeRequests = [];
  final List<Map<int, Object?>> assertRequests = [];

  static int _keys = 0;
  final int _serial = ++_keys;
  int _made = 0;
  int _reads = 0;

  /// Sets what the key says of its extensions after a change.
  void set({bool? hmacSecret, bool? credProtect}) {
    this.hmacSecret = hmacSecret ?? this.hmacSecret;
    this.credProtect = credProtect ?? this.credProtect;
    _advertise();
  }

  void _advertise() {
    extraInfo[2] = [if (credProtect) 'credProtect', if (hmacSecret) 'hmac-secret'];
    // A reader with a fingerprint on it verifies the owner by itself.
    if (fingerprintReader != FakeSupport.none) extraOptions['uv'] = fingerprints.isNotEmpty;
  }

  @override
  FakeFingerprint addFingerprint([String? name]) {
    final fingerprint = super.addFingerprint(name);
    _advertise();
    return fingerprint;
  }

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) {
    if (command != 0x01 && command != 0x02) return super.handle(command, parameters, kind);
    final Map<int, Object?> map;
    try {
      map = cborIntMap(cborDecode(parameters));
    } on CborError {
      return FakeCtapReply(0x12);
    }
    requests.add(command.toRadixString(16));
    onRequest?.call(command, map);
    return command == 0x01 ? _make(map) : _assert(map);
  }

  static Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

  static Uint8List _rpIdHash(String rpId) => Uint8List.fromList(sha256.convert(utf8.encode(rpId)).bytes);

  Uint8List _fresh(String label) => _hmac(utf8.encode('soft key $_serial'), utf8.encode('$label/${_made++}'));

  bool get _hasFingerprint => fingerprintReader != FakeSupport.none && fingerprints.isNotEmpty;

  /// Whether the owner was verified for this request: 1 by a token's tag,
  /// 2 by the key's own reader, 0 not at all; or the status that refuses.
  (int how, int status) _verified(int permission, Object? options, Object? protocol, List<int> message, Object? tag) {
    if (tag != null) {
      final refused = authorised(permission, protocol, message, tag);
      return refused == 0 ? (1, 0) : (0, refused);
    }
    if (cborTextMap(options)['uv'] == true) return _hasFingerprint ? (2, 0) : (0, 0x2c);
    return (0, 0);
  }

  FakeCtapReply _refusedTouch() => FakeCtapReply(0x2f)..keepalives = [2, 2, 2];

  static bool _matches(Object? descriptor, Uint8List id) {
    final listed = cborTextMap(descriptor)['id'];
    if (listed is! Uint8List || listed.length != id.length) return false;
    for (var i = 0; i < id.length; i++) {
      if (listed[i] != id[i]) return false;
    }
    return true;
  }

  FakeCtapReply _make(Map<int, Object?> map) {
    makeRequests.add(map);
    final clientDataHash = map[1];
    final rpId = cborTextMap(map[2])['id'];
    final userId = cborTextMap(map[3])['id'];
    final algorithms = map[4];
    if (clientDataHash is! Uint8List || rpId is! String || userId is! Uint8List || algorithms is! List<Object?>) return FakeCtapReply(0x14);
    if (!algorithms.any((item) => cborTextMap(item)['alg'] == -7)) return FakeCtapReply(0x26);
    final options = cborTextMap(map[7]);
    final (how, status) = _verified(0x01, map[7], map[9], clientDataHash, map[8]);
    if (status != 0) return FakeCtapReply(status);
    // A key with a PIN makes no credential without it.
    if (how == 0 && pin != null) return FakeCtapReply(0x36);
    if (!touches) return _refusedTouch();
    final excluded = map[5];
    if (excluded is List<Object?>) {
      for (final credential in made) {
        if (credential.rpId == rpId && excluded.any((item) => _matches(item, credential.id))) return FakeCtapReply(0x19)..keepalives = [2];
      }
    }
    if (how == 1) spendToken();
    final extensions = cborTextMap(map[6]);
    final wantsSecret = hmacSecret && extensions['hmac-secret'] == true;
    final level = credProtect && extensions['credProtect'] is int ? extensions['credProtect']! as int : null;
    final id = Uint8List.fromList([..._fresh('id'), ..._fresh('id tail')]);
    final withUv = _fresh('secret with uv');
    final credential = SoftCredential(
      id: id,
      rpId: rpId,
      withUv: withUv,
      withoutUv: ctap20 ? withUv : _fresh('secret without uv'),
      credProtect: level,
      hmacSecret: wantsSecret,
    );
    if (options['rk'] == true) {
      // A discoverable credential takes a place and is listed.
      credentials.add(FakeCredential(rpId: rpId, userName: cborTextMap(map[3])['name'] as String? ?? '', id: id, userId: userId));
    }
    made.add(credential);
    final pair = newP256KeyPair();
    final outputs = {if (wantsSecret) 'hmac-secret': true, 'credProtect': ?level};
    final authData = Uint8List.fromList([
      ..._rpIdHash(rpId),
      0x01 | (how != 0 ? 0x04 : 0) | 0x40 | (outputs.isEmpty ? 0 : 0x80),
      0,
      0,
      0,
      1,
      ...aaguid,
      id.length >> 8,
      id.length & 0xff,
      ...id,
      ...cborEncode({1: 2, 3: -7, -1: 1, -2: pair.x, -3: pair.y}),
      if (outputs.isNotEmpty) ...cborEncode(outputs),
    ]);
    return FakeCtapReply(0, {1: 'none', 2: authData, 3: <Object, Object?>{}})..keepalives = [2];
  }

  FakeCtapReply _assert(Map<int, Object?> map) {
    assertRequests.add(map);
    final rpId = map[1];
    final clientDataHash = map[2];
    final allowed = map[3];
    if (rpId is! String || clientDataHash is! Uint8List) return FakeCtapReply(0x14);
    final (how, status) = _verified(0x02, map[5], map[7], clientDataHash, map[6]);
    if (status != 0) return FakeCtapReply(status);
    // Not discoverable: without a list the key finds nothing. A discoverable credential is found by the name alone.
    final found = allowed is! List<Object?>
        ? made
              .where((credential) => credential.discoverable && credential.rpId == rpId && (credential.credProtect != 3 || how != 0))
              .firstOrNull
        : made
              .where(
                (credential) =>
                    credential.rpId == rpId &&
                    allowed.any((item) => _matches(item, credential.id)) &&
                    // At the highest level a credential does not exist for who was not verified.
                    (credential.credProtect != 3 || how != 0),
              )
              .firstOrNull;
    if (found == null) return FakeCtapReply(0x2e);
    if (cborTextMap(map[5])['up'] != false) {
      if (!touches) return _refusedTouch();
      if (how == 1) spendToken();
    }
    final extension = cborTextMap(map[4])['hmac-secret'];
    Uint8List? output;
    if (extension != null && found.hmacSecret) {
      final input = cborIntMap(extension);
      final protocol = input[4] is int ? input[4]! as int : 1;
      if (!pinProtocols.contains(protocol)) return FakeCtapReply(0x02);
      final secret = sharedSecretWith(protocol, input[1]);
      final saltEnc = input[2];
      if (secret == null || saltEnc is! Uint8List) return FakeCtapReply(0x14);
      final (hmacKey, aesKey) = secret;
      if (!FakeFidoKey.verifies(protocol, hmacKey, saltEnc, input[3])) return FakeCtapReply(0x33);
      final salts = FakeFidoKey.decrypts(protocol, aesKey, saltEnc);
      if (salts == null || (salts.length != 32 && salts.length != 64)) return FakeCtapReply(0x03);
      var credRandom = how != 0 ? found.withUv : found.withoutUv;
      if (unsteady) credRandom = _hmac(credRandom, [++_reads]);
      output = FakeFidoKey.encrypts(
        protocol,
        aesKey,
        Uint8List.fromList([..._hmac(credRandom, salts.sublist(0, 32)), if (salts.length == 64) ..._hmac(credRandom, salts.sublist(32))]),
      );
    }
    final uvFlag = how != 0 && !forgetsUvFlag ? 0x04 : 0;
    final authData = Uint8List.fromList([
      ..._rpIdHash(rpId),
      0x01 | uvFlag | (output == null ? 0 : 0x80),
      0,
      0,
      0,
      2,
      if (output != null) ...cborEncode({'hmac-secret': output}),
    ]);
    final lone = allowed is List<Object?> && allowed.length == 1;
    return FakeCtapReply(0, {
      if (!(lone && omitsLoneCredential)) 1: {'id': found.id, 'type': 'public-key'},
      2: authData,
      3: Uint8List.fromList(List.filled(70, 0x30)),
      if (found.userId != null) 4: {'id': found.userId},
    })..keepalives = [2];
  }
}
