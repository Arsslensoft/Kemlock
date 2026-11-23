import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/cbor.dart';

/// One frame the app sent to a key: an APDU, a HID report or a CCID packet.
class FakeFrame {
  FakeFrame(this.link, List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final String link;
  final Uint8List bytes;

  String get hex => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

  @override
  String toString() => '$link $hex';
}

/// The key's end of one link. An APDU link answers [transceive]; a raw
/// link takes [write] and gives back frames on [read].
abstract class FakeLink {
  /// The fake phone the link is on, once its key has arrived.
  late FakeSecurityKeys host;

  bool get extendedLength => true;
  int get frameSize => 0;

  /// The answer to [apdu]; an application that takes its time answers
  /// with a future.
  FutureOr<Uint8List> transceive(Uint8List apdu, Duration timeout) => throw UnsupportedError('Not an APDU link.');

  FutureOr<void> write(Uint8List frame) => throw UnsupportedError('Not a raw link.');

  /// The frames ready now. A link with none lets [timeout] pass on the
  /// fake clock and returns nothing.
  List<Uint8List> read(Duration timeout) => throw UnsupportedError('Not a raw link.');
}

/// A link that answers what the test told it to, in order.
///
/// ```dart
/// final link = ScriptedLink()..reply([0x90, 0x00]);          // an APDU link
/// final raw = ScriptedLink()..frames([report1, report2]);   // a raw link: one read's worth
/// ```
class ScriptedLink extends FakeLink {
  ScriptedLink({this.extendedLength = true, this.frameSize = 0});

  @override
  final bool extendedLength;

  @override
  final int frameSize;

  final Queue<Uint8List> _replies = Queue();
  final Queue<List<Uint8List>> _reads = Queue();

  /// The answer to the next APDU not yet answered.
  void reply(List<int> answer) => _replies.add(Uint8List.fromList(answer));

  /// What one later [read] gives back.
  void frames(List<List<int>> frames) => _reads.add([for (final frame in frames) Uint8List.fromList(frame)]);

  @override
  Uint8List transceive(Uint8List apdu, Duration timeout) {
    if (_replies.isEmpty) throw StateError('The script has no answer for this APDU.');
    return _replies.removeFirst();
  }

  @override
  void write(Uint8List frame) {}

  @override
  List<Uint8List> read(Duration timeout) {
    if (_reads.isEmpty) {
      host.elapse(timeout);
      return const [];
    }
    return _reads.removeFirst();
  }
}

/// A key as the fake phone sees it: its links by kind.
class FakeDevice {
  FakeDevice({required this.id, this.productName, required this.links, bool? needsPermission, this.onArrive})
    : needsPermission =
          needsPermission ?? links.keys.any((kind) => kind == SecurityKeyLinkKind.usbHid || kind == SecurityKeyLinkKind.usbCcid);

  final String id;
  final String? productName;
  final Map<SecurityKeyLinkKind, FakeLink> links;

  /// Whether the system asks before the app may use it, as Android does for USB.
  final bool needsPermission;

  /// Called when the key gets power: held to the phone or plugged in.
  final void Function(FakeSecurityKeys host)? onArrive;

  /// The key stops answering: APDUs time out and reads give nothing.
  bool silent = false;

  bool get isNfc => links.containsKey(SecurityKeyLinkKind.nfc);

  String linkId(SecurityKeyLinkKind kind) => '$id:${kind.name}';
}

/// Stands in for the phone's reach to security keys. Keys arrive and leave
/// as the test says, every frame sent is recorded, time is a clock the
/// fake moves, and each way to fail can be asked for.
///
/// ```dart
/// final phone = FakeSecurityKeys();                    // an Android phone with NFC and USB
/// final key = FakeKey(ctap: FakeFidoKey()).device(kinds: {SecurityKeyLinkKind.nfc});
/// phone.arrive(key);                                   // held to the phone
/// phone.remove(key);                                   // taken away
/// phone.removeWhen = (frame) => frame[1] == 0x10;      // leaves when it gets this frame
/// key.silent = true;                                   // stops answering
/// phone.refusePermission = true;                       // the USB question is refused
/// phone.cancelNfcSheet();                              // the iPhone sheet is closed
/// expect(phone.sent.map((f) => f.hex), [...]);
/// ```
class FakeSecurityKeys implements SecurityKeys {
  FakeSecurityKeys({this.phone = android, DateTime? start}) : _now = start ?? DateTime.utc(2026, 11, 16, 9);

