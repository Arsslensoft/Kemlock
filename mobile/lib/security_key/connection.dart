/// The connection every feature that uses a security key is built on:
/// find a key, open one of its applications by identifier, exchange
/// smartcard commands or FIDO2 messages with it, and end cleanly
/// (openspec: add-security-key-management, security-key-connection).
///
/// ```dart
/// // Gather what the person must type first, then:
/// final info = await runOnKey(keys, (connection) async {
///   final card = await connection.selectApplication(myAid);
///   return card.transmit(ApduCommand(ins: 0xca, le: 256));
/// }, nfcMessage: 'Hold your key to the phone');
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../platform/security_keys.dart';
import 'apdu.dart' hide selectApplication, selectApplicationAnswer;
import 'apdu.dart' as iso7816 show selectApplication, selectApplicationAnswer;
import 'cbor.dart';
import 'ccid.dart';
import 'ctap_hid.dart';

/// The time limits of an exchange, in one place.
abstract final class KeyLimits {
  /// How long a key has to answer one smartcard command.
  static const apdu = Duration(seconds: 5);

  /// How long a key may stay silent on a FIDO2 request.
  static const ctap = Duration(seconds: 10);

  /// How long a request may take in all while the key keeps saying it is
  /// working, or waiting for a touch.
  static const longest = Duration(seconds: 60);
}

/// The identifier of the FIDO application.
const fidoAid = [0xa0, 0x00, 0x00, 0x06, 0x47, 0x2f, 0x00, 0x01];

/// Why a key's FIDO2 side cannot be talked to.
enum FidoUnavailableReason {
  /// The key has no FIDO application on this link.
  noApplication,

  /// The key speaks only the older U2F.
  u2fOnly,
}

/// FIDO2 is not reachable on this key over this link.
class FidoUnavailable implements Exception {
  const FidoUnavailable(this.reason, this.kind);

  final FidoUnavailableReason reason;

  /// The link that was tried. Over [SecurityKeyLinkKind.smartcard] and
  /// [SecurityKeyLinkKind.usbCcid] most keys keep their FIDO application
  /// to NFC, so the key may still have one.
  final SecurityKeyLinkKind kind;

  @override
  String toString() => 'FidoUnavailable(${reason.name} over ${kind.name})';
}

/// A key's answer to a FIDO2 request: CTAP's status byte and the CBOR
/// value after it, if any.
class CtapAnswer {
  const CtapAnswer(this.status, [this.value]);

  final int status;
  final Object? value;

  /// The answer's members by number; empty when it has none.
  Map<int, Object?> get map => cborIntMap(value);
}

/// One application opened on a key, for smartcard commands.
class SmartCardSession {
  SmartCardSession._(this._connection, this._token, this.selectAnswer, [this.selectStatus = swOk]);

  final SecurityKeyConnection _connection;
  final Object _token;

  /// What the application answered when it was opened.
  final Uint8List selectAnswer;

  /// The status it was opened with: `9000`, or one the caller let count
  /// as opened.
  final int selectStatus;

  /// Sends [command] and returns the whole answer with its status word,
  /// whatever its length. A status other than `9000` is returned, not thrown.
  /// [remainingIns] is the instruction the application hands the rest of a
  /// long answer out under, when it is not ISO 7816's GET RESPONSE.
  Future<ApduResponse> transmit(ApduCommand command, {int remainingIns = insGetResponse}) =>
      _connection._transmit(_token, command, remainingIns);
}

/// A key's FIDO application, for CTAP2 requests.
class CtapSession {
  CtapSession._(this._connection, this._token, this.kind, this.selectVersion);

  final SecurityKeyConnection _connection;
  final Object _token;

  /// The link the messages go over.
  final SecurityKeyLinkKind kind;

  /// What the application said when it was selected over an APDU link:
  /// `FIDO_2_0`, or `U2F_V2` on a key that also speaks U2F. Null over HID.
  final String? selectVersion;

  /// Sends the request [command] with its [parameters] and returns the
  /// key's status and answer.
  Future<CtapAnswer> send(int command, [Map<int, Object?>? parameters]) => _connection._ctap(this, command, parameters);
}

final _random = Random.secure();

Uint8List _randomNonce() => Uint8List.fromList([for (var i = 0; i < 8; i++) _random.nextInt(256)]);

