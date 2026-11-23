import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why the phone could not reach a security key or carry a message to it
/// (openspec: add-security-key-management, security-key-connection).
sealed class SecurityKeyError implements Exception {
  const SecurityKeyError();

  /// The code the platform channel sends for it.
  String get code;
}

/// The person closed the system's NFC sheet, or cancelled the wait.
class SecurityKeyCancelled extends SecurityKeyError {
  const SecurityKeyCancelled();

  @override
  String get code => 'cancelled';

  @override
  String toString() => 'The security key request was cancelled.';
}

/// The phone has no way to reach a key over the link asked for, or the
/// build has no native side.
class SecurityKeyUnavailable extends SecurityKeyError {
  const SecurityKeyUnavailable();

  @override
  String get code => 'unavailable';

  @override
  String toString() => 'This phone cannot reach a security key.';
}

/// The phone has NFC and it is turned off.
class SecurityKeyNfcOff extends SecurityKeyError {
  const SecurityKeyNfcOff();

  @override
  String get code => 'nfcOff';

  @override
  String toString() => 'NFC is turned off.';
}

/// The person refused the system's question about a USB key.
class SecurityKeyDenied extends SecurityKeyError {
  const SecurityKeyDenied();

  @override
  String get code => 'denied';

  @override
  String toString() => 'Kemlock was not allowed to use the USB key.';
}

/// The key left the NFC field or was unplugged.
class SecurityKeyRemoved extends SecurityKeyError {
  const SecurityKeyRemoved();

  @override
  String get code => 'removed';

  @override
  String toString() => 'The security key was removed.';
}

/// The key gave no answer in time, or iPhone's reader session ran out.
class SecurityKeyTimeout extends SecurityKeyError {
  const SecurityKeyTimeout();

  @override
  String get code => 'timeout';

  @override
  String toString() => 'The security key did not answer in time.';
}

/// The key has no application with the identifier asked for.
class SecurityKeyNoApplication extends SecurityKeyError {
  const SecurityKeyNoApplication();

  @override
  String get code => 'noApplication';

  @override
  String toString() => 'The security key has no such application.';
}

/// The application's identifier is not in the list iPhone lets the app
/// select over NFC (`Info.plist`).
class SecurityKeyNotDeclared extends SecurityKeyError {
  const SecurityKeyNotDeclared();

  @override
  String get code => 'notDeclared';

  @override
  String toString() => 'This application cannot be reached over NFC on this phone.';
}

/// Anything else, with the system's [message] when it gave one.
class SecurityKeyFailed extends SecurityKeyError {
  const SecurityKeyFailed([this.message]);

  final String? message;

  @override
  String get code => 'failed';

  @override
  String toString() => message ?? 'Talking to the security key failed.';
}

/// The error a platform channel [code] stands for, with its [message].
SecurityKeyError securityKeyError(String code, [String? message]) => switch (code) {
  'cancelled' => const SecurityKeyCancelled(),
  'unavailable' => const SecurityKeyUnavailable(),
  'nfcOff' => const SecurityKeyNfcOff(),
  'denied' => const SecurityKeyDenied(),
  'removed' => const SecurityKeyRemoved(),
  'timeout' => const SecurityKeyTimeout(),
  'noApplication' => const SecurityKeyNoApplication(),
  'notDeclared' => const SecurityKeyNotDeclared(),
  _ => SecurityKeyFailed(message),
};

/// How the phone talks to a key.
enum SecurityKeyLinkKind {
  /// NFC: ISO-DEP on Android, an ISO 7816 tag on iPhone. One APDU out, one back.
  nfc,

  /// Android, USB: the FIDO HID interface, in raw reports.
  usbHid,

  /// Android, USB: the smartcard (CCID) interface, in raw bulk packets.
  usbCcid,

  /// iPhone, USB-C: the system's smartcard slot. One APDU out, one back.
  smartcard;

  /// Whether the link carries whole APDUs ([SecurityKeys.transceive]) and
  /// not raw frames ([SecurityKeys.write] and [SecurityKeys.read]).
  bool get carriesApdus => this == nfc || this == smartcard;

