/// The commands of a PIV card (NIST SP 800-73-4 part 2) and the ones
/// Yubico added, which some other makers copy: each as the bytes it
/// sends and what it reads back, with the card's refusals as named
/// errors. Chained commands and long answers are the connection's work
/// (`apdu.dart`), so nothing here knows of them.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import '../../crypto/bytes.dart';
import '../../crypto/keys/algorithms.dart';
import '../apdu.dart';
import 'piv_data.dart';

/// A card refused a PIV command. One subclass for each refusal the
/// screens tell apart.
sealed class PivError implements Exception {
  const PivError();
}

/// The PIN or PUK sent was wrong; [triesLeft] are left.
class PivWrongCode extends PivError {
  const PivWrongCode(this.triesLeft);

  final int triesLeft;

  @override
  String toString() => 'PivWrongCode($triesLeft tries left)';
}

/// The PIN or PUK has no tries left.
class PivBlocked extends PivError {
  const PivBlocked();
}

/// "Security status not satisfied": the command wants the PIN or the
/// management key first, or the card keeps the object from this link.
class PivSecurityStatus extends PivError {
  const PivSecurityStatus();
}

/// The card has no such object or key.
class PivNotFound extends PivError {
  const PivNotFound();
}

/// The card does not know the command: a maker's addition it lacks.
class PivNotSupported extends PivError {
  const PivNotSupported();
}

/// The card has no room for what was sent.
class PivNoRoom extends PivError {
  const PivNoRoom();
}

/// The card did not accept the management key.
class PivManagementKeyRefused extends PivError {
  const PivManagementKeyRefused();
}

/// Any other refusal, with the card's status word.
class PivRefused extends PivError {
  const PivRefused(this.sw);

  final int sw;

  @override
  String toString() => 'PivRefused(${sw.toRadixString(16).padLeft(4, '0')})';
}

/// The named error for the status word [sw] of a refused command.
PivError pivErrorFor(int sw) {
  if (sw & 0xfff0 == 0x63c0) return sw & 0x0f == 0 ? const PivBlocked() : PivWrongCode(sw & 0x0f);
  return switch (sw) {
    0x6983 => const PivBlocked(),
    0x6982 => const PivSecurityStatus(),
    0x6a82 || 0x6a88 => const PivNotFound(),
    0x6d00 || 0x6e00 || 0x6a81 => const PivNotSupported(),
    0x6a84 => const PivNoRoom(),
    _ => PivRefused(sw),
  };
}

/// A PIN or PUK as a card takes it: its bytes, then `FF` up to eight.
Uint8List padPivCode(List<int> code) {
  if (code.isEmpty || code.length > 8) throw ArgumentError.value(code.length, 'code', 'must be 1 to 8 bytes');
  return Uint8List(8)
    ..fillRange(0, 8, 0xff)
    ..setAll(0, code);
}

/// Sends one command to the card and returns its whole answer.
typedef PivTransmit = Future<ApduResponse> Function(ApduCommand command);

/// The PIV application of a card, once selected: one method for each
/// command. Every method throws a [PivError] when the card refuses, and
/// [PivFormatException] for an answer that is not what PIV says.
class PivCard {
  PivCard(this._transmit, {this._random = randomBytes});

  final PivTransmit _transmit;
  final Uint8List Function(int length) _random;

  Future<Uint8List> _send(ApduCommand command) async {
    final response = await _transmit(command);
    if (!response.ok) throw pivErrorFor(response.sw);
    return response.data;
  }

  // ─── Data objects ───────────────────────────────────────────────────────────

  /// GET DATA: the data [object] as the card holds it, `53` and all.
  /// Throws [PivNotFound] for an object that was never written.
  Future<Uint8List> getData(int object) =>
      _send(ApduCommand(ins: 0xcb, p1: 0x3f, p2: 0xff, data: pivTlv(0x5c, pivObjectId(object)), le: apduShortLe));

  /// PUT DATA: writes [contents] as the data [object]. Needs the
  /// management key.
  Future<void> putData(int object, List<int> contents) =>
      _send(ApduCommand(ins: 0xdb, p1: 0x3f, p2: 0xff, data: [...pivTlv(0x5c, pivObjectId(object)), ...pivTlv(0x53, contents)]));

  // ─── The PIN and the PUK ────────────────────────────────────────────────────