/// A key that was found, and the one conversation with it. One request is
/// sent at a time and one application is open at a time.
class SecurityKeyConnection {
  SecurityKeyConnection(this._keys, this.device, {this._now = DateTime.now, this._nonce = _randomNonce});

  final SecurityKeys _keys;

  /// The key and its links.
  final SecurityKeyDevice device;
  final DateTime Function() _now;
  final Uint8List Function() _nonce;

  /// Told true when the key says it waits for a touch, and false when it
  /// has answered.
  void Function(bool needed)? onTouchNeeded;

  Future<void> _queue = Future.value();
  final Set<String> _opened = {};
  CcidCard? _ccid;
  CtapHidChannel? _hid;
  Object? _token;
  bool _closed = false;
  bool _removed = false;
  bool _cancelling = false;
  bool _touch = false;

  /// Whether messages can still be exchanged.
  bool get isOpen => !_closed;

  /// Whether the key left while the connection was open.
  bool get wasRemoved => _removed;

  /// The link smartcard commands go over, if the key has one.
  SecurityKeyLink? get apduLink =>
      device.link(SecurityKeyLinkKind.nfc) ?? device.link(SecurityKeyLinkKind.usbCcid) ?? device.link(SecurityKeyLinkKind.smartcard);

  /// The link FIDO2 messages go over: HID when the key has it, else the
  /// smartcard link.
  SecurityKeyLink? get fidoLink => device.link(SecurityKeyLinkKind.usbHid) ?? apduLink;

  /// How the key is connected, as a person would say it.
  bool get isNfc => device.isNfc;