  static SecurityKeyLinkKind? fromName(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// One way to talk to a key that was found: its [id] for the calls of
/// [SecurityKeys], and what the phone knows of it.
class SecurityKeyLink {
  const SecurityKeyLink({required this.id, required this.kind, this.extendedLength = false, this.frameSize = 0});

  final String id;
  final SecurityKeyLinkKind kind;

  /// Whether the link takes extended-length APDUs. When it does not, long
  /// commands are chained.
  final bool extendedLength;

  /// Over [SecurityKeyLinkKind.usbHid], the size of a report (64 on every
  /// key seen); over [SecurityKeyLinkKind.usbCcid], the longest CCID message
  /// the key takes. 0 when the link has no such size.
  final int frameSize;

  static SecurityKeyLink? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final kind = SecurityKeyLinkKind.fromName(map['kind']);
    if (id is! String || kind == null) return null;
    final frameSize = map['frameSize'];
    return SecurityKeyLink(id: id, kind: kind, extendedLength: map['extendedLength'] == true, frameSize: frameSize is int ? frameSize : 0);
  }

  @override
  String toString() => 'SecurityKeyLink($id, ${kind.name})';
}

/// A key the phone found: held to it, or plugged in.
class SecurityKeyDevice {
  const SecurityKeyDevice({required this.id, this.productName, this.needsPermission = false, this.links = const []});

  /// Names the device in [SecurityKeys.requestPermission] and in
  /// [SecurityKeyLeft]. It means nothing once the key has left.
  final String id;

  /// The product name the device gives over USB. A key over NFC gives none.
  final String? productName;

  /// On Android a USB device is talked to only after the system's
  /// question. Until then its [links] are not known.
  final bool needsPermission;

  /// The ways to talk to it. A USB key may have two, its FIDO HID interface
  /// and its smartcard interface.
  final List<SecurityKeyLink> links;

  /// The link of [kind], if the key has one.
  SecurityKeyLink? link(SecurityKeyLinkKind kind) {
    for (final link in links) {
      if (link.kind == kind) return link;
    }
    return null;
  }

  /// Whether it is held to the phone, not plugged in.
  bool get isNfc => link(SecurityKeyLinkKind.nfc) != null;

  SecurityKeyDevice withLinks(List<SecurityKeyLink> links) =>
      SecurityKeyDevice(id: id, productName: productName, links: List.unmodifiable(links));

  static SecurityKeyDevice? fromMap(Map<Object?, Object?> map) {
    final id = map['device'];
    if (id is! String) return null;
    final product = map['product'];
    return SecurityKeyDevice(
      id: id,
      productName: product is String && product.trim().isNotEmpty ? product.trim() : null,
      needsPermission: map['needsPermission'] == true,
      links: _links(map['links']),
    );
  }

  @override
  String toString() => 'SecurityKeyDevice($id, $links)';
}

List<SecurityKeyLink> _links(Object? value) => List.unmodifiable([
  if (value is List)
    for (final link in value)
      if (link is Map) ?SecurityKeyLink.fromMap(link),
]);

/// What the watch stream of [SecurityKeys] tells.
sealed class SecurityKeyEvent {
  const SecurityKeyEvent();

  /// The event a map from the event channel stands for, or null for one
  /// this build does not know.
  static SecurityKeyEvent? fromMap(Object? event) {
    if (event is! Map) return null;
    switch (event['event']) {
      case 'arrived':
        final device = SecurityKeyDevice.fromMap(event);
        return device == null ? null : SecurityKeyArrived(device);
      case 'left':
        final id = event['device'];
        return id is String ? SecurityKeyLeft(id) : null;
      case 'sessionEnded':
        final code = event['code'];
        final message = event['message'];
        return SecurityKeySessionEnded(code is String ? securityKeyError(code, message is String ? message : null) : null);
    }
    return null;
  }
}

/// A key was held to the phone or plugged in.
class SecurityKeyArrived extends SecurityKeyEvent {
  const SecurityKeyArrived(this.device);

