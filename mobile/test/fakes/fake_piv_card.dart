import 'dart:io';
import 'dart:typed_data';

import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/algorithms.dart';
import 'package:kemlock/crypto/keys/der.dart';
import 'package:kemlock/crypto/keys/pkcs8.dart';
import 'package:kemlock/security_key/apdu.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';
import 'package:pointycastle/export.dart' as pc;

import 'fake_security_keys.dart';

/// A PIV card in software, to put on a [FakeKey]: four slots with real
/// keys, a PIN and a PUK with their counters, a management key of either
/// kind, and the maker's commands behind a switch. Written from SP
/// 800-73-4 and the maker's published reference, apart from the app's own
/// `piv_commands.dart`.
///
/// ```dart
/// final card = FakePivCard();                         // fresh from its box
/// final key = FakeKey(applets: [card]);
/// card.generate(PivSlot.authentication, PivAlgorithm.eccP256);   // a key, set from the test
/// card.putCertificate(PivSlot.authentication, der);
/// card.makerCommands = false;                         // a standard-only card
/// card.refuseOverNfc = true;                          // keeps all but 9e's certificate to itself
/// card.pinTries = 0;                                  // a blocked PIN
/// expect(card.log, ['get 5fc105', 'verify?', ...]);
/// ```
class FakePivCard extends FakeApplet {
  FakePivCard({
    this.makerCommands = true,
    this.metadata = true,
    this.serial = 12345678,
    this.version = const [5, 4, 3],
    this.managementKeyType = PivManagementKeyType.tripleDes,
    List<int>? managementKey,
    this.pin = pivFactoryPin,
    this.puk = pivFactoryPuk,
  }) : managementKey = Uint8List.fromList(managementKey ?? pivFactoryManagementKey);

  /// Whether the card knows the maker's commands at all: version, serial,
  /// metadata, set management key and reset. Off, it is a standard-only card.
  bool makerCommands;

  /// Whether the card knows the metadata command, which older firmware
  /// with the other maker's commands lacks.
  bool metadata;

  int? serial;
  List<int> version;

  PivManagementKeyType managementKeyType;
  Uint8List managementKey;

  String pin;
  String puk;
  int pinTries = 3;
  int pukTries = 3;

  /// The slots' private keys.
  final Map<PivSlot, KeyMaterial> keys = {};

  /// The data objects, by identifier: what is inside `53`.
  final Map<int, Uint8List> objects = {};

  /// The card gives every certificate but 9e's to the contact interface
  /// only, as the standard allows. The test sets it when the key is read
  /// over NFC: an applet is not told which link a command came over.
  bool refuseOverNfc = false;

  /// The card answers "no room" to PUT DATA.
  bool full = false;

  /// The card does not take an AES management key.
  bool refusesAes = false;

  /// The card refuses SET MANAGEMENT KEY, whatever the kind.
  bool refusesNewManagementKey = false;

  /// The card signs something else than it was given.
  bool signsWrongly = false;

  /// Every command received, in words: `select`, `get 5fc105`, `put
  /// 5fc105`, `verify?`, `verify`, `change pin`, `change puk`, `unblock`,
  /// `generate 9a 11`, `sign 9a`, `auth`, `set management key 0c`,
  /// `metadata 80`, `version`, `serial`, `reset`.
  final List<String> log = [];

  bool _pinVerified = false;
  bool _authenticated = false;
  Uint8List? _witness;

  @override
  List<int> get aid => pivAid;

  /// Selecting the application starts a new session: the PIN and the
  /// management key are to be given again.
  @override
  List<int> get selectAnswer {
    log.add('select');
    _pinVerified = false;
    _authenticated = false;
    _witness = null;
    return const [0x61, 0x11, 0x4f, 0x06, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00, 0x79, 0x07, 0x4f, 0x05, 0xa0, 0x00, 0x00, 0x03, 0x08];
  }