  /// Runs [task] once every earlier request has ended.
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final done = Completer<void>();
    final previous = _queue;
    _queue = done.future;
    return previous.then((_) => _guarded(task)).whenComplete(done.complete);
  }

  Future<T> _guarded<T>(Future<T> Function() task) async {
    if (_closed) throw _gone();
    try {
      return await task();
    } on SecurityKeyRemoved {
      _removed = true;
      await _shut();
      if (_cancelling) throw const SecurityKeyCancelled();
      rethrow;
    } on SecurityKeyTimeout {
      // A key that stopped answering is not asked anything more.
      await _shut();
      rethrow;
    } on SecurityKeyError {
      if (_cancelling) throw const SecurityKeyCancelled();
      rethrow;
    } finally {
      _setTouch(false);
      if (!_closed) _cancelling = false;
    }
  }

  SecurityKeyError _gone() => _cancelling ? const SecurityKeyCancelled() : const SecurityKeyRemoved();

  void _setTouch(bool needed) {
    if (_touch == needed) return;
    _touch = needed;
    onTouchNeeded?.call(needed);
  }

  Future<void> _open(SecurityKeyLink link) async {
    if (_opened.contains(link.id)) return;
    await _keys.open(link.id);
    _opened.add(link.id);
  }

  /// Carries one APDU over [link], within [timeout].
  Future<Uint8List> _exchange(SecurityKeyLink link, Uint8List apdu, Duration timeout) async {
    if (_closed) throw _gone();
    await _open(link);
    if (link.kind.carriesApdus) return _keys.transceive(link.id, apdu, timeout: timeout);
    var card = _ccid;
    if (card == null) {
      card = CcidCard(
        write: (packets) => _keys.write(link.id, packets),
        read: (timeout) => _keys.read(link.id, timeout),
        now: _now,
        maxMessage: link.frameSize,
      );
      await card.powerOn(KeyLimits.apdu);
      _ccid = card;
    }
    return card.transceive(apdu, silence: timeout, longest: KeyLimits.longest);
  }

  SecurityKeyLink _needApduLink() => apduLink ?? (throw const SecurityKeyNoApplication());

  /// Opens the application [aid] on the key. Throws
  /// [SecurityKeyNoApplication] when the key has none with that
  /// identifier, and [SecurityKeyNotDeclared] when iPhone was not told of
  /// it; the connection stays usable after either. The application opened
  /// before, if any, is closed by this. A status in [alsoSelected] counts
  /// as opened, and the session keeps it.
  Future<SmartCardSession> selectApplication(List<int> aid, {Set<int> alsoSelected = const {}}) => _enqueue(() async {
    final link = _needApduLink();
    _token = null;
    final answer = await iso7816.selectApplicationAnswer(
      (apdu) => _exchange(link, apdu, KeyLimits.apdu),
      aid,
      extendedLength: link.extendedLength,
      alsoSelected: alsoSelected,
    );
    final token = _token = Object();
    return SmartCardSession._(this, token, answer.data, answer.sw);
  });

  Future<Uint8List> _select(SecurityKeyLink link, List<int> aid) =>
      iso7816.selectApplication((apdu) => _exchange(link, apdu, KeyLimits.apdu), aid, extendedLength: link.extendedLength);

  Future<ApduResponse> _transmit(Object token, ApduCommand command, int remainingIns) => _enqueue(() {
    if (!identical(token, _token)) throw StateError('Another application was opened on this key since.');
    final link = _needApduLink();
    return transmitApdu(
      (apdu) => _exchange(link, apdu, KeyLimits.apdu),
      command,
      extendedLength: link.extendedLength,
      remainingIns: remainingIns,
    );
  });

  /// Opens the key's FIDO application for CTAP2 requests: over HID when
  /// the key has that interface, else over its smartcard link. Throws
  /// [FidoUnavailable] when the key has no FIDO application on that link
  /// or speaks only U2F over HID.
  Future<CtapSession> openFido() => _enqueue(() async {
    final link = fidoLink;
    if (link == null) throw const FidoUnavailable(FidoUnavailableReason.noApplication, SecurityKeyLinkKind.nfc);
    _token = null;
    if (link.kind == SecurityKeyLinkKind.usbHid) {
      await _open(link);
      final channel = CtapHidChannel(
        write: (reports) => _keys.write(link.id, reports),
        read: (timeout) => _keys.read(link.id, timeout),
        now: _now,
        nonce: _nonce,
        reportSize: link.frameSize > 7 ? link.frameSize : ctapHidReportSize,
      );
      final init = await _hidErrors(() => channel.init(KeyLimits.ctap));
      if (!init.cbor) throw const FidoUnavailable(FidoUnavailableReason.u2fOnly, SecurityKeyLinkKind.usbHid);
      _hid = channel;
      return CtapSession._(this, _token = Object(), link.kind, null);
    }
    final Uint8List answer;
    try {
      answer = await _select(link, fidoAid);
    } on SecurityKeyNoApplication {
      throw FidoUnavailable(FidoUnavailableReason.noApplication, link.kind);
    }
    return CtapSession._(this, _token = Object(), link.kind, ascii.decode(answer, allowInvalid: true));
  });

  Future<T> _hidErrors<T>(Future<T> Function() task) async {
    try {
      return await task();
    } on CtapHidError catch (error) {
      throw SecurityKeyFailed('The key refused the message (${error.kind.name}).');
    }
  }

  Future<CtapAnswer> _ctap(CtapSession session, int command, Map<int, Object?>? parameters) => _enqueue(() async {
    if (!identical(session._token, _token)) throw StateError('Another application was opened on this key since.');
    final message = Uint8List.fromList([command, if (parameters != null) ...cborEncode(parameters)]);
    final Uint8List answer;
    if (session.kind == SecurityKeyLinkKind.usbHid) {
      answer = await _hidErrors(
        () => _hid!.request(
          CtapHidCommand.cbor,
          message,
          silence: KeyLimits.ctap,
          longest: KeyLimits.longest,
          onKeepalive: (status) => _setTouch(status == CtapHidKeepalive.touchNeeded),
        ),
      );
    } else {
      answer = await _ctapOverApdu(session, message);
    }
    if (answer.isEmpty) throw const SecurityKeyFailed('The key sent an empty answer.');
    // CTAP2_ERR_KEEPALIVE_CANCEL: the key dropped the request because it was told to.
    if (_cancelling && answer[0] == 0x2d) throw const SecurityKeyCancelled();
    try {
      return CtapAnswer(answer[0], answer.length > 1 ? cborDecode(Uint8List.sublistView(answer, 1)) : null);
    } on CborError catch (error) {
      throw SecurityKeyFailed('The key sent an answer that cannot be read: ${error.message}');
    }
  });

  /// `NFCCTAP_MSG`, then `NFCCTAP_GETRESPONSE` for as long as the key
  /// answers `9100`, "still at it".
  Future<Uint8List> _ctapOverApdu(CtapSession session, Uint8List message) async {
    final link = _needApduLink();
    Future<Uint8List> send(Uint8List apdu) => _exchange(link, apdu, KeyLimits.ctap);
    final start = _now();
    // P1 0x80: this side can ask again while the key works.
    var response = await transmitApdu(
      send,
      ApduCommand(cla: 0x80, ins: 0x10, p1: 0x80, data: message, le: link.extendedLength ? apduExtendedLe : apduShortLe),
      extendedLength: link.extendedLength,
    );
    while (response.sw == 0x9100) {
      _setTouch(response.data.isNotEmpty && response.data[0] == 2);
      if (_now().difference(start) >= KeyLimits.longest) throw const SecurityKeyTimeout();
      response = await transmitApdu(send, ApduCommand(cla: 0x80, ins: 0x11, le: apduShortLe), extendedLength: link.extendedLength);
    }
    if (response.ok) return response.data;
    // A key that selects as U2F and does not know the CTAP2 instruction has no FIDO2.
    if (response.sw == 0x6d00 || response.sw == 0x6e00) throw FidoUnavailable(FidoUnavailableReason.u2fOnly, link.kind);
    throw SecurityKeyFailed('The key refused the message (${response.sw.toRadixString(16).padLeft(4, '0')}).');
  }

  /// Ends the request in flight, as when the person cancels: the key is
  /// told to stop over HID, and the link is closed elsewhere. The request
  /// then fails with [SecurityKeyCancelled].
  Future<void> cancel() async {
    if (_closed) return;
    _cancelling = true;
    final hid = _hid;
    if (hid != null && hid.isWaiting) {
      try {
        await hid.cancel();
      } on SecurityKeyError {
        // The key is gone: there is nothing left to cancel.
      }
      return;
    }
    await _shut();
  }

  /// Ends the conversation and lets the links go.
  Future<void> close() => _shut();

  /// The key left: nothing more is sent to it.
  void markRemoved() {
    _removed = true;
    unawaited(_shut());
  }

  Future<void> _shut() async {
    if (_closed) return;
    _closed = true;
    _token = null;
    for (final link in _opened.toList()) {
      await _keys.close(link);
    }
    _opened.clear();
  }
}