  final SecurityKeyDevice device;
}

/// The key named [deviceId] left the field or was unplugged.
class SecurityKeyLeft extends SecurityKeyEvent {
  const SecurityKeyLeft(this.deviceId);

  final String deviceId;
}

/// iPhone's NFC reader session is over: closed by the person
/// ([SecurityKeyCancelled]), run out ([SecurityKeyTimeout]), failed, or
/// ended by the app itself (no [error]).
class SecurityKeySessionEnded extends SecurityKeyEvent {
  const SecurityKeySessionEnded([this.error]);

  final SecurityKeyError? error;
}

/// What the phone can reach a key with.
class SecurityKeyCapabilities {
  const SecurityKeyCapabilities({
    this.nfc = false,
    this.nfcOn = false,
    this.usb = false,
    this.smartcards = false,
    this.readsOnRequest = false,
  });

  /// Nothing: a phone with neither NFC nor USB hosting, or a build without
  /// the native side.
  static const none = SecurityKeyCapabilities();

  /// The phone has an NFC reader.
  final bool nfc;

  /// NFC is turned on. Always true on an iPhone that has it.
  final bool nfcOn;

  /// The phone hosts USB devices (Android).
  final bool usb;

  /// The system offers plugged-in smartcards to apps (iPhone and iPad with
  /// USB-C, iOS 16 and later).
  final bool smartcards;

  /// An NFC read happens only when the app starts one, under the system's
  /// sheet ([SecurityKeys.beginNfc]), as on iPhone. On Android a key held
  /// to the phone is found for as long as the watch stream is listened to.
  final bool readsOnRequest;

  /// Whether any key can be reached at all.
  bool get any => nfc || usb || smartcards;

  /// Whether a key can be plugged in.
  bool get plugsIn => usb || smartcards;

  static SecurityKeyCapabilities fromMap(Map<Object?, Object?> map) => SecurityKeyCapabilities(
    nfc: map['nfc'] == true,
    nfcOn: map['nfcOn'] == true,
    usb: map['usb'] == true,
    smartcards: map['smartcards'] == true,
    readsOnRequest: map['readsOnRequest'] == true,
  );
}

/// The phone's side of talking to a security key: it finds keys and
/// carries bytes, and knows nothing of what the bytes mean
/// (`android/.../securitykey/SecurityKeyChannel.kt`,
/// `ios/Runner/SecurityKeyChannel.swift`). The protocols are Dart, in
/// `lib/security_key/`. Every call throws a [SecurityKeyError].
abstract interface class SecurityKeys {
  /// What this phone can reach a key with. Never throws.
  Future<SecurityKeyCapabilities> capabilities();

  /// Keys arriving and leaving. Listening starts the search (Android's NFC
  /// reader mode and USB receiver, iPhone's smartcard slots) and cancelling
  /// the last subscription stops it. Keys already plugged in when the
  /// search starts are not told here; ask [present] once listening.
  Stream<SecurityKeyEvent> watch();

  /// The keys plugged in now.
  Future<List<SecurityKeyDevice>> present();

  /// Shows the system's question about the USB device [deviceId] and
  /// returns the links it has as a security key: none when it turns out
  /// not to be one. Throws [SecurityKeyDenied] when the person refuses.
  Future<List<SecurityKeyLink>> requestPermission(String deviceId);

  /// Starts iPhone's NFC reader session with [message] on its sheet. The
  /// key that is read arrives on [watch], and the session's end as a
  /// [SecurityKeySessionEnded]. Does nothing on Android.
  Future<void> beginNfc(String message);

  /// Changes the text on iPhone's NFC sheet. Does nothing on Android.
  Future<void> setNfcMessage(String message);

  /// Ends iPhone's NFC reader session, with a tick or, with [error], with
  /// that text and a cross. Does nothing on Android.
  Future<void> endNfc({String? error});

  /// Gets the link [linkId] ready for messages.
  Future<void> open(String linkId);

  /// Ends the link. Closing a link that is gone is not an error.
  Future<void> close(String linkId);