  /// How many tries the PIN has left, asked with a VERIFY that carries no
  /// PIN, which is not a try. Null when the card says the PIN was already
  /// given in this session.
  Future<int?> pinTries() async {
    final response = await _transmit(ApduCommand(ins: 0x20, p2: pivPinReference));
    if (response.ok) return null;
    final error = pivErrorFor(response.sw);
    if (error is PivWrongCode) return error.triesLeft;
    if (error is PivBlocked) return 0;
    throw error;
  }

  /// VERIFY: gives the card the [pin]. Throws [PivWrongCode] with the
  /// tries left, or [PivBlocked].
  Future<void> verifyPin(List<int> pin) => _send(ApduCommand(ins: 0x20, p2: pivPinReference, data: padPivCode(pin)));

  /// CHANGE REFERENCE DATA for the PIN.
  Future<void> changePin(List<int> current, List<int> next) => _change(pivPinReference, current, next);

  /// CHANGE REFERENCE DATA for the PUK.
  Future<void> changePuk(List<int> current, List<int> next) => _change(pivPukReference, current, next);

  Future<void> _change(int reference, List<int> current, List<int> next) =>
      _send(ApduCommand(ins: 0x24, p2: reference, data: [...padPivCode(current), ...padPivCode(next)]));

  /// RESET RETRY COUNTER: sets a [newPin] with the [puk], which unblocks
  /// a blocked PIN. A wrong PUK throws [PivWrongCode] with the PUK's
  /// tries left.
  Future<void> unblockPin(List<int> puk, List<int> newPin) =>
      _send(ApduCommand(ins: 0x2c, p2: pivPinReference, data: [...padPivCode(puk), ...padPivCode(newPin)]));

  // ─── Keys ───────────────────────────────────────────────────────────────────

  /// GENERATE ASYMMETRIC KEY PAIR: the card makes a key of [algorithm] in
  /// [slot] and gives its public half. Needs the management key.
  Future<PublicHalf> generate(PivSlot slot, PivAlgorithm algorithm) async {
    final answer = await _send(ApduCommand(ins: 0x47, p2: slot.key, data: pivTlv(0xac, pivTlv(0x80, [algorithm.id])), le: apduShortLe));
    return readPivGeneratedKey(algorithm, answer);
  }

  /// GENERAL AUTHENTICATE with the key in [slot]: the card's raw private
  /// key operation on [input]. For RSA [input] is a whole padded block
  /// and the answer the signature; for a curve it is a hash and the
  /// answer a DER `ECDSA-Sig-Value`. Needs the PIN in every slot but 9e.
  Future<Uint8List> sign(PivSlot slot, PivAlgorithm algorithm, List<int> input) async {
    final answer = await _send(
      ApduCommand(
        ins: 0x87,
        p1: algorithm.id,
        p2: slot.key,
        data: pivTlv(0x7c, [...pivTlv(0x82, const []), ...pivTlv(0x81, input)]),
        le: apduShortLe,
      ),
    );
    return _dynamic(answer, 0x82);
  }

  // ─── The management key ─────────────────────────────────────────────────────

  /// Proves the management [key] of kind [type] to the card, and the card
  /// to this side: the standard's mutual challenge and response. Throws
  /// [PivManagementKeyRefused] when the card does not accept it, or does
  /// not answer as the key's holder would.
  Future<void> authenticate(PivManagementKeyType type, List<int> key) async {
    if (key.length != type.keyLength) throw const PivManagementKeyRefused();
    final Uint8List witness;
    final Uint8List response;
    final challenge = _random(type.blockLength);
    try {
      // "Give me a witness": the card sends a random block, encrypted.
      final first = await _send(_authenticate(type, pivTlv(0x80, const [])));
      witness = _dynamic(first, 0x80);
      if (witness.length != type.blockLength) throw const PivManagementKeyRefused();
      // The witness decrypted proves this side; the challenge is for the card to encrypt.
      final second = await _send(
        _authenticate(type, [...pivTlv(0x80, _block(type, key, witness, encrypt: false)), ...pivTlv(0x81, challenge)]),
      );
      response = _dynamic(second, 0x82);
    } on PivError {
      throw const PivManagementKeyRefused();
    } on PivFormatException {
      throw const PivManagementKeyRefused();
    }
    if (!_same(response, _block(type, key, challenge, encrypt: true))) throw const PivManagementKeyRefused();
  }

  ApduCommand _authenticate(PivManagementKeyType type, List<int> template) =>
      ApduCommand(ins: 0x87, p1: type.id, p2: pivManagementKeyReference, data: pivTlv(0x7c, template), le: apduShortLe);

