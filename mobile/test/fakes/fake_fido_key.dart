import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:pointycastle/export.dart' as pc;

import 'fake_security_keys.dart';

/// Which version of an optional command a [FakeFidoKey] has.
enum FakeSupport { none, preview, standard }

/// A passkey on a [FakeFidoKey].
class FakeCredential {
  FakeCredential({required this.rpId, this.rpName, required this.userName, this.displayName, required this.id, required this.userId});

  final String rpId;
  final String? rpName;
  final String userName;
  final String? displayName;
  final Uint8List id;
  final Uint8List userId;
}

/// A credential a site keeps for its second step, on a [FakeFidoKey]: not a
/// passkey, so the key answers for it only when the site names its [id]
/// (openspec: add-vaultwarden-security-key).
class FakeSignInCredential {
  FakeSignInCredential({required this.rpId, required this.id, required this.keyPair});

  final String rpId;
  final Uint8List id;
  final P256KeyPair keyPair;

  /// How many assertions it signed; the next one carries this plus one.
  int signCount = 0;
}

/// A fingerprint on a [FakeFidoKey].
class FakeFingerprint {
  FakeFingerprint(this.id, [this.name]);

  final Uint8List id;
  String? name;
}

/// A FIDO2 authenticator in software, for a [FakeKey]: `getInfo` as the
/// test configures it, a PIN with its tries and both PIN protocols,
/// passkeys, fingerprints, and reset with its timing rule on the fake
/// clock. It is written from the CTAP 2.1 text and does its own HMAC, HKDF
/// and AES; it shares no PIN code with the app.
///
/// ```dart
/// final fido = FakeFidoKey(pin: '123456')..addPasskey('github.com', 'adalovelace');
/// final key = FakeKey(productName: 'Example Key', ctap: fido);
/// phone.arrive(key.device(kinds: {SecurityKeyLinkKind.nfc}));
/// fido.touches = false;                         // nobody touches the key
/// fido.samples.addAll([0, 9, 0, 0, 0]);         // the second touch is too short
/// ```
class FakeFidoKey extends FakeCtapAuthenticator {
  FakeFidoKey({
    this.pin,
    List<String>? versions,
    List<int>? aaguid,
    List<int>? pinProtocols,
    this.clientPin = true,
    this.pinUvAuthToken = true,
    this.credentialManagement = FakeSupport.standard,
    this.fingerprintReader = FakeSupport.none,
    this.minPinLength,
    this.forcePinChange = false,
    this.firmwareVersion,
    this.capacity = 100,
  }) : versions = versions ?? ['U2F_V2', 'FIDO_2_0', 'FIDO_2_1'],
       aaguid = Uint8List.fromList(aaguid ?? List.filled(16, 0x2f)),
       pinProtocols = pinProtocols ?? [2, 1];

  /// A key from before CTAP 2.1: PIN protocol 1, the older token, and the
  /// preview commands only.
  factory FakeFidoKey.ctap20({String? pin, FakeSupport fingerprintReader = FakeSupport.none}) => FakeFidoKey(
    pin: pin,
    versions: ['U2F_V2', 'FIDO_2_0'],
    aaguid: List.filled(16, 0x20),
    pinProtocols: [1],
    pinUvAuthToken: false,
    credentialManagement: FakeSupport.preview,
    fingerprintReader: fingerprintReader,
  );

  // What getInfo says.
  List<String> versions;
  Uint8List aaguid;
  List<int> pinProtocols;
  bool clientPin;
  bool pinUvAuthToken;
  FakeSupport credentialManagement;
  FakeSupport fingerprintReader;

  /// The fewest characters of a PIN; reported only when set (4 otherwise).
  int? minPinLength;
  bool forcePinChange;
  int? firmwareVersion;

  /// How many passkeys the key holds at most.
  int capacity;

  /// Options and members a newer standard might add.
  Map<String, bool> extraOptions = {};
  Map<int, Object?> extraInfo = {};

  // The key's state.
  String? pin;
  int retries = 8;
  final List<FakeCredential> credentials = [];
  final List<FakeFingerprint> fingerprints = [];

  /// How many fingerprints the reader keeps.
  int maxFingerprints = 5;