  /// Sends one APDU and returns the key's answer, status word included.
  /// For links whose kind [SecurityKeyLinkKind.carriesApdus].
  Future<Uint8List> transceive(String linkId, Uint8List apdu, {required Duration timeout});

  /// Sends raw [frames], in order: HID reports or CCID bulk packets.
  Future<void> write(String linkId, List<Uint8List> frames);

  /// The raw frames the key has sent: those waiting, or the first to come
  /// within [timeout]. Empty when none came.
  Future<List<Uint8List>> read(String linkId, Duration timeout);
}

/// [SecurityKeys] over the app's channels. A build without the native
/// side, such as the tests', has no NFC and no USB.
class ChannelSecurityKeys implements SecurityKeys {
  ChannelSecurityKeys();

  static const _channel = MethodChannel('com.kemlock.app/security_keys');
  static const _events = EventChannel('com.kemlock.app/security_keys/events');

  Stream<SecurityKeyEvent>? _watch;

  @override
  Future<SecurityKeyCapabilities> capabilities() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>('capabilities');
      return map == null ? SecurityKeyCapabilities.none : SecurityKeyCapabilities.fromMap(map);
    } on MissingPluginException {
      return SecurityKeyCapabilities.none;
    } on PlatformException {
      return SecurityKeyCapabilities.none;
    }
  }

  @override
  Stream<SecurityKeyEvent> watch() => _watch ??= _events
      .receiveBroadcastStream()
      .map(SecurityKeyEvent.fromMap)
      .where((event) => event != null)
      .cast<SecurityKeyEvent>()
      .handleError((Object error) {
        // A build without the native side: no key is ever found.
      }, test: (error) => error is MissingPluginException);

  @override
  Future<List<SecurityKeyDevice>> present() async {
    final List<Object?>? devices;
    try {
      devices = await _channel.invokeMethod<List<Object?>>('present');
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      throw securityKeyError(e.code, e.message);
    }
    return [
      for (final device in devices ?? const <Object?>[])
        if (device is Map) ?SecurityKeyDevice.fromMap(device),
    ];
  }

  @override
  Future<List<SecurityKeyLink>> requestPermission(String deviceId) async =>
      _links(await _call<List<Object?>>('requestPermission', {'device': deviceId}));

  @override
  Future<void> beginNfc(String message) => _call<void>('beginNfc', {'message': message});

  @override
  Future<void> setNfcMessage(String message) => _quiet('setNfcMessage', {'message': message});

  @override
  Future<void> endNfc({String? error}) => _quiet('endNfc', {'error': error});

  @override
  Future<void> open(String linkId) => _call<void>('open', {'link': linkId});

  @override
  Future<void> close(String linkId) => _quiet('close', {'link': linkId});

  @override
  Future<Uint8List> transceive(String linkId, Uint8List apdu, {required Duration timeout}) async {
    final answer = await _call<Uint8List>('transceive', {'link': linkId, 'data': apdu, 'timeoutMs': timeout.inMilliseconds});
    if (answer == null) throw const SecurityKeyFailed('The phone gave back no answer.');
    return answer;
  }

  @override
  Future<void> write(String linkId, List<Uint8List> frames) => _call<void>('write', {'link': linkId, 'frames': frames});

  @override
  Future<List<Uint8List>> read(String linkId, Duration timeout) async {
    final frames = await _call<List<Object?>>('read', {'link': linkId, 'timeoutMs': timeout.inMilliseconds});
    return [
      for (final frame in frames ?? const <Object?>[])
        if (frame is Uint8List) frame,
    ];
  }

  Future<T?> _call<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const SecurityKeyUnavailable();
    } on PlatformException catch (e) {
      throw securityKeyError(e.code, e.message);
    }
  }

  /// For the calls that tidy up: nothing to tell when there is nothing to end.
  Future<void> _quiet(String method, Map<String, Object?> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native side: nothing to end.
    } on PlatformException {
      // The link or the session is already gone.
    }
  }
}

/// The phone's reach to security keys; tests put a fake in its place.
final securityKeysProvider = Provider<SecurityKeys>((ref) => ChannelSecurityKeys());