  /// The maker's SET MANAGEMENT KEY: [key] of kind [type], used without a
  /// touch. Needs the present management key. Throws [PivNotSupported]
  /// on a card without the command and [PivRefused] on one that does not
  /// take the kind.
  Future<void> setManagementKey(PivManagementKeyType type, List<int> key) {
    if (key.length != type.keyLength) throw ArgumentError.value(key.length, 'key', 'not the length of ${type.name}');
    return _send(ApduCommand(ins: 0xff, p1: 0xff, p2: 0xff, data: [type.id, pivManagementKeyReference, key.length, ...key]));
  }

  // ─── The maker's other additions ────────────────────────────────────────────

  /// What the card says of the code or slot with the key [reference]:
  /// [pivPinReference], [pivPukReference], [pivManagementKeyReference] or
  /// a slot's key. Throws [PivNotFound] for a slot with no key.
  Future<PivMetadata> metadata(int reference) async =>
      PivMetadata.parse(await _send(ApduCommand(ins: 0xf7, p2: reference, le: apduShortLe)));

  /// The firmware version.
  Future<({int major, int minor, int patch})> version() async => readPivVersion(await _send(ApduCommand(ins: 0xfd, le: apduShortLe)));

  /// The serial number.
  Future<int> serial() async => readPivSerial(await _send(ApduCommand(ins: 0xf8, le: apduShortLe)));

  /// Erases every key and certificate and puts the three codes back to
  /// the factory ones. The card takes it only once the PIN and the PUK
  /// are both blocked.
  Future<void> reset() => _send(ApduCommand(ins: 0xfb));

  /// The value with [tag] in a dynamic authentication template, `7C`.
  Uint8List _dynamic(Uint8List answer, int tag) {
    final outer = readPivTlvs(answer);
    if (outer.length != 1 || outer.single.tag != 0x7c) throw const PivFormatException('not an authentication template');
    final value = readPivTlvs(outer.single.value).where((part) => part.tag == tag).firstOrNull?.value;
    if (value == null) throw const PivFormatException('authentication template without its answer');
    return value;
  }
}

/// One block of triple DES or AES with [key], as the management key
/// exchange uses them: no chaining, no padding.
Uint8List _block(PivManagementKeyType type, List<int> key, Uint8List block, {required bool encrypt}) {
  final cipher = type == PivManagementKeyType.tripleDes ? pc.DESedeEngine() : pc.AESEngine() as pc.BlockCipher;
  cipher.init(encrypt, pc.KeyParameter(Uint8List.fromList(key)));
  final out = Uint8List(block.length);
  cipher.processBlock(block, 0, out, 0);
  return out;
}

/// Whether [key] is a triple DES key a card may refuse as weak: one whose
/// three parts are not all different, or one of DES's weak and semi-weak
/// keys.
bool isWeakTripleDesKey(List<int> key) {
  if (key.length != 24) return true;
  final parts = [for (var i = 0; i < 24; i += 8) _hex(_withoutParity(key.sublist(i, i + 8)))];
  if (parts.toSet().length != 3) return true;
  return parts.any(_weakDesKeys.contains);
}

/// [key] with every byte given odd parity in its lowest bit, as DES keys
/// are written.
Uint8List withOddParity(List<int> key) => Uint8List.fromList([for (final byte in key) (byte & 0xfe) | (_ones(byte >> 1).isEven ? 1 : 0)]);

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

int _ones(int value) {
  var count = 0;
  for (var v = value; v > 0; v >>= 1) {
    count += v & 1;
  }
  return count;
}

List<int> _withoutParity(List<int> key) => [for (final byte in key) byte & 0xfe];

String _hex(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

/// DES's four weak and twelve semi-weak keys, parity bits cleared.
const _weakDesKeys = {
  '0000000000000000', 'fefefefefefefefe', 'e0e0e0e0f0f0f0f0', '1e1e1e1e0e0e0e0e', //
  '00fe00fe00fe00fe', 'fe00fe00fe00fe00', '1ee01ee00ef00ef0', 'e01ee01ef00ef00e',
  '00e000e000f000f0', 'e000e000f000f000', '1efe1efe0efe0efe', 'fe1efe1efe0efe0e',
  '001e001e000e000e', '1e001e000e000e00', 'e0fee0fef0fef0fe', 'fee0fee0fef0fef0',
};