  /// Sends [command] straight to the card, with no phone in between: for
  /// tests of the commands alone. Call [selectAnswer] first, as SELECT does.
  Future<ApduResponse> transmit(ApduCommand command) async {
    final (data, sw) = this.command(command.cla, command.ins, command.p1, command.p2, command.data);
    return ApduResponse(data, sw);
  }

  /// Whether the management key was proven in this session.
  bool get authenticated => _authenticated;

  /// The certificate stored in [slot], unwrapped; null for none.
  Uint8List? certificate(PivSlot slot) {
    final contents = objects[slot.object];
    if (contents == null || contents.isEmpty) return null;
    return unwrapPivCertificate(pivTlv(0x53, contents));
  }

  /// Stores [der] as the certificate of [slot], as a desktop tool would.
  void putCertificate(PivSlot slot, List<int> der, {bool compressed = false}) {
    objects[slot.object] = compressed
        ? Uint8List.fromList([
            ...pivTlv(0x70, gzip.encode(der)),
            ...pivTlv(0x71, const [1]),
            ...pivTlv(0xfe, const []),
          ])
        : wrapPivCertificate(Uint8List.fromList(der));
  }

  /// Makes a key of [algorithm] in [slot] and returns it.
  KeyMaterial generate(PivSlot slot, PivAlgorithm algorithm) => keys[slot] = _newKey(algorithm);

  /// The RSA keys the card "generates", in turn: making one takes seconds
  /// in Dart, so they are read from the OpenSSL fixture unless the test
  /// gives its own.
  List<RsaMaterial> rsaKeys = [];
  int _rsaNext = 0;

  KeyMaterial _newKey(PivAlgorithm algorithm) {
    switch (algorithm) {
      case PivAlgorithm.rsa2048:
        if (rsaKeys.isEmpty) rsaKeys = [readPkcs1(File('test/fixtures/keys/openssl/rsa2048.traditional.der').readAsBytesSync())];
        return rsaKeys[_rsaNext++ % rsaKeys.length];
      case PivAlgorithm.eccP256 || PivAlgorithm.eccP384:
        final curve = algorithm == PivAlgorithm.eccP256 ? EcCurve.p256 : EcCurve.p384;
        while (true) {
          final d = bytesToBigInt(randomBytes(curve.size));
          if (d > BigInt.zero && d < curve.domain.n) return ecMaterial(curve, bigIntToBytes(d, curve.size));
        }
    }
  }

  static PivAlgorithm _algorithmOf(KeyMaterial key) => switch (key) {
    RsaMaterial() => PivAlgorithm.rsa2048,
    EcMaterial(:final curve) => curve == EcCurve.p256 ? PivAlgorithm.eccP256 : PivAlgorithm.eccP384,
    _ => throw StateError('Not a key a PIV slot holds.'),
  };

  static Uint8List _publicParts(KeyMaterial key) => switch (key) {
    RsaMaterial(:final n, :final e) => Uint8List.fromList([...pivTlv(0x81, bigIntToBytes(n)), ...pivTlv(0x82, bigIntToBytes(e))]),
    EcMaterial(:final point) => pivTlv(0x86, point),
    _ => throw StateError('Not a key a PIV slot holds.'),
  };

  static const _ok = 0x9000;
  static const _securityStatus = 0x6982;
  static const _blocked = 0x6983;
  static const _notFound = 0x6a82;
  static const _notSupported = 0x6d00;
  static const _wrongData = 0x6a80;

  (List<int>, int) _status(int sw) => (const [], sw);

  String _hex(int value, [int width = 2]) => value.toRadixString(16).padLeft(width, '0');

