/// One conversation with a card's PIV application: what is read on
/// opening it, with no PIN (openspec: add-piv-management, design decision
/// 3), and the PIN or PUK held for as long as the conversation lasts.
library;

import 'dart:typed_data';

import '../../crypto/keys/algorithms.dart';
import 'piv_commands.dart';
import 'piv_data.dart';

/// What a slot's certificate object gave.
enum PivSlotStatus {
  /// Nothing: no certificate was ever stored, or it was removed.
  empty,

  /// Bytes that are, or should be, a certificate.
  certificate,

  /// The card keeps this object from the link it was asked over: the
  /// standard lets a card give all but 9e's certificate to the contact
  /// interface only.
  needsContact,

  /// An object that is not wrapped as a certificate is.
  unreadable,
}

/// One slot as it was read.
class PivSlotState {
  const PivSlotState(this.slot, this.status, {this.certificate, this.metadata});

  final PivSlot slot;
  final PivSlotStatus status;

  /// The certificate's bytes as the card holds them, unpacked. They are
  /// not checked to be a certificate here.
  final Uint8List? certificate;

  /// What the card says of the slot's key, on a card that says.
  final PivMetadata? metadata;

  /// The slot's public key, when the card reports it.
  PublicHalf? get publicKey => metadata?.publicKey;

  /// Whether something is stored in the slot's certificate object.
  bool get inUse => status == PivSlotStatus.certificate || status == PivSlotStatus.unreadable;
}

/// Everything read from a card's PIV application on opening it.
class PivState {
  const PivState({
    required this.slots,
    this.pinTries,
    this.pin,
    this.puk,
    this.managementKey,
    this.version,
    this.serial,
    this.cardId,
    this.hasCapabilityContainer = false,
    this.factoryManagementKey,
  });

  final Map<PivSlot, PivSlotState> slots;

  /// The PIN's tries left, read with a VERIFY that carries no PIN.
  final int? pinTries;

  /// What the card says of its three codes, on a card that says.
  final PivMetadata? pin;
  final PivMetadata? puk;
  final PivMetadata? managementKey;

  /// The maker's firmware version and serial number, on a card that
  /// answers those commands.
  final ({int major, int minor, int patch})? version;
  final int? serial;

  /// The card identifier in the capability container, in hex.
  final String? cardId;
  final bool hasCapabilityContainer;

  /// Whether the management key is the published one: from metadata, or
  /// from one authentication with it on a card without metadata. Null
  /// when neither told.
  final bool? factoryManagementKey;

  /// Whether the card answered the maker's commands, the family reset and
  /// "set management key" belong to. No brand or firmware table decides it.
  bool get makerCommands => version != null;

  /// The PUK's tries left: only a card with metadata reports them.
  int? get pukTries => puk?.triesLeft;

  bool get pinBlocked => pinTries == 0;
  bool get pukBlocked => pukTries == 0;

  /// The kind of the management key: what metadata says, or the
  /// standard's triple DES.
  PivManagementKeyType get managementKeyType =>
      PivManagementKeyType.byId(managementKey?.algorithm ?? PivManagementKeyType.tripleDes.id) ?? PivManagementKeyType.tripleDes;

  /// How many of the four slots hold something.
  int get slotsInUse => slots.values.where((slot) => slot.inUse).length;

  /// What names this card in a vault note: its serial number, or else its
  /// card identifier.
  String? get keyId => serial?.toString() ?? cardId;

  /// The same, once a capability container with the card identifier [id]
  /// was written.
  PivState withCardId(String id) => PivState(
    slots: slots,
    pinTries: pinTries,
    pin: pin,
    puk: puk,
    managementKey: managementKey,
    version: version,
    serial: serial,
    cardId: id,
    hasCapabilityContainer: true,
    factoryManagementKey: factoryManagementKey,
  );
}

/// One try is left: nothing was sent, and the person is asked first.
class PivLastTry implements Exception {
  const PivLastTry();
}

/// A card's PIV application, opened and read.
class PivSession {
  PivSession._(this.card, this.state);

  /// Reads the application behind [transmit], which was just selected:
  /// the four certificates, the PIN's tries left, and what the card
  /// answers of the maker's version, serial number and metadata. No PIN
  /// is sent and no try is spent. A group of commands answered "not
  /// supported" is left out, not guessed at.
  static Future<PivSession> open(PivTransmit transmit, {Uint8List Function(int length)? random}) async {
    final card = random == null ? PivCard(transmit) : PivCard(transmit, random: random);
    final session = PivSession._(card, const PivState(slots: {}));
    await session.refresh();
    return session;
  }

  final PivCard card;

  /// What the last [refresh] read.
  PivState state;

  Uint8List? _pin;
  Uint8List? _puk;

  /// Keeps the typed [pin] until [close].
  void holdPin(List<int> pin) {
    _wipe(_pin);
    _pin = Uint8List.fromList(pin);
  }

  /// Keeps the typed [puk] until [close].
  void holdPuk(List<int> puk) {
    _wipe(_puk);
    _puk = Uint8List.fromList(puk);
  }

  bool get holdsPin => _pin != null;

  /// Ends the conversation: the PIN and the PUK are wiped.
  void close() {
    _wipe(_pin);
    _wipe(_puk);
    _pin = null;
    _puk = null;
  }

