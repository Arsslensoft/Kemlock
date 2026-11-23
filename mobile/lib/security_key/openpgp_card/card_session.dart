/// What the features call to talk to a security key's OpenPGP card
/// application over one connection (openspec: add-openpgp-card, design
/// decisions 3, 8 and 13): open it and read what it reports, hold the PINs
/// typed for this connection, and run each command with the PIN it needs.
///
/// A PIN is never sent unless the person typed it for that purpose: an
/// operation that needs one the session does not hold throws
/// [CardPinNeeded] with the tries left, read just then, and the caller asks
/// for it and calls [OpenPgpCardSession.holdPin]. The tries left are read
/// before every PIN is sent, and nothing is sent when none is left. The
/// PINs held are wiped by [OpenPgpCardSession.close].
library;

import 'dart:typed_data';

import '../../crypto/keys/openpgp/s2k.dart' show iteratedSaltedS2kCount;
import '../../platform/security_keys.dart';
import '../apdu.dart';
import '../connection.dart';
import 'card_commands.dart';
import 'card_commands.dart' as commands show changePin, decipherEcdh, decipherRsa;
import 'card_data.dart';

/// An operation needs [pin], which this connection was not given.
/// [status] is the PIN status read just now, with the tries left.
final class CardPinNeeded extends CardError {
  const CardPinNeeded(this.pin, this.status);

  final CardPin pin;
  final PinStatus status;

  /// The tries left for [pin].
  int get triesLeft => switch (pin) {
    CardPin.admin => status.adminPinTries,
    CardPin.resetCode => status.resetCodeTries,
    _ => status.pinTries,
  };

  @override
  String toString() => 'CardPinNeeded(${pin.name}, $triesLeft left)';
}

/// The card wants its PINs hashed in a way Kemlock cannot: no PIN is sent
/// to it, so no try is spent.
final class CardKdfUnreadable extends CardError {
  const CardKdfUnreadable();
}

/// Everything read from a card on opening, without a PIN.
class CardSnapshot {
  const CardSnapshot({
    required this.data,
    this.touch = const {},
    this.kdf,
    this.algorithms,
    this.cardholder,
    this.url,
    this.signatureCounter,
  });

  /// The application related data: identifier, attributes, fingerprints,
  /// times, PIN status, key information, capabilities.
  final ApplicationData data;

  /// Each place's touch setting; empty when the card reports none.
  final Map<CardPlace, TouchSetting> touch;

  /// The KDF object; null when the card has none.
  final KdfSetting? kdf;

  /// The algorithms each place can be set to; null before version 3.4.
  final AlgorithmList? algorithms;
  final String? cardholder;

  /// The address the public key may be fetched from.
  final String? url;

  /// How many signatures the card has made.
  final int? signatureCounter;

  CardAid get aid => data.aid;
  PinStatus get pinStatus => data.pinStatus;

  /// The fingerprint written for [place], in upper-case hexadecimal.
  String? fingerprintHex(CardPlace place) {
    final fingerprint = data.fingerprints[place];
    return fingerprint == null ? null : cardHex(fingerprint);
  }

  CardSnapshot withPinStatus(PinStatus status) => CardSnapshot(
    data: data.withPinStatus(status),
    touch: touch,
    kdf: kdf,
    algorithms: algorithms,
    cardholder: cardholder,
    url: url,
    signatureCounter: signatureCounter,
  );
}

/// One conversation with a card's OpenPGP application, for as long as its
/// connection lasts.
class OpenPgpCardSession {
  OpenPgpCardSession._(this.connection, this._card, this.snapshot);