  @override
  (List<int>, int) command(int cla, int ins, int p1, int p2, Uint8List data) {
    switch (ins) {
      case 0xcb:
        return _getData(data);
      case 0xdb:
        return _putData(data);
      case 0x20:
        return _verify(p2, data);
      case 0x24:
        return _change(p2, data);
      case 0x2c:
        return _unblock(data);
      case 0x47:
        return _generate(p2, data);
      case 0x87:
        return p2 == pivManagementKeyReference ? _authenticate(p1, data) : _sign(p1, p2, data);
      case 0xff || 0xf7 || 0xfd || 0xf8 || 0xfb when !makerCommands:
        return _status(_notSupported);
      case 0xff:
        return _setManagementKey(data);
      case 0xf7:
        return _metadata(p2);
      case 0xfd:
        log.add('version');
        return (version, _ok);
      case 0xf8:
        log.add('serial');
        final number = serial;
        if (number == null) return _status(_notSupported);
        return ([number >> 24 & 0xff, number >> 16 & 0xff, number >> 8 & 0xff, number & 0xff], _ok);
      case 0xfb:
        return _reset();
      default:
        return _status(_notSupported);
    }
  }

  int? _object(List<PivTlv> parts) {
    final id = parts.where((part) => part.tag == 0x5c).firstOrNull?.value;
    if (id == null || id.length != 3) return null;
    return id[0] << 16 | id[1] << 8 | id[2];
  }

  (List<int>, int) _getData(Uint8List data) {
    final object = _object(readPivTlvs(data));
    if (object == null) return _status(_wrongData);
    log.add('get ${_hex(object, 6)}');
    final isCertificate = PivSlot.values.any((slot) => slot.object == object);
    if (refuseOverNfc && isCertificate && object != PivSlot.cardAuthentication.object) return _status(_securityStatus);
    final contents = objects[object];
    if (contents == null) return _status(_notFound);
    return (pivTlv(0x53, contents), _ok);
  }

  (List<int>, int) _putData(Uint8List data) {
    final parts = readPivTlvs(data);
    final object = _object(parts);
    final contents = parts.where((part) => part.tag == 0x53).firstOrNull?.value;
    if (object == null || contents == null) return _status(_wrongData);
    log.add('put ${_hex(object, 6)}');
    if (!_authenticated) return _status(_securityStatus);
    if (full) return _status(0x6a84);
    objects[object] = Uint8List.fromList(contents);
    return _status(_ok);
  }

  /// Checks [given], eight padded bytes, against [code]; null when it is right.
  bool _matches(List<int> given, String code) {
    if (given.length != 8) return false;
    final padded = [...code.codeUnits, ...List.filled(8 - code.length, 0xff)];
    for (var i = 0; i < 8; i++) {
      if (padded[i] != given[i]) return false;
    }
    return true;
  }

  int _wrong(int tries) => tries == 0 ? _blocked : 0x63c0 | tries;

  String _text(List<int> padded) => String.fromCharCodes(padded.where((byte) => byte != 0xff));

  (List<int>, int) _verify(int p2, Uint8List data) {
    if (p2 != pivPinReference) return _status(0x6a88);
    if (data.isEmpty) {
      log.add('verify?');
      if (pinTries == 0) return _status(_blocked);
      return _status(_pinVerified ? _ok : 0x63c0 | pinTries);
    }
    log.add('verify');
    if (pinTries == 0) return _status(_blocked);
    if (!_matches(data, pin)) {
      _pinVerified = false;
      return _status(_wrong(--pinTries));
    }
    pinTries = 3;
    _pinVerified = true;
    return _status(_ok);
  }

  (List<int>, int) _change(int p2, Uint8List data) {
    if (data.length != 16) return _status(_wrongData);
    final current = data.sublist(0, 8);
    final next = _text(data.sublist(8));
    if (p2 == pivPinReference) {
      log.add('change pin');
      if (pinTries == 0) return _status(_blocked);
      if (!_matches(current, pin)) return _status(_wrong(--pinTries));
      if (next.length < 6) return _status(_wrongData);
      pin = next;
      pinTries = 3;
      _pinVerified = true;
      return _status(_ok);
    }
    if (p2 == pivPukReference) {
      log.add('change puk');
      if (pukTries == 0) return _status(_blocked);
      if (!_matches(current, puk)) return _status(_wrong(--pukTries));
      if (next.length != 8) return _status(_wrongData);
      puk = next;
      pukTries = 3;
      return _status(_ok);
    }
    return _status(0x6a88);
  }