  /// An Android phone with NFC on and USB hosting.
  static const android = SecurityKeyCapabilities(nfc: true, nfcOn: true, usb: true);

  /// An iPhone with NFC and a USB-C port that offers smartcards.
  static const iphone = SecurityKeyCapabilities(nfc: true, nfcOn: true, smartcards: true, readsOnRequest: true);

  /// An iPad: no NFC, smartcards over USB-C.
  static const ipad = SecurityKeyCapabilities(smartcards: true, readsOnRequest: true);

  /// What [capabilities] answers; the test may change it at any time.
  SecurityKeyCapabilities phone;

  DateTime _now;

  /// Every frame sent to a key, in order.
  final List<FakeFrame> sent = [];

  /// Every other call, in order: `watch`, `stopWatch`, `present`,
  /// `requestPermission usb:1`, `beginNfc Hold your key`, `setNfcMessage
  /// Reading`, `endNfc`, `endNfc No key`, `open nfc:1:nfc`, `close nfc:1:nfc`.
  final List<String> calls = [];

  /// The system's USB question is refused.
  bool refusePermission = false;

  /// Keeps the USB question up until it completes, when set.
  Future<void>? permissionWaits;

  /// The next [beginNfc] is closed by the person at once.
  bool cancelNextNfcSheet = false;

  /// The key that gets a frame for which this answers true leaves at that
  /// moment: before it saw the frame, or, with [removeAfterProcessing],
  /// once it has acted on it but before the app hears the answer.
  bool Function(Uint8List frame)? removeWhen;
  bool removeAfterProcessing = false;

  /// Lets other work in between two reads of raw frames, as a real link
  /// does. A widget test sets it to act while a key keeps the app waiting:
  /// each read then takes a millisecond of the test's clock.
  bool yieldOnRead = false;

  /// The application identifiers, in lowercase hex, the phone lets the app
  /// select over NFC, as the list in iPhone's Info.plist does. Null for any.
  Set<String>? declaredAids;

  final List<FakeDevice> _here = [];
  final Set<String> _permitted = {};
  final Set<String> _open = {};
  FakeDevice? _held;
  FakeDevice? _sessionTag;
  bool _session = false;
  late final StreamController<SecurityKeyEvent> _events = StreamController.broadcast(
    onListen: () {
      calls.add('watch');
      // A key already in the field is found as soon as the search starts.
      for (final device in _here.where((device) => device.isNfc)) {
        _events.add(SecurityKeyArrived(_describe(device)));
      }
    },
    onCancel: () => calls.add('stopWatch'),
  );

  Override get asOverride => securityKeysProvider.overrideWithValue(this);

  /// The fake clock.
  DateTime now() => _now;

  /// Moves the fake clock on.
  void elapse(Duration time) => _now = _now.add(time);

  /// Whether something listens for keys.
  bool get isWatching => _events.hasListener;

  /// Whether iPhone's NFC sheet is up.
  bool get nfcSheetUp => _session;

  /// The links the app has open.
  Set<String> get openLinks => Set.unmodifiable(_open);

  /// The keys held to the phone or plugged in.
  List<FakeDevice> get here => List.unmodifiable(_here);

  /// [device] is held to the phone or plugged in. On a phone that reads
  /// NFC only on request, a key held to it is found by the next read.
  void arrive(FakeDevice device) {
    for (final link in device.links.values) {
      link.host = this;
    }
    if (device.isNfc && phone.readsOnRequest) {
      _held = device;
      if (_session) _found(device);
      return;
    }
    _here.add(device);
    device.onArrive?.call(this);
    if (_events.hasListener) _events.add(SecurityKeyArrived(_describe(device)));
  }

  void _found(FakeDevice device) {
    _held = null;
    _sessionTag = device;
    _here.add(device);
    device.onArrive?.call(this);
    _events.add(SecurityKeyArrived(_describe(device)));
  }

  /// [device] is taken away or unplugged.
  void remove(FakeDevice device) {
    if (_held == device) _held = null;
    if (!_here.remove(device)) return;
    if (_sessionTag == device) _sessionTag = null;
    _open.removeWhere((link) => link.startsWith('${device.id}:'));
    _permitted.remove(device.id);
    if (_events.hasListener) _events.add(SecurityKeyLeft(device.id));
  }

  /// The person closes iPhone's NFC sheet.
  void cancelNfcSheet() => _endSession(const SecurityKeyCancelled());