  /// Opens the application on [connection] and reads what it reports. A
  /// card left terminated by a factory reset that was cut off gives a
  /// session with [terminated] set and nothing read, which
  /// [finishReset] brings back.
  ///
  /// Throws [SecurityKeyNoApplication] for a key without the application,
  /// [CardError] for a refusal, [CardFormatError] for an answer that does
  /// not read, and what the connection throws.
  static Future<OpenPgpCardSession> open(SecurityKeyConnection connection) async {
    final card = await connection.selectApplication(openPgpAid, alsoSelected: const {CardStatus.terminated});
    final session = OpenPgpCardSession._(connection, card, null);
    if (card.selectStatus == CardStatus.terminated) return session;
    session.snapshot = await session._read();
    return session;
  }

  final SecurityKeyConnection connection;
  SmartCardSession _card;

  /// What the card reported when it was last read; null for a terminated
  /// card.
  CardSnapshot? snapshot;

  final Map<CardPin, Uint8List> _held = {};
  final Set<CardPin> _verified = {};
  bool _closed = false;

  /// Whether the card is in its termination state.
  bool get terminated => snapshot == null;

  bool get isOpen => !_closed && connection.isOpen;

  /// The snapshot, which a terminated card has not.
  CardSnapshot get read => snapshot ?? (throw const CardTerminated());

  Future<Uint8List> _send(ApduCommand command, {CardPin? pin}) async {
    if (_closed) throw const SecurityKeyRemoved();
    return cardAnswer(await _card.transmit(command), pin: pin);
  }

  /// The value of the object [tag], or null when the card does not have it.
  Future<Uint8List?> _optional(int tag) async {
    try {
      return await _send(getData(tag));
    } on CardNotFound {
      return null;
    } on CardNotSupported {
      return null;
    } on CardRefused {
      // Older cards answer "wrong parameters" in their own ways
      return null;
    }
  }

  Future<CardSnapshot> _read() async {
    final data = ApplicationData.parse(await _send(getData(0x6e)));
    final touch = <CardPlace, TouchSetting>{};
    if (data.aid.isV3) {
      for (final place in CardPlace.values) {
        final value = await _optional(place.touch);
        if (value != null && value.isNotEmpty) touch[place] = TouchSetting(unwrapTlv(value, place.touch));
      }
    }
    final kdf = data.capabilities?.kdf ?? false ? await _optional(0xf9) : null;
    final algorithms = data.aid.isV3 ? await _optional(0xfa) : null;
    final holder = await _optional(0x65);
    final url = await _optional(0x5f50);
    final security = await _optional(0x7a);
    return CardSnapshot(
      data: data,
      touch: touch,
      kdf: kdf == null || kdf.isEmpty ? null : KdfSetting.parse(kdf),
      algorithms: algorithms == null || algorithms.isEmpty ? null : AlgorithmList.parse(algorithms),
      cardholder: holder == null || holder.isEmpty ? null : cardholderName(holder),
      url: url == null || url.isEmpty ? null : String.fromCharCodes(unwrapTlv(url, 0x5f50)),
      signatureCounter: security == null || security.isEmpty ? null : signatureCounter(security),
    );
  }

  /// Reads everything again, as after a change.
  Future<CardSnapshot> refresh() async => snapshot = await _read();

  /// Reads the PIN status afresh: how many tries each PIN has left.
  Future<PinStatus> readPinStatus() async {
    final status = PinStatus(unwrapTlv(await _send(getData(0xc4)), 0xc4));
    final current = snapshot;
    if (current != null) snapshot = current.withPinStatus(status);
    return status;
  }

  // ─── PINs ───────────────────────────────────────────────────────────────────

  /// Keeps [value], as typed (UTF-8), for [pin] until [close]: it is sent
  /// when an operation needs it, and again before each signature on a
  /// card that wants the PIN for every one. [CardPin.pinToSign] and
  /// [CardPin.pin] are the same PIN.
  void holdPin(CardPin pin, Uint8List value) {
    final key = pin == CardPin.pinToSign ? CardPin.pin : pin;
    _wipe(_held.remove(key));
    _held[key] = Uint8List.fromList(value);
  }