  static void _wipe(Uint8List? bytes) => bytes?.fillRange(0, bytes.length, 0);

  /// Reads the application again, as after something changed it.
  Future<PivState> refresh() async {
    final slots = <PivSlot, PivSlotState>{};
    final certificates = <PivSlot, (PivSlotStatus, Uint8List?)>{};
    for (final slot in PivSlot.values) {
      certificates[slot] = await _readCertificate(slot);
    }
    final pinTries = await card.pinTries();
    final version = await _orNull(card.version);
    final serial = await _orNull(card.serial);

    // Metadata is one group: a card that does not know the command for the PIN is not asked for the rest.
    var hasMetadata = true;
    Future<PivMetadata?> metadata(int reference) async {
      if (!hasMetadata) return null;
      try {
        return await card.metadata(reference);
      } on PivNotSupported {
        hasMetadata = false;
        return null;
      } on PivError {
        // No key in the slot, or a refusal of this one reference.
        return null;
      } on PivFormatException {
        return null;
      }
    }

    final pin = await metadata(pivPinReference);
    final puk = await metadata(pivPukReference);
    final managementKey = await metadata(pivManagementKeyReference);
    for (final slot in PivSlot.values) {
      final (status, certificate) = certificates[slot]!;
      slots[slot] = PivSlotState(slot, status, certificate: certificate, metadata: await metadata(slot.key));
    }

    // The capability container's card identifier is written once and kept; the
    // card holder identifier is renewed with every certificate, so it names nothing.
    final cardId = await _orNull(() async => readPivCccId(await card.getData(pivCccObject)));
    final hasCcc = cardId != null;

    var factory = managementKey?.isDefault;
    if (managementKey == null) {
      // The one thing tried unasked: a failed management key authentication costs no try.
      try {
        await card.authenticate(PivManagementKeyType.tripleDes, pivFactoryManagementKey);
        factory = true;
      } on PivManagementKeyRefused {
        factory = false;
      }
    }

    return state = PivState(
      slots: slots,
      // A card that says the PIN was already given has its counter full again.
      pinTries: pinTries ?? pin?.triesLeft ?? state.pinTries,
      pin: pin,
      puk: puk,
      managementKey: managementKey,
      version: version,
      serial: serial,
      cardId: cardId,
      hasCapabilityContainer: hasCcc,
      factoryManagementKey: factory,
    );
  }

  Future<(PivSlotStatus, Uint8List?)> _readCertificate(PivSlot slot) async {
    final Uint8List object;
    try {
      object = await card.getData(slot.object);
    } on PivNotFound {
      return (PivSlotStatus.empty, null);
    } on PivSecurityStatus {
      return (PivSlotStatus.needsContact, null);
    }
    try {
      final certificate = unwrapPivCertificate(object);
      return certificate == null ? (PivSlotStatus.empty, null) : (PivSlotStatus.certificate, certificate);
    } on PivFormatException {
      return (PivSlotStatus.unreadable, object);
    }
  }

  Future<T?> _orNull<T>(Future<T> Function() ask) async {
    try {
      return await ask();
    } on PivError {
      return null;
    } on PivFormatException {
      return null;
    }
  }

  /// Gives the card the held PIN, after reading the tries left afresh:
  /// with none left nothing is sent and [PivBlocked] is thrown; with one
  /// left nothing is sent either, and [PivLastTry] is thrown, unless
  /// [lastTry] says the person was warned.
  Future<void> verifyPin({bool lastTry = false}) async {
    final pin = _pin;
    if (pin == null) throw StateError('No PIN is held.');
    final tries = await card.pinTries();
    if (tries == 0) throw const PivBlocked();
    if (tries == 1 && !lastTry) throw const PivLastTry();
    await card.verifyPin(pin);
  }

  /// Changes the PIN from the held one to [next], with the same care for
  /// the tries left as [verifyPin].
  Future<void> changePin(List<int> next, {bool lastTry = false}) async {
    final pin = _pin;
    if (pin == null) throw StateError('No PIN is held.');
    final tries = await card.pinTries();
    if (tries == 0) throw const PivBlocked();
    if (tries == 1 && !lastTry) throw const PivLastTry();
    await card.changePin(pin, next);
  }

  /// The PUK's tries left, read afresh on a card that reports them.
  Future<int?> _pukTries() async {
    if (state.puk == null) return null;
    try {
      return (await card.metadata(pivPukReference)).triesLeft;
    } on PivError {
      return null;
    }
  }

  Future<void> _checkPuk(bool lastTry) async {
    final tries = await _pukTries();
    if (tries == 0) throw const PivBlocked();
    if (tries == 1 && !lastTry) throw const PivLastTry();
  }

  /// Changes the PUK from the held one to [next].
  Future<void> changePuk(List<int> next, {bool lastTry = false}) async {
    final puk = _puk;
    if (puk == null) throw StateError('No PUK is held.');
    await _checkPuk(lastTry);
    await card.changePuk(puk, next);
  }

  /// Sets [newPin] with the held PUK, which unblocks a blocked PIN.
  Future<void> unblockPin(List<int> newPin, {bool lastTry = false}) async {
    final puk = _puk;
    if (puk == null) throw StateError('No PUK is held.');
    await _checkPuk(lastTry);
    await card.unblockPin(puk, newPin);
  }
}