  (List<int>, int) _unblock(Uint8List data) {
    log.add('unblock');
    if (data.length != 16) return _status(_wrongData);
    if (pukTries == 0) return _status(_blocked);
    if (!_matches(data.sublist(0, 8), puk)) return _status(_wrong(--pukTries));
    final next = _text(data.sublist(8));
    if (next.length < 6) return _status(_wrongData);
    pukTries = 3;
    pin = next;
    pinTries = 3;
    return _status(_ok);
  }

  PivSlot? _slot(int key) => PivSlot.values.where((slot) => slot.key == key).firstOrNull;

  (List<int>, int) _generate(int p2, Uint8List data) {
    final slot = _slot(p2);
    final algorithm = data.length == 5 && data[0] == 0xac && data[2] == 0x80 ? PivAlgorithm.byId(data[4]) : null;
    if (slot == null || algorithm == null) return _status(_wrongData);
    log.add('generate ${slot.id} ${_hex(algorithm.id)}');
    if (!_authenticated) return _status(_securityStatus);
    final key = generate(slot, algorithm);
    return (pivTlv(0x7f49, _publicParts(key)), _ok);
  }

  (List<int>, int) _authenticate(int p1, Uint8List data) {
    log.add('auth');
    final outer = readPivTlvs(data);
    if (outer.length != 1 || outer.single.tag != 0x7c) return _status(_wrongData);
    if (p1 != managementKeyType.id) {
      _witness = null;
      return _status(0x6a86);
    }
    final parts = readPivTlvs(outer.single.value);
    final given = parts.where((part) => part.tag == 0x80).firstOrNull?.value;
    final challenge = parts.where((part) => part.tag == 0x81).firstOrNull?.value;
    if (given != null && given.isEmpty && challenge == null) {
      final witness = _witness = randomBytes(managementKeyType.blockLength);
      return (pivTlv(0x7c, pivTlv(0x80, _block(witness, encrypt: true))), _ok);
    }
    final witness = _witness;
    _witness = null;
    if (witness == null || given == null || challenge == null || challenge.length != managementKeyType.blockLength) {
      return _status(_wrongData);
    }
    if (given.length != witness.length || [for (var i = 0; i < witness.length; i++) given[i] ^ witness[i]].any((x) => x != 0)) {
      _authenticated = false;
      return _status(_securityStatus);
    }
    _authenticated = true;
    return (pivTlv(0x7c, pivTlv(0x82, _block(challenge, encrypt: true))), _ok);
  }

  Uint8List _block(Uint8List block, {required bool encrypt}) {
    final cipher = managementKeyType == PivManagementKeyType.tripleDes ? pc.DESedeEngine() : pc.AESEngine() as pc.BlockCipher;
    cipher.init(encrypt, pc.KeyParameter(managementKey));
    final out = Uint8List(block.length);
    cipher.processBlock(block, 0, out, 0);
    return out;
  }