  /// A copy of the value held for [pin], for the owner of this connection
  /// to give the next session on it; null when none is.
  Uint8List? held(CardPin pin) {
    final value = _held[pin == CardPin.pinToSign ? CardPin.pin : pin];
    return value == null ? null : Uint8List.fromList(value);
  }

  /// Whether a value is held for [pin].
  bool holds(CardPin pin) => _held.containsKey(pin == CardPin.pinToSign ? CardPin.pin : pin);

  /// Forgets what was held for [pin], as after the card refused it.
  void forget(CardPin pin) {
    final key = pin == CardPin.pinToSign ? CardPin.pin : pin;
    _wipe(_held.remove(key));
    if (key == CardPin.pin) {
      _verified
        ..remove(CardPin.pin)
        ..remove(CardPin.pinToSign);
    } else {
      _verified.remove(key);
    }
  }

  static void _wipe(Uint8List? bytes) => bytes?.fillRange(0, bytes.length, 0);

  /// The tries [status] gives for [pin].
  static int triesOf(PinStatus status, CardPin pin) => switch (pin) {
    CardPin.admin => status.adminPinTries,
    CardPin.resetCode => status.resetCodeTries,
    _ => status.pinTries,
  };

  /// What is sent for [value], the PIN [pin] as typed: the value itself,
  /// or its hash when the card hashes its PINs. Throws
  /// [CardKdfUnreadable] for a KDF object Kemlock cannot follow.
  Uint8List prepare(CardPin pin, Uint8List value) {
    final kdf = snapshot?.kdf;
    if (kdf == null || !kdf.on) return value;
    // A plain PIN to a card that wants a hash spends a try for nothing: a KDF it cannot follow stops here
    if (!kdf.readable) throw const CardKdfUnreadable();
    final salt = switch (pin) {
      CardPin.admin => kdf.saltAdmin!,
      CardPin.resetCode => kdf.saltResetCode ?? kdf.saltPin!,
      _ => kdf.saltPin!,
    };
    return iteratedSaltedS2kCount(value, salt, kdf.count!, hashAlgorithm: kdf.hash == 0x0a ? 10 : 8);
  }

  /// Sends [command], which carries a value for [pin], and says what the
  /// card's refusal of that value is. The specification's answer to a wrong
  /// value is `6982`, the status of a command whose PIN was not given, with
  /// the tries left to be read from the PIN status; some cards answer
  /// `63Cx`. Either way what is held for [pin] is forgotten first, so that
  /// no later command sends it again, the tries are read afresh, and
  /// [CardWrongPin] is thrown with them, or [CardPinBlocked] when none is
  /// left.
  Future<void> _sendPin(CardPin pin, ApduCommand command) async {
    try {
      await _send(command, pin: pin);
    } on CardPinBlocked {
      forget(pin);
      rethrow;
    } on CardError catch (error) {
      if (error is! CardWrongPin && error is! CardSecurityNotSatisfied) rethrow;
      forget(pin);
      final left = triesOf(await readPinStatus(), pin);
      if (left == 0) throw CardPinBlocked(pin);
      throw CardWrongPin(pin, left);
    }
  }

  /// Verifies [pin] with the value held for it, after reading its tries:
  /// throws [CardPinNeeded] when none is held, [CardPinBlocked] with
  /// nothing sent when no try is left, and [CardWrongPin] with the tries
  /// read again after a refusal, the value then forgotten.
  Future<void> _verify(CardPin pin) async {
    final held = _held[pin == CardPin.pinToSign ? CardPin.pin : pin];
    final status = await readPinStatus();
    if (triesOf(status, pin) == 0) throw CardPinBlocked(pin);
    if (held == null) throw CardPinNeeded(pin, status);
    await _sendPin(pin, verifyPin(pin, prepare(pin, held)));
    _verified.add(pin);
  }