/// Finds keys for as long as something waits for one, keeps the one that
/// is connected, and runs actions on it. A screen that shows a key keeps
/// a hub while it is open; [runOnKey] makes one for a single action.
class SecurityKeyHub {
  SecurityKeyHub(this._keys, {this._now = DateTime.now, this.hold, this._nonce = _randomNonce});

  final SecurityKeys _keys;
  final DateTime Function() _now;
  final Uint8List Function() _nonce;

  /// Takes a hold on "lock when hidden" and returns what lets it go. The
  /// hub takes one while iPhone's NFC sheet or Android's USB question
  /// covers the app.
  final void Function() Function()? hold;

  /// Called whenever something a screen shows has changed.
  void Function()? onChanged;

  /// What the phone can reach a key with; known once [start] has run.
  SecurityKeyCapabilities capabilities = SecurityKeyCapabilities.none;

  final Map<String, SecurityKeyDevice> _devices = {};
  StreamSubscription<SecurityKeyEvent>? _subscription;
  SecurityKeyConnection? _live;
  Completer<SecurityKeyConnection>? _waiter;
  bool _wantNfc = false;
  bool _connecting = false;
  bool _sessionUp = false;
  bool _started = false;
  void Function()? _sessionHold;
  SecurityKeyDevice? _denied;
  List<SecurityKeyDevice> _choices = const [];

  /// The key that is connected now, if one is.
  SecurityKeyConnection? get live => _live;

  /// The plugged-in key the person did not allow Kemlock to use.
  SecurityKeyDevice? get denied => _denied;

  /// Several keys are present: the person picks one with [pick].
  List<SecurityKeyDevice> get choices => _choices;

  /// Whether an action waits for a key to be presented.
  bool get isWaiting => _waiter != null;

  /// Whether iPhone's NFC sheet is up.
  bool get nfcSheetUp => _sessionUp;

  /// Whether the system's USB question is up.
  bool get askingPermission => _connecting;