  /// iPhone's NFC session runs out.
  void expireNfcSession() => _endSession(const SecurityKeyTimeout());

  void _endSession(SecurityKeyError? error) {
    if (!_session) return;
    _session = false;
    final tag = _sessionTag;
    if (tag != null) remove(tag);
    if (_events.hasListener) _events.add(SecurityKeySessionEnded(error));
  }

  SecurityKeyDevice _describe(FakeDevice device) {
    final asks = device.needsPermission && !_permitted.contains(device.id);
    return SecurityKeyDevice(
      id: device.id,
      productName: device.productName,
      needsPermission: asks,
      links: asks ? const [] : _links(device),
    );
  }

  List<SecurityKeyLink> _links(FakeDevice device) => [
    for (final MapEntry(key: kind, value: link) in device.links.entries)
      SecurityKeyLink(id: device.linkId(kind), kind: kind, extendedLength: link.extendedLength, frameSize: link.frameSize),
  ];

  @override
  Future<SecurityKeyCapabilities> capabilities() async => phone;

  @override
  Stream<SecurityKeyEvent> watch() => _events.stream;

  @override
  Future<List<SecurityKeyDevice>> present() async {
    calls.add('present');
    return [
      for (final device in _here)
        if (!device.isNfc) _describe(device),
    ];
  }

  @override
  Future<List<SecurityKeyLink>> requestPermission(String deviceId) async {
    calls.add('requestPermission $deviceId');
    if (permissionWaits case final waits?) await waits;
    final device = _here.where((device) => device.id == deviceId).firstOrNull;
    if (device == null) throw const SecurityKeyRemoved();
    if (refusePermission) throw const SecurityKeyDenied();
    _permitted.add(deviceId);
    return _links(device);
  }

  @override
  Future<void> beginNfc(String message) async {
    calls.add('beginNfc $message');
    if (!phone.readsOnRequest) return;
    if (!phone.nfc) throw const SecurityKeyUnavailable();
    _session = true;
    if (cancelNextNfcSheet) {
      cancelNextNfcSheet = false;
      scheduleMicrotask(cancelNfcSheet);
    } else if (_held case final device?) {
      scheduleMicrotask(() {
        if (_session && _held == device) _found(device);
      });
    }
  }

  @override
  Future<void> setNfcMessage(String message) async => calls.add('setNfcMessage $message');

  @override
  Future<void> endNfc({String? error}) async {
    calls.add(error == null ? 'endNfc' : 'endNfc $error');
    _endSession(null);
  }

  @override
  Future<void> open(String linkId) async {
    calls.add('open $linkId');
    _find(linkId);
    _open.add(linkId);
  }

  @override
  Future<void> close(String linkId) async {
    calls.add('close $linkId');
    _open.remove(linkId);
  }

  @override
  Future<Uint8List> transceive(String linkId, Uint8List apdu, {required Duration timeout}) async {
    sent.add(FakeFrame(linkId, apdu));
    final (device, link) = _find(linkId);
    if (device.silent) {
      elapse(timeout);
      throw const SecurityKeyTimeout();
    }
    final leaves = removeWhen?.call(apdu) ?? false;
    if (leaves && !removeAfterProcessing) {
      remove(device);
      throw const SecurityKeyRemoved();
    }
    final declared = declaredAids;
    if (declared != null && linkId.endsWith(':nfc') && apdu.length > 5 && apdu[0] == 0 && apdu[1] == 0xa4 && apdu[2] == 0x04) {
      final aid = FakeFrame('', apdu.sublist(5, 5 + apdu[4])).hex;
      if (!declared.contains(aid)) throw const SecurityKeyNotDeclared();
    }
    final reply = link.transceive(apdu, timeout);
    // Awaited only when it is a future, so that an answer at hand comes back as it always did
    final answer = reply is Future<Uint8List> ? await reply : reply;
    if (leaves) remove(device);
    if (!_here.contains(device)) throw const SecurityKeyRemoved();
    return answer;
  }

  @override
  Future<void> write(String linkId, List<Uint8List> frames) async {
    for (final frame in frames) {
      sent.add(FakeFrame(linkId, frame));
      final (device, link) = _find(linkId);
      if (device.silent) continue;
      final leaves = removeWhen?.call(frame) ?? false;
      if (leaves && !removeAfterProcessing) {
        remove(device);
        throw const SecurityKeyRemoved();
      }
      final written = link.write(frame);
      if (written is Future<void>) await written;
      if (leaves) remove(device);
      if (!_here.contains(device)) throw const SecurityKeyRemoved();
    }
  }