  /// Makes sure [pin] counts for the next command: verified once per
  /// connection, or before each signature when the card wants that.
  Future<void> _need(CardPin pin) async {
    final everySignature = pin == CardPin.pinToSign && read.pinStatus.pinForEverySignature;
    if (!everySignature && _verified.contains(pin)) return;
    await _verify(pin);
  }

  /// Runs [command], which needs [pin]; a card that says the PIN no longer
  /// counts is given it once more.
  Future<Uint8List> _withPin(CardPin pin, ApduCommand command) async {
    await _need(pin);
    try {
      return await _send(command);
    } on CardSecurityNotSatisfied {
      _verified.remove(pin);
      await _verify(pin);
      return _send(command);
    }
  }

  // ─── Private operations ─────────────────────────────────────────────────────

  /// The signature place's signature of [input]: a DigestInfo for RSA,
  /// the hash for ECDSA and EdDSA.
  Future<Uint8List> sign(Uint8List input) => _withPin(CardPin.pinToSign, computeSignature(input));

  /// The decryption place's RSA decryption of [cryptogram]: the message
  /// inside, its padding taken off by the card.
  Future<Uint8List> decipherRsa(Uint8List cryptogram) => _withPin(CardPin.pin, commands.decipherRsa(cryptogram));

  /// The decryption place's ECDH with the other side's [point].
  Future<Uint8List> decipherEcdh(Uint8List point) => _withPin(CardPin.pin, commands.decipherEcdh(point));

  /// The authentication place's signature of [input].
  Future<Uint8List> authenticate(Uint8List input) => _withPin(CardPin.pin, internalAuthenticate(input));

  /// The public key in [place]; no PIN.
  Future<CardPublicKey> readPublicKey(CardPlace place) async => CardPublicKey.parse(await _send(generateKey(place, read: true)));

  // ─── With the admin PIN ─────────────────────────────────────────────────────

  Future<void> _admin(ApduCommand command) => _withPin(CardPin.admin, command);

  /// Sets whether the PIN is asked for every signature.
  Future<void> setPinForEverySignature(bool every) async {
    await _admin(putPinPolicy(everySignature: every));
    await readPinStatus();
  }

  /// Sets [place]'s touch setting.
  Future<void> setTouch(CardPlace place, TouchPolicy policy) => _admin(putTouch(place, policy));

  /// Sets [place]'s algorithm; a key of another kind there is lost.
  Future<void> setAlgorithm(CardPlace place, CardAlgorithm algorithm) => _admin(putAttributes(place, algorithm));

  /// Makes a new key in [place] and gives its public key.
  Future<CardPublicKey> generate(CardPlace place) async {
    await _need(CardPin.admin);
    final answer = await _send(generateKey(place));
    return CardPublicKey.parse(answer);
  }

  /// Puts a key's [parts] into [place] (see [importKey]).
  Future<void> putKey(CardPlace place, List<(int, List<int>)> parts) => _admin(importKey(place, parts));

  /// Writes [place]'s fingerprint and creation time.
  Future<void> putKeyIdentity(CardPlace place, Uint8List fingerprint, DateTime created) async {
    await _admin(putFingerprint(place, fingerprint));
    await _admin(putKeyTime(place, created));
  }

  /// Sets the reset code, or removes it when [code] is null.
  Future<void> setResetCode(Uint8List? code) async {
    await _admin(putResetCode(code == null ? const [] : prepare(CardPin.resetCode, code)));
    await readPinStatus();
  }

  /// Sets a new PIN with the admin PIN, which unblocks a blocked one.
  Future<void> unblockWithAdmin(Uint8List newPin) async {
    await _admin(resetPin(prepare(CardPin.pin, newPin)));
    _afterNewPin(newPin);
  }

  // ─── Without a held PIN ─────────────────────────────────────────────────────