  /// Starts looking for keys. A key already plugged in, or the first to
  /// arrive, is connected; with several the person is asked ([choices]).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    capabilities = await _keys.capabilities();
    if (!_started) return;
    _subscription = _keys.watch().listen(_onEvent);
    final List<SecurityKeyDevice> present;
    try {
      present = await _keys.present();
    } on SecurityKeyError {
      _changed();
      return;
    }
    if (!_started) return;
    for (final device in present) {
      _devices.putIfAbsent(device.id, () => device);
    }
    _changed();
    await _consider();
  }

  /// Stops looking, closes the session with the key and ends any wait.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    // Not awaited: the links are let go at once, whatever the stream takes to wind down.
    unawaited(_subscription?.cancel());
    _subscription = null;
    _failWaiter(const SecurityKeyCancelled());
    final live = _live;
    _live = null;
    await live?.close();
    if (_sessionUp) {
      _sessionUp = false;
      await _keys.endNfc();
    }
    _releaseSession();
    _devices.clear();
    _choices = const [];
    _denied = null;
  }

  void _changed() => onChanged?.call();

  void _releaseSession() {
    _sessionHold?.call();
    _sessionHold = null;
  }

  void _failWaiter(Object error) {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.completeError(error);
  }

  void _onEvent(SecurityKeyEvent event) {
    switch (event) {
      case SecurityKeyArrived(:final device):
        _devices[device.id] = device;
        unawaited(_consider(arrived: device));
      case SecurityKeyLeft(:final deviceId):
        _devices.remove(deviceId);
        if (_denied?.id == deviceId) _denied = null;
        _choices = [
          for (final device in _choices)
            if (device.id != deviceId) device,
        ];
        if (_choices.length < 2) _choices = const [];
        final live = _live;
        if (live != null && live.device.id == deviceId) {
          live.markRemoved();
          _live = null;
        }
        _changed();
      case SecurityKeySessionEnded(:final error):
        _sessionUp = false;
        _wantNfc = false;
        _releaseSession();
        final live = _live;
        if (live != null && live.isNfc) {
          live.markRemoved();
          _live = null;
        }
        // Ended by the person or by the system while an action still waited for a key.
        _failWaiter(error ?? const SecurityKeyCancelled());
        _changed();
    }
  }

  /// Connects the key there is, or asks which when there are several.
  Future<void> _consider({SecurityKeyDevice? arrived}) async {
    if (_connecting) return;
    // A key read over NFC because an action asked for one takes the place of a plugged-in key.
    if (arrived != null && arrived.isNfc && _wantNfc) {
      final plugged = _live;
      _live = null;
      await plugged?.close();
      return _connect(arrived);
    }
    if (_live != null) return;
    final candidates = [
      for (final device in _devices.values)
        if (device.id != _denied?.id) device,
    ];
    if (candidates.isEmpty) return;
    if (candidates.length == 1) return _connect(candidates.single);
    _choices = candidates;
    _changed();
  }

  /// Uses [device], one of [choices].
  Future<void> pick(SecurityKeyDevice device) {
    _choices = const [];
    _changed();
    return _connect(device);
  }

  /// Asks the system's USB question again for the key that was [denied].
  Future<void> askAgain() async {
    final device = _denied;
    if (device == null) return;
    _denied = null;
    _changed();
    await _connect(device);
  }

  Future<void> _connect(SecurityKeyDevice found) async {
    if (_connecting) return;
    var device = found;
    _connecting = true;
    try {
      if (device.needsPermission) {
        final release = hold?.call();
        _changed();
        try {
          device = device.withLinks(await _keys.requestPermission(device.id));
        } on SecurityKeyDenied {
          _denied = found;
          return;
        } on SecurityKeyError {
          // Unplugged while the question was up.
          _devices.remove(found.id);
          return;
        } finally {
          release?.call();
        }
      }
      if (!_started || !_devices.containsKey(found.id)) return;
      if (device.links.isEmpty) {
        // Not a security key after all: it is not offered again.
        _devices.remove(found.id);
        return;
      }
      _devices[device.id] = device;
      final connection = SecurityKeyConnection(_keys, device, now: _now, nonce: _nonce);
      _live = connection;
      final waiter = _waiter;
      _waiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete(connection);
    } finally {
      _connecting = false;
      _changed();
    }
    if (_live == null) await _consider();
  }

  /// Runs [action] on the connected key, or waits for one to be presented
  /// first: on iPhone by starting an NFC read with [nfcMessage] on the
  /// system's sheet, on Android until a key is held to the phone or
  /// plugged in. With [viaNfc] a plugged-in key is not used and a key is
  /// asked for over NFC, for what only NFC carries. Whatever the person
  /// must type is asked before this is called, so a key is held to the
  /// phone only for the exchange itself.
  ///
  /// A key read under iPhone's sheet is let go when [action] ends: with a
  /// tick, or with [nfcFailure] and a cross when it threw. A plugged-in
  /// key, and a key in the field of an Android phone, stay connected.
  ///
  /// Throws [SecurityKeyCancelled] when the person cancels the wait,
  /// [SecurityKeyUnavailable] on a phone that can reach no key, and
  /// whatever [action] throws.
  Future<T> runOnKey<T>(
    Future<T> Function(SecurityKeyConnection connection) action, {
    String nfcMessage = '',
    String? nfcFailure,
    bool viaNfc = false,
  }) async {
    if (!_started) await start();
    var connection = _live;
    if (connection == null || !connection.isOpen || (viaNfc && !connection.isNfc)) {
      connection = await _waitForKey(nfcMessage, viaNfc: viaNfc);
    }
    final underSheet = capabilities.readsOnRequest && connection.isNfc;
    var failed = true;
    try {
      final result = await action(connection);
      failed = false;
      return result;
    } finally {
      if (underSheet) {
        if (_live == connection) _live = null;
        await connection.close();
        if (_sessionUp) {
          _sessionUp = false;
          _wantNfc = false;
          await _keys.endNfc(error: failed ? nfcFailure : null);
        }
        _releaseSession();
        _changed();
      } else if (!connection.isOpen && _live == connection) {
        _live = null;
        _changed();
      }
    }
  }

  Future<SecurityKeyConnection> _waitForKey(String nfcMessage, {required bool viaNfc}) async {
    if (!capabilities.any) throw const SecurityKeyUnavailable();
    if (viaNfc && !capabilities.nfc) throw const SecurityKeyUnavailable();
    if (capabilities.nfc && !capabilities.nfcOn && (viaNfc || !capabilities.plugsIn)) throw const SecurityKeyNfcOff();
    final waiter = _waiter = Completer<SecurityKeyConnection>();
    _wantNfc = viaNfc;
    _changed();
    if (capabilities.readsOnRequest && capabilities.nfc) {
      _wantNfc = true;
      _sessionHold ??= hold?.call();
      _sessionUp = true;
      try {
        await _keys.beginNfc(nfcMessage);
      } on SecurityKeyError {
        _sessionUp = false;
        _wantNfc = false;
        _releaseSession();
        _waiter = null;
        _changed();
        rethrow;
      }
      _changed();
    }
    try {
      return await waiter.future;
    } finally {
      if (identical(_waiter, waiter)) _waiter = null;
      _changed();
    }
  }

  /// The person cancels: the wait for a key ends, or the request in
  /// flight is stopped. Whatever was running fails with
  /// [SecurityKeyCancelled], which is not an error to show.
  Future<void> cancel() async {
    if (_waiter != null) {
      _failWaiter(const SecurityKeyCancelled());
      _wantNfc = false;
      if (_sessionUp) {
        _sessionUp = false;
        await _keys.endNfc();
        _releaseSession();
      }
      _changed();
      return;
    }
    await _live?.cancel();
  }
}