  @override
  Future<List<Uint8List>> read(String linkId, Duration timeout) async {
    if (yieldOnRead) await Future<void>.delayed(const Duration(milliseconds: 1));
    final (device, link) = _find(linkId);
    if (device.silent) {
      elapse(timeout);
      return const [];
    }
    return link.read(timeout);
  }

  (FakeDevice, FakeLink) _find(String linkId) {
    for (final device in _here) {
      for (final MapEntry(key: kind, value: link) in device.links.entries) {
        if (device.linkId(kind) == linkId) return (device, link);
      }
    }
    throw const SecurityKeyRemoved();
  }
}

/// A smartcard application on a [FakeKey]. Later changes add theirs.
abstract class FakeApplet {
  List<int> get aid;

  /// What the application answers to SELECT.
  List<int> get selectAnswer => const [];

  /// The status it answers SELECT with: `9000`, or the warning of a card in
  /// a state of its own, which still leaves it selected.
  int get selectStatus => 0x9000;

  /// Told that SELECT opened it: what a connection allowed before is gone.
  void selected() {}

  /// Answers one command: the data and the status word, or a future of them
  /// for an application that takes its time.
  FutureOr<(List<int>, int)> command(int cla, int ins, int p1, int p2, Uint8List data);
}

/// What a CTAP2 authenticator answers to one request, and how long it
/// takes about it.
class FakeCtapReply {
  FakeCtapReply(this.status, [this.value]);

  /// The key keeps saying [status] (1 working, 2 waiting for a touch) for
  /// ever, until it is told to cancel.
  FakeCtapReply.hang(int status) : status = 0, value = null, hangs = status;

  final int status;
  final Object? value;

  /// The keep-alive statuses the key sends before it answers.
  List<int> keepalives = const [];

  /// The status of the endless keep-alives of [FakeCtapReply.hang].
  int? hangs;

  Uint8List get bytes => Uint8List.fromList([status, if (value != null) ...cborEncode(value)]);
}

/// The CTAP2 side of a [FakeKey]; `fake_fido_key.dart` has one.
abstract class FakeCtapAuthenticator {
  /// Answers the request [command] with its CBOR [parameters] (empty for
  /// none), received over a link of [kind].
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind);

  /// The key got power; [now] is the clock it lives by.
  void poweredUp(DateTime Function() now) {}

  /// The request the key was working on was cancelled.
  void cancelled() {}
}

/// The identifier of the FIDO application.
const fakeFidoAid = [0xa0, 0x00, 0x00, 0x06, 0x47, 0x2f, 0x00, 0x01];

/// A security key in software, at the level of the wire: it takes APDUs
/// over "NFC" or a smartcard slot, CCID packets or HID reports, and hands
/// CTAP2 requests to its [ctap] authenticator and smartcard commands to
/// its [applets]. The framing here is written from the standards, apart
/// from the app's own.
///
/// ```dart
/// final key = FakeKey(productName: 'Example Key', ctap: FakeFidoKey());
/// phone.arrive(key.device(kinds: {SecurityKeyLinkKind.usbHid, SecurityKeyLinkKind.usbCcid}));
/// ```
class FakeKey {
  FakeKey({
    this.productName,
    this.ctap,
    List<FakeApplet>? applets,
    this.fido = true,
    this.selectVersion = 'FIDO_2_0',
    this.extendedLength = true,
    this.fidoOverSmartcard = false,
    this.keepaliveEvery = const Duration(milliseconds: 100),
  }) : applets = applets ?? [];

  final String? productName;

  /// The FIDO2 authenticator. A key with [fido] and none is U2F only.
  FakeCtapAuthenticator? ctap;
  final List<FakeApplet> applets;

  /// Whether the key has a FIDO application at all.
  bool fido;

  /// What the FIDO application answers to SELECT: `FIDO_2_0`, or `U2F_V2`
  /// as keys that also speak U2F do.
  String selectVersion;

  /// Whether the key takes extended-length APDUs.
  bool extendedLength;

  /// Whether the FIDO application answers on the smartcard interface too
  /// (CCID, or iPhone's slot). Most keys answer it over NFC only.
  bool fidoOverSmartcard;