  /// Changes [pin] (the PIN or the admin PIN) from [current] to [next].
  /// The tries are read first, and nothing is sent when none is left.
  Future<void> changePin(CardPin pin, Uint8List current, Uint8List next) async {
    final status = await readPinStatus();
    if (triesOf(status, pin) == 0) throw CardPinBlocked(pin);
    await _sendPin(pin, commands.changePin(pin, prepare(pin, current), prepare(pin, next)));
    forget(pin);
    if (pin == CardPin.pin) {
      _afterNewPin(next);
    } else {
      holdPin(CardPin.admin, next);
    }
    await readPinStatus();
  }

  /// Sets a new PIN with the reset code, which unblocks a blocked one.
  Future<void> unblockWithResetCode(Uint8List code, Uint8List newPin) async {
    final status = await readPinStatus();
    if (status.resetCodeTries == 0) throw const CardPinBlocked(CardPin.resetCode);
    await _sendPin(CardPin.resetCode, resetPin(prepare(CardPin.pin, newPin), resetCode: prepare(CardPin.resetCode, code)));
    _afterNewPin(newPin);
  }

  void _afterNewPin(Uint8List pin) {
    forget(CardPin.pin);
    holdPin(CardPin.pin, pin);
  }

  // ─── Factory reset ──────────────────────────────────────────────────────────

  /// Whether the card says it can be terminated and activated again.
  bool get canReset => snapshot?.data.historical?.lifeCycleManagement ?? false;

  /// Erases the card's PGP keys and returns its PINs to the factory ones:
  /// both PINs are blocked with values nobody typed, then the application
  /// is terminated and activated, and read again. The one place Kemlock
  /// sends PINs the person did not type; the caller has the person
  /// confirm first.
  ///
  /// Each wrong value must take a try: on a card whose count stays where
  /// it was, the reset ends with [CardNotSupported] before the card is
  /// terminated, rather than going on for ever.
  Future<CardSnapshot> factoryReset() async {
    if (!canReset) throw const CardNotSupported(CardStatus.insNotSupported);
    for (final pin in [CardPin.pin, CardPin.admin]) {
      var status = await readPinStatus();
      var left = triesOf(status, pin);
      while (left > 0) {
        try {
          await _send(verifyPin(pin, _wrongValue()), pin: pin);
        } on CardWrongPin {
          // As intended
        } on CardSecurityNotSatisfied {
          // As intended too: how the specification's cards refuse a wrong value
        } on CardPinBlocked {
          // Blocked: done with this one
        }
        status = await readPinStatus();
        final now = triesOf(status, pin);
        if (now >= left) throw const CardNotSupported(CardStatus.insNotSupported);
        left = now;
      }
    }
    _clearPins();
    await _send(terminate());
    return finishReset();
  }

  /// A value that cannot be the PIN, which the card still counts as a
  /// try: when it hashes, all zeros of the hash's length, which no PIN
  /// hashes to; else eight zero bytes, as Yubico's tools send, which no
  /// PIN typed as text holds. GnuPG sends "@" eight times, which a person
  /// can type and set, and a right PIN would fill the counter again.
  Uint8List _wrongValue() {
    final kdf = snapshot?.kdf;
    if (kdf != null && kdf.on) return Uint8List(kdf.hash == 0x0a ? 64 : 32);
    return Uint8List(8);
  }

  /// Activates a terminated application and reads it again: the second
  /// half of a factory reset.
  Future<CardSnapshot> finishReset() async {
    await _send(activate());
    _card = await connection.selectApplication(openPgpAid);
    _clearPins();
    return snapshot = await _read();
  }

  // ─── Ending ─────────────────────────────────────────────────────────────────

  void _clearPins() {
    for (final value in _held.values) {
      _wipe(value);
    }
    _held.clear();
    _verified.clear();
  }

  /// Ends the conversation: every PIN held is wiped. The connection itself
  /// is its owner's to close.
  void close() {
    _closed = true;
    _clearPins();
  }

  /// For tests: whether any PIN is still held.
  bool get holdsAnyPin => _held.isNotEmpty;
}