  /// How many good touches an enrolment takes.
  int samplesNeeded = 4;

  /// What the key makes of the coming touches of its reader, as CTAP's
  /// sample statuses; good (0) once this runs out.
  final Queue<int> samples = Queue();

  /// A PIN the key's own rules refuse.
  bool Function(String pin)? refusesPin;

  /// Whether the person touches the key when it asks.
  bool touches = true;

  /// The links the key does not reset over.
  Set<SecurityKeyLinkKind> noResetOver = {};

  /// Every request, as `command` or `command.subCommand` in hex.
  final List<String> requests = [];

  /// Called with each request before it is answered.
  void Function(int command, Map<int, Object?> parameters)? onRequest;

  /// How many times an unfinished fingerprint was dropped on request.
  int enrollmentsCancelled = 0;

  /// The number of sites, and of a site's passkeys, the key says it has in
  /// place of the true ones; each "next" past the end gives the last one
  /// again. A key that lies about its counts.
  int? claimedSites;
  int? claimedPasskeys;

  DateTime Function() _now = DateTime.now;
  DateTime _poweredAt = DateTime.now();
  int _wrongInARow = 0;
  bool _lockedUntilPowerCycle = false;
  Uint8List? _token;
  int _permissions = 0;
  P256KeyPair _agreement = newP256KeyPair();
  List<(String, String?)> _sites = [];
  List<FakeCredential> _listing = [];
  (String, String?)? _lastSite;
  FakeCredential? _lastListed;
  (Uint8List, int)? _enrolling;
  int _ids = 0;

  /// Puts a passkey for [userName] at [rpId] on the key.
  FakeCredential addPasskey(String rpId, String userName, {String? rpName, String? displayName}) {
    final n = ++_ids;
    final credential = FakeCredential(
      rpId: rpId,
      rpName: rpName,
      userName: userName,
      displayName: displayName,
      id: Uint8List.fromList([0xc0, n >> 8, n & 0xff, ...List.filled(13, 0x5a)]),
      userId: Uint8List.fromList([0x75, n >> 8, n & 0xff]),
    );
    credentials.add(credential);
    return credential;
  }

  /// Puts a fingerprint called [name] on the key.
  FakeFingerprint addFingerprint([String? name]) {
    final fingerprint = FakeFingerprint(Uint8List.fromList([0xf0, ++_ids]), name);
    fingerprints.add(fingerprint);
    return fingerprint;
  }

  @override
  void poweredUp(DateTime Function() now) {
    _now = now;
    _poweredAt = now();
    _wrongInARow = 0;
    _lockedUntilPowerCycle = false;
    _token = null;
    _enrolling = null;
    _agreement = newP256KeyPair();
  }