  /// The time between two keep-alives.
  Duration keepaliveEvery;

  /// Cuts each CCID answer into chunks of this many bytes, one per read.
  int? ccidChunk;

  /// How many times the card asks for more time before each CCID answer.
  int ccidTimeExtensions = 0;

  /// The size of the key's HID reports.
  int reportSize = 64;

  static int _count = 0;

  /// The key as a device with links of [kinds], to give to
  /// [FakeSecurityKeys.arrive]. Each call is the key freshly connected.
  FakeDevice device({required Set<SecurityKeyLinkKind> kinds, String? id}) {
    final nfc = kinds.contains(SecurityKeyLinkKind.nfc);
    return FakeDevice(
      id: id ?? '${nfc ? 'nfc' : (kinds.contains(SecurityKeyLinkKind.smartcard) ? 'smartcard' : 'usb')}:${++_count}',
      productName: nfc ? null : productName,
      links: {
        for (final kind in kinds)
          kind: switch (kind) {
            SecurityKeyLinkKind.nfc || SecurityKeyLinkKind.smartcard => _ApduLink(_Card(this, kind)),
            SecurityKeyLinkKind.usbCcid => _CcidLink(_Card(this, kind)),
            SecurityKeyLinkKind.usbHid => _HidLink(this),
          },
      },
      onArrive: (host) => ctap?.poweredUp(host.now),
    );
  }
}

/// The smartcard side of a [FakeKey] on one link: SELECT, chained
/// commands, answers handed out with GET RESPONSE, and the FIDO
/// application's CTAP2 messages.
class _Card {
  _Card(this.key, this.kind);

  final FakeKey key;
  final SecurityKeyLinkKind kind;
  late FakeSecurityKeys host;

  Object? _selected;
  final BytesBuilder _chain = BytesBuilder(copy: true);
  Uint8List _rest = Uint8List(0);
  FakeCtapReply? _pending;
  List<int> _keepalives = const [];

  Uint8List _answer(List<int> data, int sw) => Uint8List.fromList([...data, sw >> 8, sw & 0xff]);

  FutureOr<Uint8List> apdu(Uint8List raw) {
    if (raw.length < 4) return _answer(const [], 0x6700);
    final cla = raw[0];
    final ins = raw[1];
    final p1 = raw[2];
    final p2 = raw[3];
    final body = Uint8List.sublistView(raw, 4);
    var data = Uint8List(0);
    var extended = false;
    if (body.length >= 3 && body[0] == 0) {
      if (!key.extendedLength) return _answer(const [], 0x6700);
      extended = true;
      if (body.length > 3) {
        final length = body[1] << 8 | body[2];
        if (body.length < 3 + length) return _answer(const [], 0x6700);
        data = Uint8List.sublistView(body, 3, 3 + length);
      }
    } else if (body.length > 1) {
      if (body.length < 1 + body[0]) return _answer(const [], 0x6700);
      data = Uint8List.sublistView(body, 1, 1 + body[0]);
    }
    if (cla & 0x10 != 0) {
      _chain.add(data);
      return _answer(const [], 0x9000);
    }
    if (_chain.isNotEmpty) {
      _chain.add(data);
      data = _chain.takeBytes();
    }
    if (cla == 0 && ins == 0xc0) return _hand(_rest, extended: false);
    final selected = _selected;
    final select = cla == 0 && ins == 0xa4 && p1 == 0x04;
    // An application of a later change may answer later
    final FutureOr<(List<int>, int)> result = selected is FakeApplet && !select
        ? selected.command(cla, ins, p1, p2, data)
        : _command(cla, ins, p1, p2, data);
    if (result is Future<(List<int>, int)>) return result.then((result) => _reply(result, extended: extended));
    return _reply(result, extended: extended);
  }

  Uint8List _reply((List<int>, int) result, {required bool extended}) {
    final (answer, sw) = result;
    if (sw != 0x9000) return _answer(answer, sw);
    return _hand(Uint8List.fromList(answer), extended: extended);
  }

  /// Hands out [data] whole, or 256 bytes at a time when the command was a short one.
  Uint8List _hand(Uint8List data, {required bool extended}) {
    if (extended || data.length <= 256) {
      _rest = Uint8List(0);
      return _answer(data, 0x9000);
    }
    _rest = Uint8List.sublistView(data, 256);
    return _answer(Uint8List.sublistView(data, 0, 256), 0x6100 | (_rest.length > 255 ? 0 : _rest.length));
  }

