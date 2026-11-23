import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/openpgp_card/card_commands.dart';
import '../../security_key/openpgp_card/card_data.dart';
import '../../security_key/openpgp_card/card_operations.dart';
import '../../security_key/openpgp_card/card_session.dart';
import 'security_key_controller.dart';

/// The state behind the "PGP keys" row and the sheets it opens
/// (openspec: add-openpgp-card): what the key's OpenPGP card application
/// showed when the key was last read, and the PINs typed for the
/// connection now open. It lives as long as the Security key sheet,
/// beside its [SecurityKeyController], and stores nothing.
///
/// A PIN is kept for the connection it was used on, so that one is asked
/// once per connection, and is wiped when the connection changes, the key
/// is forgotten or taken away, the app is hidden, or the sheet closes. One
/// typed before a connection, as on an iPhone, where each read is a
/// connection of its own, goes to the next one, if its card is the one
/// it was typed for, and goes with it: an action that asks for a further
/// PIN keeps those it was given for its next read, and no longer.
class OpenPgpCardController extends ChangeNotifier with WidgetsBindingObserver {
  OpenPgpCardController._(this.keys, this._onSnapshot) {
    keys.readers.add(peek);
    keys.addListener(_onKeysChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  static final _attached = Expando<OpenPgpCardController>();

  /// Makes the controller of [keys]' card, which reads the card each time
  /// [keys] reads the key.
  static OpenPgpCardController attach(SecurityKeyController keys, {void Function(CardSnapshot snapshot)? onSnapshot}) =>
      _attached[keys] = OpenPgpCardController._(keys, onSnapshot);

  /// The controller [attach] made for [keys], if any.
  static OpenPgpCardController? of(SecurityKeyController keys) => _attached[keys];

  final SecurityKeyController keys;

  /// Told what each read of a card showed.
  final void Function(CardSnapshot snapshot)? _onSnapshot;

  bool _present = false;
  bool _terminated = false;
  CardSnapshot? _snapshot;
  SecurityKeyConnection? _connection;
  final Map<CardPin, Uint8List> _pins = {};

  /// Whether a PIN was given since the last run, which the PINs may then
  /// follow to another connection, and the identifier of the card it was
  /// given for, which that connection's card must have.
  bool _carry = false;
  String? _pinsFor;
  bool _disposed = false;

  /// Whether the key read last has an OpenPGP card application.
  bool get present => _present;

  /// Whether that application was left terminated by a reset cut short.
  bool get terminated => _terminated;

  /// What it reported when last read; null before a read, or for a terminated
  /// card.
  CardSnapshot? get snapshot => _snapshot;

  void _notify() {
    if (_disposed) return;
    if (_snapshot case final snapshot?) _onSnapshot?.call(snapshot);
    notifyListeners();
  }

  void _wipePins() {
    for (final value in _pins.values) {
      value.fillRange(0, value.length, 0);
    }
    _pins.clear();
    _carry = false;
    _pinsFor = null;
  }

  void _forget() {
    _wipePins();
    _present = false;
    _terminated = false;
    _snapshot = null;
    _connection = null;
  }

  void _onKeysChanged() {
    // A key forgotten (taken away, the vault locked) takes its card with it
    if (keys.key == null && (_present || _pins.isNotEmpty)) {
      _forget();
      _notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _wipePins();
  }

  /// Takes [connection] as the one the PINs are for. Those of another are
  /// wiped, but for PINs given since the last run, which come along: true
  /// then, and [_arrived] keeps them only on the card they were typed for.
  bool _usingConnection(SecurityKeyConnection connection) {
    if (identical(connection, _connection)) return false;
    _connection = connection;
    if (_carry && _pins.isNotEmpty) return true;
    _wipePins();
    return false;
  }

  /// PINs that [came] from another connection are wiped unless [card],
  /// what this one showed, is the card they were typed for.
  void _arrived(bool came, CardSnapshot? card) {
    if (came && (card == null || card.aid.hex != _pinsFor)) _wipePins();
  }

  /// Reads the card on [connection] as the key is read, and never throws.
  /// It reads, without a PIN, what the row's summary says. One of the Security
  /// key sheet controller's `readers`.
  Future<void> peek(SecurityKeyConnection connection) async {
    if (!connection.isOpen) return;
    final came = _usingConnection(connection);
    CardSnapshot? seen;
    try {
      final session = await OpenPgpCardSession.open(connection);
      _present = true;
      _terminated = session.terminated;
      _snapshot = seen = session.snapshot;
      session.close();
    } on SecurityKeyNoApplication {
      _present = false;
      _terminated = false;
      _snapshot = null;
    } on SecurityKeyNotDeclared {
      _present = false;
      _snapshot = null;
    } on Object {
      // A card that could not be read now keeps what was read before
    }
    _arrived(came, seen);
    _notify();
  }

  /// Runs [action] on the card of the key connected, or of the next one
  /// presented, with the PINs already typed on this connection; what the
  /// card reports afterwards is shown. Throws what [action] and the card
  /// throw: [CardPinNeeded] when a PIN must be asked for, which
  /// [givePin] then holds.
  ///
  /// With [only], what the card the person said yes for showed, a card
  /// that does not show the same identifier and the same keys throws
  /// [CardWrongCard] before [action], and nothing is sent to it but the
  /// reads: a factory reset needs no PIN, and two cards may share one, so
  /// nothing else would stop an erasure on a second key held to the phone
  /// in the first one's place.
  ///
  /// PINs given since the last run go to this one, also on a connection of
  /// its own, when its card is the one they were typed for. A connection
  /// that ends with the run, as each read under iPhone's NFC sheet does,
  /// takes its PINs with it, unless the run ends asking for another
  /// ([CardPinNeeded], [CardWrongPin]): they then wait for the one given
  /// next, and go with it to the next run.
  Future<T> run<T>(Future<T> Function(OpenPgpCardSession session) action, {CardSnapshot? only}) async {
    SecurityKeyConnection? used;
    var asking = false;
    try {
      return await keys.runOnConnection((connection) async {
        used = connection;
        final came = _usingConnection(connection);
        _carry = false;
        final OpenPgpCardSession session;
        try {
          session = await OpenPgpCardSession.open(connection);
        } on Object {
          if (came) _wipePins();
          rethrow;
        }
        _arrived(came, session.snapshot);
        for (final MapEntry(key: pin, value: value) in _pins.entries) {
          session.holdPin(pin, value);
        }
        try {
          if (only != null && !_sameCard(only, session.snapshot)) throw const CardWrongCard();
          return await action(session);
        } finally {
          _present = true;
          _terminated = session.terminated;
          _snapshot = session.snapshot ?? _snapshot;
          // What the session holds now: a PIN the card refused is gone, a new one is kept
          for (final pin in const [CardPin.pin, CardPin.admin, CardPin.resetCode]) {
            final held = session.held(pin);
            _drop(pin);
            if (held != null) _pins[pin] = held;
          }
          session.close();
          _notify();
        }
      });
    } on CardPinNeeded {
      asking = true;
      rethrow;
    } on CardWrongPin {
      asking = true;
      rethrow;
    } finally {
      final connection = used;
      if (connection != null && !connection.isOpen && !asking) _wipePins();
    }
  }

  /// Whether [now] is the card [shown] was read from, as it was: the same
  /// application identifier, which holds the maker and the serial number,
  /// and the same key in each place. A terminated card shows neither.
  static bool _sameCard(CardSnapshot shown, CardSnapshot? now) =>
      now != null &&
      now.aid.hex == shown.aid.hex &&
      CardPlace.values.every((place) => now.fingerprintHex(place) == shown.fingerprintHex(place));

  /// Keeps [value], the [pin] just typed for the card shown, for the next
  /// run: on this connection, or on the next one if that card is there.
  void givePin(CardPin pin, Uint8List value) {
    final key = pin == CardPin.pinToSign ? CardPin.pin : pin;
    _drop(key);
    _pins[key] = Uint8List.fromList(value);
    _carry = true;
    _pinsFor = _snapshot?.aid.hex;
  }

  void _drop(CardPin pin) {
    final value = _pins.remove(pin);
    value?.fillRange(0, value.length, 0);
  }

  /// Forgets what was typed for [pin].
  void forgetPin(CardPin pin) => _drop(pin == CardPin.pinToSign ? CardPin.pin : pin);

  /// For tests: whether a PIN is kept.
  bool get holdsAnyPin => _pins.isNotEmpty;

  @override
  void dispose() {
    _disposed = true;
    _forget();
    keys.removeListener(_onKeysChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