  @override
  void cancelled() => _enrolling = null;

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) {
    final Map<int, Object?> map;
    try {
      map = parameters.isEmpty ? {} : cborIntMap(cborDecode(parameters));
    } on CborError {
      return FakeCtapReply(0x12); // CTAP2_ERR_INVALID_CBOR
    }
    final sub = switch (command) {
      0x06 => map[2],
      0x09 || 0x40 => map[2],
      0x0a || 0x41 => map[1],
      _ => null,
    };
    requests.add(sub is int ? '${command.toRadixString(16)}.${sub.toRadixString(16)}' : command.toRadixString(16));
    onRequest?.call(command, map);
    return switch (command) {
      0x02 => _signInAssertion(map),
      0x04 => FakeCtapReply(0, _info()),
      0x06 => clientPin ? _clientPin(map) : FakeCtapReply(0x01),
      0x07 => _reset(kind),
      0x0a => credentialManagement == FakeSupport.standard ? _credentials(map) : FakeCtapReply(0x01),
      0x41 => credentialManagement == FakeSupport.preview ? _credentials(map) : FakeCtapReply(0x01),
      0x09 => fingerprintReader == FakeSupport.standard ? _fingerprints(map) : FakeCtapReply(0x01),
      0x40 => fingerprintReader == FakeSupport.preview ? _fingerprints(map) : FakeCtapReply(0x01),
      _ => FakeCtapReply(0x01),
    };
  }

  Map<int, Object?> _info() => {
    1: versions,
    3: aaguid,
    4: {
      'rk': true,
      'up': true,
      'plat': false,
      if (clientPin) 'clientPin': pin != null,
      if (credentialManagement == FakeSupport.standard) 'credMgmt': true,
      if (credentialManagement == FakeSupport.preview) 'credentialMgmtPreview': true,
      if (fingerprintReader == FakeSupport.standard) 'bioEnroll': fingerprints.isNotEmpty,
      if (fingerprintReader == FakeSupport.preview) 'userVerificationMgmtPreview': fingerprints.isNotEmpty,
      if (pinUvAuthToken) 'pinUvAuthToken': true,
      ...extraOptions,
    },
    5: 1200,
    if (clientPin) 6: pinProtocols,
    if (forcePinChange) 12: true,
    13: ?minPinLength,
    14: ?firmwareVersion,
    20: capacity - credentials.length,
    ...extraInfo,
  };

  // The PIN protocols, from CTAP 2.1 sections 6.5.6 and 6.5.7.

  static Uint8List _hmac(List<int> key, List<int> message) => Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

  static Uint8List _hkdf(Uint8List z, String info) {
    final prk = _hmac(Uint8List(32), z);
    return _hmac(prk, [...ascii.encode(info), 1]);
  }

  static Uint8List _aes(Uint8List key, Uint8List iv, Uint8List input, {required bool encrypt}) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine())..init(encrypt, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    final output = Uint8List(input.length);
    for (var offset = 0; offset + 16 <= input.length; offset += 16) {
      cipher.processBlock(input, offset, output, offset);
    }
    return output;
  }

  /// The shared secret for the platform's [peer] key: (HMAC key, AES key).
  (Uint8List, Uint8List)? _secret(int protocol, Object? peer) {
    final cose = cborIntMap(peer);
    final x = cose[-2];
    final y = cose[-3];
    if (x is! Uint8List || y is! Uint8List) return null;
    final Uint8List z;
    try {
      z = p256SharedSecret(_agreement.d, Uint8List.fromList([4, ...x, ...y]));
    } on ArgumentError {
      return null;
    }
    if (protocol == 1) {
      final secret = Uint8List.fromList(sha256.convert(z).bytes);
      return (secret, secret);
    }
    return (_hkdf(z, 'CTAP2 HMAC key'), _hkdf(z, 'CTAP2 AES key'));
  }

  static bool _verify(int protocol, Uint8List key, List<int> message, Object? tag) {
    if (tag is! Uint8List) return false;
    final mac = _hmac(key, message);
    final expected = protocol == 1 ? mac.sublist(0, 16) : mac;
    if (tag.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < tag.length; i++) {
      difference |= tag[i] ^ expected[i];
    }
    return difference == 0;
  }

  static Uint8List? _decrypt(int protocol, Uint8List key, Object? ciphertext) {
    if (ciphertext is! Uint8List) return null;
    if (protocol == 1) return ciphertext.length % 16 == 0 ? _aes(key, Uint8List(16), ciphertext, encrypt: false) : null;
    if (ciphertext.length < 32 || ciphertext.length % 16 != 0) return null;
    return _aes(key, ciphertext.sublist(0, 16), ciphertext.sublist(16), encrypt: false);
  }

  static Uint8List _encrypt(int protocol, Uint8List key, Uint8List plaintext) {
    if (protocol == 1) return _aes(key, Uint8List(16), plaintext, encrypt: true);
    final iv = Uint8List.fromList(List.generate(16, (i) => 0xa0 + i));
    return Uint8List.fromList([...iv, ..._aes(key, iv, plaintext, encrypt: true)]);
  }

  /// The new PIN in [padded], or the status that refuses it.
  (String?, int) _newPin(Uint8List? padded) {
    if (padded == null || padded.length != 64) return (null, 0x02);
    var end = padded.indexOf(0);
    if (end < 0) end = 64;
    final String candidate;
    try {
      candidate = utf8.decode(padded.sublist(0, end));
    } on FormatException {
      return (null, 0x37);
    }
    if (candidate.runes.length < (minPinLength ?? 4) || end > 63) return (null, 0x37);
    if (refusesPin?.call(candidate) ?? false) return (null, 0x37);
    return (candidate, 0);
  }

  /// Checks the encrypted hash of the PIN typed against the key's PIN,
  /// counting the tries as the standard says. 0 when it is the PIN.
  int _checkPin(int protocol, Uint8List aesKey, Object? pinHashEnc) {
    if (pin == null) return 0x35;
    if (retries == 0) return 0x32;
    if (_lockedUntilPowerCycle) return 0x34;
    retries--;
    final hash = _decrypt(protocol, aesKey, pinHashEnc);
    final expected = sha256.convert(utf8.encode(pin!)).bytes.sublist(0, 16);
    var same = hash != null && hash.length == 16;
    for (var i = 0; same && i < 16; i++) {
      same = hash![i] == expected[i];
    }
    if (!same) {
      _agreement = newP256KeyPair();
      if (retries == 0) return 0x32;
      if (++_wrongInARow >= 3) {
        _lockedUntilPowerCycle = true;
        return 0x34;
      }
      return 0x31;
    }
    retries = 8;
    _wrongInARow = 0;
    return 0;
  }

  FakeCtapReply _clientPin(Map<int, Object?> map) {
    final protocol = map[1];
    final sub = map[2];
    if (protocol is! int || !pinProtocols.contains(protocol)) return FakeCtapReply(0x02);
    switch (sub) {
      case 1:
        return FakeCtapReply(0, {3: retries, if (_lockedUntilPowerCycle) 4: true});
      case 2:
        return FakeCtapReply(0, {
          1: {1: 2, 3: -25, -1: 1, -2: _agreement.x, -3: _agreement.y},
        });
    }
    final secret = _secret(protocol, map[3]);
    if (secret == null) return FakeCtapReply(0x02);
    final (hmacKey, aesKey) = secret;
    switch (sub) {
      case 3:
        final newPinEnc = map[5];
        if (pin != null) return FakeCtapReply(0x33);
        if (newPinEnc is! Uint8List || !_verify(protocol, hmacKey, newPinEnc, map[4])) return FakeCtapReply(0x33);
        final (candidate, status) = _newPin(_decrypt(protocol, aesKey, newPinEnc));
        if (candidate == null) return FakeCtapReply(status);
        pin = candidate;
        retries = 8;
        return FakeCtapReply(0);
      case 4:
        final newPinEnc = map[5];
        final pinHashEnc = map[6];
        if (newPinEnc is! Uint8List || pinHashEnc is! Uint8List) return FakeCtapReply(0x02);
        if (pin == null) return FakeCtapReply(0x35);
        if (!_verify(protocol, hmacKey, [...newPinEnc, ...pinHashEnc], map[4])) return FakeCtapReply(0x33);
        final refused = _checkPin(protocol, aesKey, pinHashEnc);
        if (refused != 0) return FakeCtapReply(refused);
        final (candidate, status) = _newPin(_decrypt(protocol, aesKey, newPinEnc));
        if (candidate == null) return FakeCtapReply(status);
        pin = candidate;
        forcePinChange = false;
        _token = null;
        return FakeCtapReply(0);
      case 5 || 9:
        if (sub == 9 && (!pinUvAuthToken || map[9] is! int || map[9] == 0)) return FakeCtapReply(0x02);
        final refused = _checkPin(protocol, aesKey, map[6]);
        if (refused != 0) return FakeCtapReply(refused);
        if (forcePinChange) return FakeCtapReply(0x37);
        final token = _token = Uint8List.fromList(List.generate(32, (i) => (i * 13 + requests.length) & 0xff));
        // The older token is good for everything the PIN guards.
        _permissions = sub == 9 ? map[9]! as int : 0xff;
        _signInTokenRpId = sub == 9 ? map[10] : null;
        return FakeCtapReply(0, {2: _encrypt(protocol, aesKey, token)});
      default:
        return FakeCtapReply(0x3e);
    }
  }

  /// 0 when [tag] signs [message] with a token that has [permission].
  int _authorised(int permission, Object? protocol, List<int> message, Object? tag) {
    final token = _token;
    if (tag == null || protocol is! int) return 0x36;
    if (token == null || !_verify(protocol, token, message, tag)) return 0x33;
    if (_permissions & permission == 0) return 0x40;
    return 0;
  }

  static Uint8List _rpIdHash(String rpId) => Uint8List.fromList(sha256.convert(utf8.encode(rpId)).bytes);

  // ─── Signing in to a site with a credential it lists ───────────────────
  // (openspec: add-vaultwarden-security-key). `authenticatorGetAssertion`
  // for credentials that are not passkeys on the key: a site's second
  // step. It is kept apart from the passkeys above and from anything
  // another change adds for the same command.

  /// The second-step credentials on the key, see [addSignInCredential].
  final List<FakeSignInCredential> signInCredentials = [];

  /// The key answers an assertion only with its PIN (`alwaysUv`).
  bool get alwaysUv => extraOptions['alwaysUv'] ?? false;
  set alwaysUv(bool value) => value ? extraOptions['alwaysUv'] = true : extraOptions.remove('alwaysUv');

  /// How many credentials the key takes in one allow list
  /// (`maxCredentialCountInList`); null when it does not say, and then it
  /// takes one, as keys from before CTAP 2.1 that say nothing.
  int? get maxCredentialCountInList => extraInfo[7] as int?;
  set maxCredentialCountInList(int? value) => value == null ? extraInfo.remove(7) : extraInfo[7] = value;

  /// The allow lists of the assertion requests the key got, by length.
  final List<int> allowListLengths = [];

  Object? _signInTokenRpId;

  /// Registers a second-step credential for [rpId] on the key, with a new
  /// P-256 key pair, and returns it: its [FakeSignInCredential.id] and
  /// public point are what a server keeps.
  FakeSignInCredential addSignInCredential(String rpId, {List<int>? id, P256KeyPair? keyPair}) {
    final n = ++_ids;
    final credential = FakeSignInCredential(
      rpId: rpId,
      id: Uint8List.fromList(id ?? [0x51, n >> 8, n & 0xff, ...List.filled(29, 0xa5)]),
      keyPair: keyPair ?? newP256KeyPair(),
    );
    signInCredentials.add(credential);
    return credential;
  }

  FakeCtapReply _signInAssertion(Map<int, Object?> map) {
    final rpId = map[1];
    final clientDataHash = map[2];
    final allowList = map[3];
    if (rpId is! String || clientDataHash is! Uint8List || clientDataHash.length != 32) return FakeCtapReply(0x14);
    if (allowList is! List<Object?> || allowList.isEmpty) return FakeCtapReply(0x2e);
    allowListLengths.add(allowList.length);
    if (allowList.length > (maxCredentialCountInList ?? 1)) return FakeCtapReply(0x15); // CTAP2_ERR_LIMIT_EXCEEDED
    final options = cborTextMap(map[5]);
    if (options['uv'] == true) return FakeCtapReply(0x2b);
    var verified = false;
    if (map[6] != null) {
      final refused = _authorised(0x02, map[7], clientDataHash, map[6]);
      if (refused != 0) return FakeCtapReply(refused);
      // A token asked for with a site's name signs for that site only.
      if (_signInTokenRpId != null && _signInTokenRpId != rpId) return FakeCtapReply(0x33);
      verified = true;
    } else if (alwaysUv && pin != null) {
      return FakeCtapReply(0x36);
    }
    final ids = [
      for (final descriptor in allowList)
        if (cborTextMap(descriptor)['id'] case final Uint8List id) id,
    ];
    final credential = signInCredentials.where((c) => c.rpId == rpId && ids.any((id) => _same(id, c.id))).firstOrNull;
    if (credential == null) return FakeCtapReply(0x2e);
    if (options['up'] != false && !touches) {
      return FakeCtapReply(0x2f)..keepalives = [2, 2, 2];
    }
    final counter = ++credential.signCount;
    final authenticatorData = Uint8List.fromList([
      ..._rpIdHash(rpId),
      0x01 | (verified ? 0x04 : 0),
      counter >> 24 & 0xff,
      counter >> 16 & 0xff,
      counter >> 8 & 0xff,
      counter & 0xff,
    ]);
    final signature = es256Sign(credential.keyPair, Uint8List.fromList([...authenticatorData, ...clientDataHash]));
    return FakeCtapReply(0, {
      // A key may leave the credential out when it was asked about one only.
      if (ids.length > 1 || !omitsSingleCredential) 1: {'id': credential.id, 'type': 'public-key'},
      2: authenticatorData,
      3: signature,
    })..keepalives = waitsForTouch ? [2] : const [];
  }

  /// The key leaves the credential out of its answer when it was asked
  /// about one only, as the standard lets it.
  bool omitsSingleCredential = false;

  /// The key says it waits for a touch before it answers an assertion, as
  /// a plugged-in key does.
  bool waitsForTouch = false;

  // ─── End of signing in to a site ───────────────────────────────────────

  FakeCtapReply _credentials(Map<int, Object?> map) {
    final sub = map[1];
    final parameters = map[2];
    if (sub is! int) return FakeCtapReply(0x02);
    if (sub != 3 && sub != 5) {
      final refused = _authorised(0x04, map[3], [sub, if (parameters != null) ...cborEncode(parameters)], map[4]);
      if (refused != 0) return FakeCtapReply(refused);
    }
    Map<int, Object?> site((String, String?) rp) => {
      3: {'id': rp.$1, if (rp.$2 != null) 'name': rp.$2},
      4: _rpIdHash(rp.$1),
    };
    Map<int, Object?> credential(FakeCredential c) => {
      6: {'id': c.userId, 'name': c.userName, if (c.displayName != null) 'displayName': c.displayName},
      7: {'id': c.id, 'type': 'public-key'},
      8: {1: 2, 3: -7},
      10: 1,
    };
    switch (sub) {
      case 1:
        return FakeCtapReply(0, {1: credentials.length, 2: capacity - credentials.length});
      case 2:
        final names = <String, String?>{};
        for (final c in credentials) {
          names[c.rpId] ??= c.rpName;
        }
        _sites = [for (final MapEntry(:key, :value) in names.entries) (key, value)];
        if (_sites.isEmpty) return FakeCtapReply(0x2e);
        final total = claimedSites ?? _sites.length;
        return FakeCtapReply(0, {...site(_lastSite = _sites.removeAt(0)), 5: total});
      case 3:
        if (_sites.isEmpty && claimedSites != null && _lastSite != null) return FakeCtapReply(0, site(_lastSite!));
        if (_sites.isEmpty) return FakeCtapReply(0x30);
        return FakeCtapReply(0, site(_lastSite = _sites.removeAt(0)));
      case 4:
        final hash = cborIntMap(parameters)[1];
        if (hash is! Uint8List) return FakeCtapReply(0x02);
        _listing = [
          for (final c in credentials)
            if (_same(_rpIdHash(c.rpId), hash)) c,
        ];
        if (_listing.isEmpty) return FakeCtapReply(0x2e);
        final total = claimedPasskeys ?? _listing.length;
        return FakeCtapReply(0, {...credential(_lastListed = _listing.removeAt(0)), 9: total});
      case 5:
        if (_listing.isEmpty && claimedPasskeys != null && _lastListed != null) return FakeCtapReply(0, credential(_lastListed!));
        if (_listing.isEmpty) return FakeCtapReply(0x30);
        return FakeCtapReply(0, credential(_lastListed = _listing.removeAt(0)));
      case 6:
        final id = cborTextMap(cborIntMap(parameters)[2])['id'];
        final before = credentials.length;
        if (id is Uint8List) credentials.removeWhere((c) => _same(c.id, id));
        return FakeCtapReply(credentials.length == before ? 0x2e : 0);
      default:
        return FakeCtapReply(0x3e);
    }
  }

  /// One touch of the reader while enrolling.
  FakeCtapReply _sample(Uint8List id, int remaining) {
    if (!touches) {
      return FakeCtapReply(0x2f)..keepalives = [2, 2, 2];
    }
    final status = samples.isEmpty ? 0 : samples.removeFirst();
    final left = status == 0 ? remaining - 1 : remaining;
    if (left == 0) {
      fingerprints.add(FakeFingerprint(id));
      _enrolling = null;
    } else {
      _enrolling = (id, left);
    }
    return FakeCtapReply(0, {4: id, 5: status, 6: left})..keepalives = [2];
  }

  FakeCtapReply _fingerprints(Map<int, Object?> map) {
    if (map[6] == true) return FakeCtapReply(0, {1: 1});
    final sub = map[2];
    final parameters = map[3];
    if (sub is! int) return FakeCtapReply(0x02);
    if (sub == 7) return FakeCtapReply(0, {1: 1, 2: 1, 3: samplesNeeded, 8: 15});
    if (sub == 3) {
      if (_enrolling != null) enrollmentsCancelled++;
      _enrolling = null;
      return FakeCtapReply(0);
    }
    final refused = _authorised(0x08, map[4], [1, sub, if (parameters != null) ...cborEncode(parameters)], map[5]);
    if (refused != 0) return FakeCtapReply(refused);
    final id = cborIntMap(parameters)[1];
    FakeFingerprint? named() => id is Uint8List ? fingerprints.where((f) => _same(f.id, id)).firstOrNull : null;
    switch (sub) {
      case 1:
        if (fingerprints.length >= maxFingerprints) return FakeCtapReply(0x17);
        return _sample(Uint8List.fromList([0xf0, ++_ids]), samplesNeeded);
      case 2:
        final enrolling = _enrolling;
        if (enrolling == null || id is! Uint8List || !_same(enrolling.$1, id)) return FakeCtapReply(0x30);
        return _sample(enrolling.$1, enrolling.$2);
      case 4:
        if (fingerprints.isEmpty) return FakeCtapReply(0x2c);
        return FakeCtapReply(0, {
          7: [
            for (final f in fingerprints) {1: f.id, if (f.name != null) 2: f.name},
          ],
        });
      case 5:
        final fingerprint = named();
        final name = cborIntMap(parameters)[2];
        if (fingerprint == null || name is! String) return FakeCtapReply(0x2c);
        fingerprint.name = name;
        return FakeCtapReply(0);
      case 6:
        final fingerprint = named();
        if (fingerprint == null) return FakeCtapReply(0x2c);
        fingerprints.remove(fingerprint);
        return FakeCtapReply(0);
      default:
        return FakeCtapReply(0x3e);
    }
  }

  /// Reset is taken within ten seconds of power-up, over a link the key
  /// resets over, and after a touch.
  FakeCtapReply _reset(SecurityKeyLinkKind kind) {
    if (noResetOver.contains(kind)) return FakeCtapReply(0x30);
    if (_now().difference(_poweredAt) > const Duration(seconds: 10)) return FakeCtapReply(0x30);
    if (!touches) {
      return FakeCtapReply(0x2f)..keepalives = [2, 2, 2];
    }
    pin = null;
    retries = 8;
    forcePinChange = false;
    credentials.clear();
    fingerprints.clear();
    _token = null;
    _lockedUntilPowerCycle = false;
    return FakeCtapReply(0)..keepalives = [2];
  }

  // What a subclass that adds commands needs of the PIN protocols and the
  // token (test/security_key/soft_key.dart).

  /// The shared secret for the platform's [peer] key: (HMAC key, AES key).
  (Uint8List, Uint8List)? sharedSecretWith(int protocol, Object? peer) => _secret(protocol, peer);

  /// 0 when [tag] signs [message] with a token that has [permission].
  int authorised(int permission, Object? protocol, List<int> message, Object? tag) => _authorised(permission, protocol, message, tag);

  /// What a CTAP 2.1 key does once a token was used for a credential or an
  /// assertion the owner was present for (sections 6.1.2, step 14.4, and
  /// 6.2.2, step 9.4): the token keeps none of its permissions but `lbw`.
  /// A key from before CTAP 2.1 keeps its token good until it is unplugged.
  void spendToken() {
    if (pinUvAuthToken) _permissions &= 0x20;
  }

  static bool verifies(int protocol, Uint8List key, List<int> message, Object? tag) => _verify(protocol, key, message, tag);

  static Uint8List? decrypts(int protocol, Uint8List key, Object? ciphertext) => _decrypt(protocol, key, ciphertext);

  static Uint8List encrypts(int protocol, Uint8List key, Uint8List plaintext) => _encrypt(protocol, key, plaintext);

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