  (List<int>, int) _command(int cla, int ins, int p1, int p2, Uint8List data) {
    if (cla == 0 && ins == 0xa4 && p1 == 0x04) {
      if (_same(data, fakeFidoAid)) {
        if (!key.fido || (kind != SecurityKeyLinkKind.nfc && !key.fidoOverSmartcard)) return (const [], 0x6a82);
        _selected = fakeFidoAid;
        return (ascii.encode(key.ctap == null ? 'U2F_V2' : key.selectVersion), 0x9000);
      }
      for (final applet in key.applets) {
        if (_same(data, applet.aid)) {
          _selected = applet;
          applet.selected();
          return (applet.selectAnswer, applet.selectStatus);
        }
      }
      return (const [], 0x6a82);
    }
    final selected = _selected;
    if (selected == null) return (const [], 0x6985);
    final ctap = key.ctap;
    if (cla != 0x80 || ctap == null) return (const [], 0x6d00);
    switch (ins) {
      case 0x10:
        if (data.isEmpty) return (const [], 0x6700);
        final reply = ctap.handle(data[0], Uint8List.sublistView(data, 1), kind);
        // Without the "I can wait" bit the key answers only when it is done.
        if (p1 & 0x80 == 0 || (reply.keepalives.isEmpty && reply.hangs == null)) return (reply.bytes, 0x9000);
        _pending = reply;
        _keepalives = [...reply.keepalives];
        return _next();
      case 0x11:
        if (_pending == null) return (const [], 0x6985);
        return _next();
      default:
        return (const [], 0x6d00);
    }
  }

