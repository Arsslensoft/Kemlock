import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/credential_management.dart';
import '../../security_key/fido/ctap.dart';
import '../../security_key/fido/get_info.dart';
import '../../security_key/fido/pin_protocol.dart';
import '../../vault/vault_controller.dart';
import '../settings/auto_lock.dart';

/// Whether the vault is open. When it locks, the Security key sheet closes
/// its session with the key and forgets the PIN. Tests of the sheet alone
/// put a value in its place.
final keySheetVaultOpenProvider = Provider<bool>((ref) => ref.watch(vaultControllerProvider.select((state) => state.isUnlocked)));

/// Why a key that was read has no FIDO2 features to show.
enum KeyFidoProblem {
  /// None: the key's FIDO2 side was read.
  none,

  /// The key has no FIDO application.
  noFido,

  /// The key does only the older two-step sign-in (U2F).
  u2fOnly,

  /// The key is plugged into a phone that gives apps FIDO2 over NFC only.
  needsNfc,
}

/// What was read from a key the last time it was connected. Nothing here
/// is kept past the sheet.
class KeyDetails {
  const KeyDetails({
    required this.deviceId,
    this.productName,
    required this.kind,
    this.info,
    this.problem = KeyFidoProblem.none,
    this.retries,
  });

  final String deviceId;

  /// The name the key gives over USB. Over NFC a key gives none.
  final String? productName;

  /// The link it was read over.
  final SecurityKeyLinkKind kind;

  /// What the key says of its FIDO2 side; null when it has none to read.
  final AuthenticatorInfo? info;
  final KeyFidoProblem problem;

  /// The PIN tries the key said were left when it was read.
  final int? retries;

  bool get isNfc => kind == SecurityKeyLinkKind.nfc;

  /// Whether the PIN can be managed: the key has PINs and offers a
  /// protocol the app knows.
  bool get pinManageable => info != null && info!.pin != KeyPinState.unsupported && PinProtocol.choose(info!.pinUvAuthProtocols) != null;

  KeyDetails withRetries(int? retries) =>
      KeyDetails(deviceId: deviceId, productName: productName, kind: kind, info: info, problem: problem, retries: retries);
}

/// A key connected for one action, with its FIDO application open and
/// what it says of itself just read.
class KeySession {
  const KeySession(this.connection, this.fido, this.info);

  final SecurityKeyConnection connection;
  final CtapSession fido;
  final AuthenticatorInfo info;

  ClientPin get clientPin => ClientPin(fido, info);
}

/// The state behind the Security key sheet and the sheets it opens: the
/// search for a key, what was read from it, and the PIN while the sheet is
/// open. It lives as long as the sheet and stores nothing.
class SecurityKeyController extends ChangeNotifier {
  SecurityKeyController({required SecurityKeys keys, AutoLockHolds? holds, DateTime Function() now = DateTime.now}) {
    hub = SecurityKeyHub(keys, now: now, hold: holds?.hold)..onChanged = _onHubChanged;
  }

  late final SecurityKeyHub hub;

  /// The texts of iPhone's NFC sheet, which the sheet sets in its language.
  String nfcMessage = '';
  String nfcFailure = '';

  KeyDetails? _key;
  bool _live = false;
  int _running = 0;
  bool _touchNeeded = false;
  bool _removedNotice = false;
  bool _started = false;
  bool _disposed = false;
  Object? _readError;
  Uint8List? _pin;

  /// The connection [_pin] was used on; null while it waits for the next.
  SecurityKeyConnection? _pinOn;
  bool _pinBlocked = false;
  bool _pinLocked = false;
  PasskeyStorage? _storage;
  SecurityKeyConnection? _seen;

  SecurityKeyCapabilities get capabilities => hub.capabilities;

  /// Whether the phone's abilities are known yet.
  bool get ready => _started;

  /// What the last key read said of itself. It stays after a key read over
  /// NFC is taken away.
  KeyDetails? get key => _key;