/// Waits for a key, runs [action] on it and lets the key go: the whole of
/// a feature's talk with a key when it keeps no screen open on one. See
/// [SecurityKeyHub.runOnKey] for [nfcMessage], [nfcFailure] and [viaNfc].
/// With several keys present [choose] says which to use; without it the
/// wait goes on until one is alone.
Future<T> runOnKey<T>(
  SecurityKeys keys,
  Future<T> Function(SecurityKeyConnection connection) action, {
  String nfcMessage = '',
  String? nfcFailure,
  bool viaNfc = false,
  Future<SecurityKeyDevice?> Function(List<SecurityKeyDevice> present)? choose,
  void Function() Function()? hold,
  void Function(SecurityKeyHub hub)? onHub,
  DateTime Function() now = DateTime.now,
}) async {
  final hub = SecurityKeyHub(keys, now: now, hold: hold);
  var choosing = false;
  hub.onChanged = () {
    if (choose == null || choosing || hub.choices.isEmpty) return;
    choosing = true;
    unawaited(
      choose(hub.choices).then((device) {
        choosing = false;
        return device == null ? hub.cancel() : hub.pick(device);
      }),
    );
  };
  onHub?.call(hub);
  try {
    return await hub.runOnKey(action, nfcMessage: nfcMessage, nfcFailure: nfcFailure, viaNfc: viaNfc);
  } finally {
    await hub.stop();
  }
}