  (List<int>, int) _next() {
    final reply = _pending!;
    if (reply.hangs case final status?) {
      host.elapse(key.keepaliveEvery);
      return ([status], 0x9100);
    }
    if (_keepalives.isNotEmpty) {
      host.elapse(key.keepaliveEvery);
      return ([_keepalives.removeAt(0)], 0x9100);
    }
    _pending = null;
    return (reply.bytes, 0x9000);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _ApduLink extends FakeLink {
  _ApduLink(this._card);

  final _Card _card;

  @override
  bool get extendedLength => _card.key.extendedLength;

  @override
  FutureOr<Uint8List> transceive(Uint8List apdu, Duration timeout) {
    _card.host = host;
    return _card.apdu(apdu);
  }
}

/// The CCID interface of a [FakeKey]: power on, `XfrBlock` in, `DataBlock` out.
class _CcidLink extends FakeLink {
  _CcidLink(this._card);

  final _Card _card;
  final Queue<Uint8List> _out = Queue();

  @override
  bool get extendedLength => _card.key.extendedLength;

  @override
  int get frameSize => 3072;

  Uint8List _message(int type, int sequence, List<int> data, {int status = 0, int error = 0}) {
    final length = data.length;
    return Uint8List.fromList([
      type,
      length & 0xff,
      length >> 8 & 0xff,
      length >> 16 & 0xff,
      length >> 24,
      0,
      sequence,
      status,
      error,
      0,
      ...data,
    ]);
  }

  void _send(Uint8List message) {
    final chunk = _card.key.ccidChunk;
    if (chunk == null) {
      _out.add(message);
      return;
    }
    for (var offset = 0; offset < message.length; offset += chunk) {
      _out.add(Uint8List.sublistView(message, offset, offset + chunk < message.length ? offset + chunk : message.length));
    }
  }

  @override
  FutureOr<void> write(Uint8List frame) {
    _card.host = host;
    if (frame.length < 10) return null;
    final sequence = frame[6];
    switch (frame[0]) {
      case 0x62:
        _send(_message(0x80, sequence, const [0x3b, 0x80, 0x80, 0x01, 0x01]));
      case 0x63:
        _send(_message(0x81, sequence, const [], status: 1));
      case 0x6f:
        final length = frame[1] | frame[2] << 8 | frame[3] << 16 | frame[4] << 24;
        final answer = _card.apdu(Uint8List.sublistView(frame, 10, 10 + length));
        if (answer is Future<Uint8List>) return answer.then((answer) => _answered(sequence, answer));
        _answered(sequence, answer);
      default:
        _send(_message(0x81, sequence, const [], status: 0x40, error: 0));
    }
  }

  void _answered(int sequence, Uint8List answer) {
    for (var i = 0; i < _card.key.ccidTimeExtensions; i++) {
      _send(_message(0x80, sequence, const [], status: 0x80, error: 1));
    }
    _send(_message(0x80, sequence, answer));
  }

  @override
  List<Uint8List> read(Duration timeout) {
    if (_out.isEmpty) {
      host.elapse(timeout);
      return const [];
    }
    return [_out.removeFirst()];
  }
}

/// The FIDO HID interface of a [FakeKey]: `INIT`, `CBOR` with its
/// keep-alives, and `CANCEL`.
class _HidLink extends FakeLink {
  _HidLink(this._key);

  final FakeKey _key;

  /// What the key has to send, a read's worth at a time, each marked as a keep-alive or not.
  final Queue<(List<Uint8List>, bool)> _out = Queue();
  int _nextChannel = 0x00010001;
  int? _channel;
  int _command = 0;
  int _length = 0;
  final BytesBuilder _payload = BytesBuilder(copy: true);
  int? _hangs;
  int _hangChannel = 0;

  @override
  int get frameSize => _key.reportSize;

  List<Uint8List> _pack(int channel, int command, List<int> payload) {
    final size = _key.reportSize;
    final cid = [channel >> 24 & 0xff, channel >> 16 & 0xff, channel >> 8 & 0xff, channel & 0xff];
    final reports = <Uint8List>[];
    var offset = 0;
    var sequence = 0;
    do {
      final head = offset == 0 ? [...cid, command | 0x80, payload.length >> 8, payload.length & 0xff] : [...cid, sequence++];
      final room = size - head.length;
      final end = offset + room < payload.length ? offset + room : payload.length;
      reports.add(
        Uint8List(size)
          ..setAll(0, head)
          ..setAll(head.length, payload.sublist(offset, end)),
      );
      offset = end;
    } while (offset < payload.length);
    return reports;
  }

  @override
  void write(Uint8List frame) {
    final channel = frame[0] << 24 | frame[1] << 16 | frame[2] << 8 | frame[3];
    if (frame[4] & 0x80 != 0) {
      _channel = channel;
      _command = frame[4] & 0x7f;
      _length = frame[5] << 8 | frame[6];
      _payload.clear();
      _payload.add(Uint8List.sublistView(frame, 7));
    } else {
      if (channel != _channel) return;
      _payload.add(Uint8List.sublistView(frame, 5));
    }
    if (_payload.length < _length) return;
    final payload = Uint8List.sublistView(_payload.takeBytes(), 0, _length);
    _channel = null;
    _message(channel, _command, payload);
  }

  void _message(int channel, int command, Uint8List payload) {
    final ctap = _key.ctap;
    switch (command) {
      case 0x06:
        final given = _nextChannel++;
        _out.add((
          _pack(channel, 0x06, [
            ...payload.take(8),
            given >> 24 & 0xff,
            given >> 16 & 0xff,
            given >> 8 & 0xff,
            given & 0xff,
            2,
            5,
            4,
            3,
            0x01 | (ctap == null ? 0 : 0x04),
          ]),
          false,
        ));
      case 0x10 when ctap != null && payload.isNotEmpty:
        final reply = ctap.handle(payload[0], Uint8List.sublistView(payload, 1), SecurityKeyLinkKind.usbHid);
        if (reply.hangs case final status?) {
          _hangs = status;
          _hangChannel = channel;
          return;
        }
        for (final status in reply.keepalives) {
          _out.add((_pack(channel, 0x3b, [status]), true));
        }
        _out.add((_pack(channel, 0x10, reply.bytes), false));
      case 0x11:
        final working = _hangs != null || _out.any((batch) => batch.$2);
        _hangs = null;
        if (!working) return;
        _out.clear();
        ctap?.cancelled();
        // CTAP2_ERR_KEEPALIVE_CANCEL
        _out.add((_pack(channel, 0x10, const [0x2d]), false));
      default:
        _out.add((_pack(channel, 0x3f, const [0x01]), false));
    }
  }

  @override
  List<Uint8List> read(Duration timeout) {
    if (_out.isEmpty) {
      if (_hangs case final status?) {
        host.elapse(_key.keepaliveEvery < timeout ? _key.keepaliveEvery : timeout);
        return _pack(_hangChannel, 0x3b, [status]);
      }
      host.elapse(timeout);
      return const [];
    }
    final (frames, keepalive) = _out.removeFirst();
    if (keepalive) host.elapse(_key.keepaliveEvery);
    return frames;
  }
}