  /// Whether the link to [key] is live now.
  bool get connected => _live && _key != null;

  /// Whether an exchange with the key is going on, or waited for.
  bool get busy => _running > 0;

  /// Whether an action waits for the key to be presented.
  bool get waitingForKey => hub.isWaiting;

  /// Whether the key says it waits for a touch.
  bool get touchNeeded => _touchNeeded;

  /// A plugged-in key was pulled out since the sheet last showed one.
  bool get removedNotice => _removedNotice;

  /// Why the last read of a key failed, when it did.
  Object? get readError => _readError;

  /// The PIN typed for [key], kept while the sheet is open: for a plugged-in
  /// key while it stays plugged in, and over NFC for the next connection
  /// and as long as that one lasts. Two keys of one model look the same
  /// over NFC, so a key held to the phone again is asked for its PIN again:
  /// on an iPhone, where each read is a connection of its own, at each read.
  Uint8List? get pin => _pin;

  /// The key has no PIN tries left.
  bool get pinBlocked => _pinBlocked || _key?.retries == 0;

  /// The key takes no more PINs until it is presented again.
  bool get pinLocked => _pinLocked;

  /// How full the key is, once the PIN was given.
  PasskeyStorage? get storage => _storage;

  /// Starts looking for a key.
  Future<void> start() async {
    await hub.start();
    if (_disposed) return;
    _started = true;
    _onHubChanged();
  }