  (List<int>, int) _sign(int p1, int p2, Uint8List data) {
    final slot = _slot(p2);
    if (slot == null) return _status(0x6a86);
    log.add('sign ${slot.id}');
    final key = keys[slot];
    if (key == null) return _status(_notFound);
    if (_algorithmOf(key).id != p1) return _status(0x6a86);
    if (slot.needsPin && !_pinVerified) return _status(_securityStatus);
    // The signature slot wants the PIN before every signature.
    if (slot == PivSlot.signature) _pinVerified = false;
    final outer = readPivTlvs(data);
    if (outer.length != 1 || outer.single.tag != 0x7c) return _status(_wrongData);
    final input = readPivTlvs(outer.single.value).where((part) => part.tag == 0x81).firstOrNull?.value;
    if (input == null || input.isEmpty) return _status(_wrongData);
    final signed = signsWrongly ? Uint8List.fromList([...input.sublist(0, input.length - 1), input.last ^ 1]) : input;
    final Uint8List signature;
    switch (key) {
      case RsaMaterial(:final n, :final d):
        final size = (n.bitLength + 7) >> 3;
        if (signed.length != size) return _status(_wrongData);
        signature = bigIntToBytes(bytesToBigInt(signed).modPow(d, n), size);
      case EcMaterial(:final curve, :final d):
        if (signed.length != curve.size) return _status(_wrongData);
        // No digest: the card signs the hash it is given.
        final signer = pc.ECDSASigner(null, pc.HMac(pc.SHA256Digest(), 64))
          ..init(true, pc.PrivateKeyParameter<pc.ECPrivateKey>(pc.ECPrivateKey(bytesToBigInt(d), curve.domain)));
        final rs = signer.generateSignature(signed) as pc.ECSignature;
        signature = derSequence([derInteger(rs.r), derInteger(rs.s)]);
      default:
        return _status(_wrongData);
    }
    return (pivTlv(0x7c, pivTlv(0x82, signature)), _ok);
  }

  (List<int>, int) _setManagementKey(Uint8List data) {
    if (data.length < 3 || data[1] != pivManagementKeyReference || data.length != 3 + data[2]) return _status(_wrongData);
    log.add('set management key ${_hex(data[0])}');
    if (!_authenticated) return _status(_securityStatus);
    final type = PivManagementKeyType.byId(data[0]);
    if (refusesNewManagementKey) return _status(0x6985);
    if (type == null || data[2] != type.keyLength) return _status(_wrongData);
    if (refusesAes && type != PivManagementKeyType.tripleDes) return _status(0x6a86);
    managementKeyType = type;
    managementKey = Uint8List.fromList(data.sublist(3));
    return _status(_ok);
  }

  bool get _factoryManagementKey {
    if (managementKey.length != pivFactoryManagementKey.length) return false;
    for (var i = 0; i < managementKey.length; i++) {
      if (managementKey[i] != pivFactoryManagementKey[i]) return false;
    }
    return true;
  }

  (List<int>, int) _metadata(int reference) {
    if (!metadata) return _status(_notSupported);
    log.add('metadata ${_hex(reference)}');
    switch (reference) {
      case pivPinReference:
        return ([0x01, 0x01, 0xff, 0x05, 0x01, pin == pivFactoryPin ? 1 : 0, 0x06, 0x02, 3, pinTries], _ok);
      case pivPukReference:
        return ([0x01, 0x01, 0xff, 0x05, 0x01, puk == pivFactoryPuk ? 1 : 0, 0x06, 0x02, 3, pukTries], _ok);
      case pivManagementKeyReference:
        return ([0x01, 0x01, managementKeyType.id, 0x02, 0x02, 0x00, 0x01, 0x05, 0x01, _factoryManagementKey ? 1 : 0], _ok);
      default:
        final key = keys[_slot(reference)];
        if (key == null) return _status(_notFound);
        return ([0x01, 0x01, _algorithmOf(key).id, 0x02, 0x02, 0x02, 0x01, 0x03, 0x01, 0x01, ...pivTlv(0x04, _publicParts(key))], _ok);
    }
  }

  (List<int>, int) _reset() {
    log.add('reset');
    // Only a card whose PIN and PUK are both blocked takes it.
    if (pinTries != 0 || pukTries != 0) return _status(0x6985);
    keys.clear();
    objects.clear();
    pin = pivFactoryPin;
    puk = pivFactoryPuk;
    pinTries = 3;
    pukTries = 3;
    managementKeyType = PivManagementKeyType.tripleDes;
    managementKey = Uint8List.fromList(pivFactoryManagementKey);
    _pinVerified = false;
    _authenticated = false;
    return _status(_ok);
  }
}