  /// The vault locked: the session with the key is closed and everything
  /// read or typed is forgotten.
  Future<void> lock() async {
    _forgetKey();
    _removedNotice = false;
    _readError = null;
    await hub.stop();
    _started = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _forgetKey();
    unawaited(hub.stop());
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _forgetPin() {
    _pin?.fillRange(0, _pin!.length, 0);
    _pin = null;
    _pinOn = null;
  }

  /// Over NFC the PIN lasts no longer than the connection it was used on.
  void _forgetPinOfEndedConnection() {
    final on = _pinOn;
    if (_pin != null && on != null && on.isNfc && (!on.isOpen || !identical(hub.live, on))) _forgetPin();
  }

  void _forgetKey() {
    _forgetPin();
    _key = null;
    _live = false;
    _storage = null;
    _pinBlocked = false;
    _pinLocked = false;
    _seen = null;
  }

  /// Keeps [pin] for the next actions on this key: typed before an action,
  /// for the connection it runs on; set during one, as a new PIN, for that
  /// action's connection.
  void rememberPin(Uint8List pin) {
    if (identical(pin, _pin)) return;
    _forgetPin();
    _pin = Uint8List.fromList(pin);
    _pinOn = _running > 0 ? _seen : null;
  }

  /// Forgets the PIN, as after the key refused it.
  void forgetPin() {
    _forgetPin();
    _notify();
  }

  /// Notes what a refusal says of the key's PIN.
  void notePinError(PinError error) {
    switch (error) {
      case PinWrong(:final retries):
        _forgetPin();
        if (_key != null) _key = _key!.withRetries(retries);
      case PinLockedUntilReconnected():
        _forgetPin();
        _pinLocked = true;
      case PinBlocked():
        _forgetPin();
        _pinBlocked = true;
        if (_key != null) _key = _key!.withRetries(0);
      default:
        break;
    }
    _notify();
  }

  /// Sets how full the key is, read with the PIN.
  set storage(PasskeyStorage? storage) {
    _storage = storage;
    _notify();
  }

  void _onHubChanged() {
    if (_disposed) return;
    final connection = hub.live;
    if (connection != null && !identical(connection, _seen)) {
      _seen = connection;
      connection.onTouchNeeded = _onTouch;
      // A key that arrives while nothing asked for one is read at once.
      if (_running == 0) unawaited(read().then((_) {}, onError: (Object _) {}));
    }
    _forgetPinOfEndedConnection();
    if (connection == null) {
      _seen = null;
      if (_live) {
        _live = false;
        _pinLocked = false;
        // A plugged-in key that is pulled out takes its details with it; one read over NFC keeps them.
        if (_key != null && !_key!.isNfc) {
          _forgetKey();
          _removedNotice = true;
        }
      }
    }
    notifyListeners();
  }

  void _onTouch(bool needed) {
    _touchNeeded = needed;
    _notify();
  }

  /// Reads done in the same connection as [read], after the FIDO2 side,
  /// by the sections that show another of the key's applications. They
  /// run whether or not the key has FIDO2 on this link, so the key is
  /// held to an iPhone only once.
  final List<Future<void> Function(SecurityKeyConnection connection)> readers = [];

  /// Reads the key: what it is, what it supports and, when it has a PIN,
  /// the tries left, then what [readers] read. On iPhone this starts an
  /// NFC read.
  Future<void> read({bool viaNfc = false}) => _runOn((connection) async {
    try {
      final session = await _open(connection);
      if (session.info.pin == KeyPinState.set && PinProtocol.choose(session.info.pinUvAuthProtocols) != null) {
        try {
          final retries = await session.clientPin.retries();
          _key = _key?.withRetries(retries);
        } on CtapError {
          // A key that will not say: the count is learnt at the first wrong PIN.
        }
      }
    } on FidoUnavailable {
      await _readOthers(connection);
      rethrow;
    }
    await _readOthers(connection);
  }, viaNfc: viaNfc);

  Future<void> _readOthers(SecurityKeyConnection connection) async {
    for (final reader in [...readers]) {
      await reader(connection);
    }
    _notify();
  }

  /// Runs [action] on the key's connection without opening its FIDO
  /// application, for the sections that use another of its applications:
  /// on the key connected, or on the one the person presents next.
  Future<T> runOnConnection<T>(Future<T> Function(SecurityKeyConnection connection) action, {bool viaNfc = false}) =>
      _runOn(action, viaNfc: viaNfc);

  /// Runs [action] on the key: on the one connected, or on the one the
  /// person presents next. The key's FIDO application is opened and read
  /// first, so [action] meets the key as it is now; if it is another key
  /// than the one the PIN was typed for, the PIN is forgotten before
  /// [action] runs.
  ///
  /// Throws [FidoUnavailable] for a key with no FIDO2 on this link, and
  /// whatever the exchange throws; [SecurityKeyCancelled] is not an error
  /// to show.
  Future<T> run<T>(Future<T> Function(KeySession session) action, {bool? viaNfc}) =>
      _runOn((connection) async => action(await _open(connection)), viaNfc: viaNfc ?? (_key?.problem == KeyFidoProblem.needsNfc));

  Future<T> _runOn<T>(Future<T> Function(SecurityKeyConnection connection) action, {required bool viaNfc}) async {
    _running++;
    _readError = null;
    _removedNotice = false;
    _notify();
    try {
      return await hub.runOnKey(
        (connection) async {
          _seen = connection;
          connection.onTouchNeeded = _onTouch;
          return action(connection);
        },
        nfcMessage: nfcMessage,
        nfcFailure: nfcFailure,
        viaNfc: viaNfc,
      );
    } on SecurityKeyCancelled {
      rethrow;
    } on FidoUnavailable {
      rethrow;
    } on PinError {
      rethrow;
    } catch (error) {
      if (_key == null) _readError = error;
      rethrow;
    } finally {
      _running--;
      _touchNeeded = false;
      _live = hub.live != null && identical(hub.live, _seen);
      if (hub.live == null) _seen = null;
      // As each read under iPhone's NFC sheet ends
      _forgetPinOfEndedConnection();
      _notify();
    }
  }

  Future<KeySession> _open(SecurityKeyConnection connection) async {
    final link = connection.fidoLink;
    final kind = link?.kind ?? SecurityKeyLinkKind.nfc;
    final CtapSession fido;
    final AuthenticatorInfo info;
    try {
      fido = await connection.openFido();
      info = await getInfo(fido);
    } on FidoUnavailable catch (unavailable) {
      final overSmartcard = unavailable.kind == SecurityKeyLinkKind.smartcard;
      _adopt(
        KeyDetails(
          deviceId: connection.device.id,
          productName: connection.device.productName,
          kind: kind,
          problem: switch (unavailable.reason) {
            FidoUnavailableReason.u2fOnly => KeyFidoProblem.u2fOnly,
            // iPhone gives apps FIDO2 over NFC only: the key may well have it.
            FidoUnavailableReason.noApplication => overSmartcard && capabilities.nfc ? KeyFidoProblem.needsNfc : KeyFidoProblem.noFido,
          },
        ),
      );
      rethrow;
    }
    if (!info.fido2) {
      _adopt(
        KeyDetails(deviceId: connection.device.id, productName: connection.device.productName, kind: kind, problem: KeyFidoProblem.u2fOnly),
      );
      throw FidoUnavailable(FidoUnavailableReason.u2fOnly, kind);
    }
    _adopt(
      KeyDetails(
        deviceId: connection.device.id,
        productName: connection.device.productName,
        kind: kind,
        info: info,
        retries: _key?.retries,
      ),
    );
    _pinFor(connection);
    return KeySession(connection, fido, info);
  }

  /// Ties the PIN to [connection], the key's FIDO side just read on it: a
  /// PIN typed for the next connection becomes this one's. One used on
  /// another connection is forgotten when either is over NFC, where a key
  /// of the same model held to the phone in turn may be another key, which
  /// a PIN sent to it would cost a try, or a fake one made to collect it.
  void _pinFor(SecurityKeyConnection connection) {
    final on = _pinOn;
    if (_pin == null || identical(on, connection)) return;
    if (on != null && (on.isNfc || connection.isNfc)) {
      _forgetPin();
    } else {
      _pinOn = connection;
    }
  }

  /// Takes [details] as the key now shown. A different key than before
  /// loses the PIN and everything read with it; the same model over NFC
  /// keeps what was read, and the PIN only as [_pinFor] says.
  void _adopt(KeyDetails details) {
    final before = _key;
    final sameModel = before?.info != null && details.info != null && before!.info!.sameModelAs(details.info!);
    // Two keys of one model plugged in turn are told apart by the plug; over NFC a key has only its model to go by.
    final samePlug = before != null && (before.isNfc || details.isNfc || before.deviceId == details.deviceId);
    if (!(sameModel && samePlug)) {
      _forgetPin();
      _storage = null;
      _pinBlocked = false;
      _key = details.withRetries(null);
    } else {
      _key = details;
    }
    _pinLocked = false;
    _live = true;
    _removedNotice = false;
    _notify();
  }

  /// Reads again what the key of [session] says of itself, after an action
  /// that changed it, within the same connection.
  Future<void> refresh(KeySession session) async {
    final info = await getInfo(session.fido);
    final before = _key;
    if (before == null) return;
    int? retries;
    if (info.pin == KeyPinState.set && PinProtocol.choose(info.pinUvAuthProtocols) != null) {
      try {
        retries = await ClientPin(session.fido, info).retries();
      } on CtapError {
        retries = null;
      }
    }
    _key = KeyDetails(deviceId: before.deviceId, productName: before.productName, kind: before.kind, info: info, retries: retries);
    _pinBlocked = false;
    _pinLocked = false;
    _notify();
  }

  /// Forgets what was read with the PIN, as after a reset.
  void forgetPinState() {
    _forgetPin();
    _storage = null;
    _pinBlocked = false;
    _pinLocked = false;
    _notify();
  }

  /// The person cancels the wait for a key, or the request in flight.
  Future<void> cancel() => hub.cancel();
}
