import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/apdu.dart';
import 'package:kemlock/security_key/cbor.dart';
import 'package:kemlock/security_key/connection.dart';

import '../fakes/fake_security_keys.dart';
import 'hex.dart';

const _nfc = {SecurityKeyLinkKind.nfc};
const _hid = {SecurityKeyLinkKind.usbHid};
const _usb = {SecurityKeyLinkKind.usbHid, SecurityKeyLinkKind.usbCcid};

/// An application that keeps a value: `DA` writes it, `CA` reads it back.
class _Store extends FakeApplet {
  Uint8List value = Uint8List(0);

  @override
  List<int> get aid => const [0xa0, 0x00, 0x00, 0x05, 0x27, 0x21, 0x01];

  @override
  List<int> get selectAnswer => const [0x4f, 0x4b];

  @override
  (List<int>, int) command(int cla, int ins, int p1, int p2, Uint8List data) {
    switch (ins) {
      case 0xda:
        value = Uint8List.fromList(data);
        return (const [], 0x9000);
      case 0xca:
        return (value, 0x9000);
      default:
        return (const [], 0x6d00);
    }
  }
}

/// An application in its termination state until `44` activates it: it
/// answers SELECT with `6285`, as an OpenPGP card does.
class _Terminated extends _Store {
  bool active = false;

  @override
  int get selectStatus => active ? 0x9000 : 0x6285;

  @override
  (List<int>, int) command(int cla, int ins, int p1, int p2, Uint8List data) {
    if (ins != 0x44) return super.command(cla, ins, p1, p2, data);
    active = true;
    return (const [], 0x9000);
  }
}

/// An authenticator that answers every request with what it was asked,
/// after the keep-alives the test sets.
class _Echo extends FakeCtapAuthenticator {
  List<int> keepalives = const [];
  int? hangs;
  int cancels = 0;
  final List<int> commands = [];
  void Function(int command)? onCommand;

  @override
  FakeCtapReply handle(int command, Uint8List parameters, SecurityKeyLinkKind kind) {
    commands.add(command);
    onCommand?.call(command);
    if (hangs case final status?) return FakeCtapReply.hang(status);
    return FakeCtapReply(
      0,
      {1: command, 2: parameters.isEmpty ? null : cborDecode(parameters), 3: kind.name}..removeWhere((_, v) => v == null),
    )..keepalives = keepalives;
  }

  @override
  void cancelled() => cancels++;
}

void main() {
  late FakeSecurityKeys phone;
  late SecurityKeyHub hub;
  late int changes;
  late List<String> holds;

  /// A hub on [phone], started, with [devices] already there.
  Future<void> start({SecurityKeyCapabilities capabilities = FakeSecurityKeys.android, List<FakeDevice> devices = const []}) async {
    phone = FakeSecurityKeys(phone: capabilities);
    devices.forEach(phone.arrive);
    changes = 0;
    holds = [];
    hub = SecurityKeyHub(
      phone,
      now: phone.now,
      nonce: () => unhex('0102030405060708'),
      hold: () {
        holds.add('hold');
        return () => holds.add('release');
      },
    )..onChanged = () => changes++;
    addTearDown(() => hub.stop());
    await hub.start();
    await pumpEventQueue();
  }

  SecurityKeyConnection live() => hub.live!;

  group('an application is opened by its identifier', () {
    test('and answers when the key has it', () async {
      final store = _Store();
      await start(
        devices: [
          FakeKey(applets: [store]).device(kinds: _nfc),
        ],
      );

      final card = await live().selectApplication(store.aid);
      expect(card.selectAnswer, [0x4f, 0x4b]);
      expect((await card.transmit(ApduCommand(ins: 0xda, data: [1, 2, 3]))).ok, isTrue);
      final read = await card.transmit(ApduCommand(ins: 0xca, le: 256));

      expect(read.data, [1, 2, 3]);
      expect(phone.sent.first.hex, '00a4040007a000000527210100');
    });

    test('is reported missing when the key has none, and the connection stays usable', () async {
      final store = _Store();
      await start(
        devices: [
          FakeKey(applets: [store]).device(kinds: _nfc),
        ],
      );

      await expectLater(live().selectApplication(unhex('a000000308')), throwsA(isA<SecurityKeyNoApplication>()));

      expect(live().isOpen, isTrue);
      expect((await live().selectApplication(store.aid)).selectAnswer, [0x4f, 0x4b]);
    });

    test('in a state of its own when the caller lets that status count, and refused when not', () async {
      final store = _Terminated();
      await start(
        devices: [
          FakeKey(applets: [store]).device(kinds: _nfc),
        ],
      );

      await expectLater(live().selectApplication(store.aid), throwsA(isA<SecurityKeyFailed>()));
      final card = await live().selectApplication(store.aid, alsoSelected: {0x6285});

      expect(card.selectStatus, 0x6285);
      expect((await card.transmit(ApduCommand(ins: 0x44))).ok, isTrue);
      expect((await live().selectApplication(store.aid)).selectStatus, 0x9000);
    });

    test('is reported unreachable on iPhone when the app did not declare the identifier', () async {
      final store = _Store();
      await start(capabilities: FakeSecurityKeys.iphone);
      phone
        ..declaredAids = {hex(fidoAid)}
        ..arrive(FakeKey(applets: [store], ctap: _Echo()).device(kinds: _nfc));

      await hub.runOnKey((connection) async {
        await expectLater(connection.selectApplication(store.aid), throwsA(isA<SecurityKeyNotDeclared>()));
        expect(connection.isOpen, isTrue);
        expect((await connection.openFido()).selectVersion, 'FIDO_2_0');
      });
    });

    test('one at a time: opening another closes the one before', () async {
      final store = _Store();
      await start(
        devices: [
          FakeKey(applets: [store], ctap: _Echo()).device(kinds: _nfc),
        ],
      );

      final card = await live().selectApplication(store.aid);
      final fido = await live().openFido();

      await expectLater(card.transmit(ApduCommand(ins: 0xca, le: 256)), throwsStateError);
      expect((await fido.send(4)).status, 0);
    });
  });

  group('smartcard commands of any allowed length', () {
    test('reach a key that does not take long frames in chained parts, and a long answer comes back whole', () async {
      final store = _Store();
      await start(
        devices: [
          FakeKey(applets: [store], extendedLength: false).device(kinds: _nfc),
        ],
      );
      final value = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));

      final card = await live().selectApplication(store.aid);
      expect((await card.transmit(ApduCommand(ins: 0xda, data: value))).ok, isTrue);
      final read = await card.transmit(ApduCommand(ins: 0xca, le: 256));

      expect(store.value, value);
      expect(read.data, value);
      final frames = phone.sent.map((frame) => frame.bytes).toList();
      expect(
        [for (final frame in frames.sublist(1, 5)) frame[0]],
        [0x10, 0x10, 0x10, 0x00],
        reason: 'the chaining bit on all but the last',
      );
      expect(frames.where((frame) => frame[1] == 0xc0), hasLength(3), reason: '1,000 bytes come back in four parts');
    });

    test('go as one extended frame where the link takes them', () async {
      final store = _Store();
      await start(
        devices: [
          FakeKey(applets: [store]).device(kinds: _nfc),
        ],
      );
      final value = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));

      final card = await live().selectApplication(store.aid);
      await card.transmit(ApduCommand(ins: 0xda, data: value));
      final read = await card.transmit(ApduCommand(ins: 0xca, le: 65536));

      expect(read.data, value);
      expect(phone.sent, hasLength(3));
    });

    test('ride in CCID packets over USB, after the card is powered on', () async {
      final store = _Store();
      final key = FakeKey(applets: [store])
        ..ccidChunk = 7
        ..ccidTimeExtensions = 2;
      await start(
        devices: [
          key.device(kinds: {SecurityKeyLinkKind.usbCcid}),
        ],
      );

      final card = await live().selectApplication(store.aid);
      await card.transmit(ApduCommand(ins: 0xda, data: [9, 8, 7]));

      expect((await card.transmit(ApduCommand(ins: 0xca, le: 256))).data, [9, 8, 7]);
      expect([for (final frame in phone.sent) frame.bytes[0]], [0x62, 0x6f, 0x6f, 0x6f]);
    });
  });

  group('FIDO2 messages', () {
    test('are exchanged over NFC', () async {
      await start(
        devices: [FakeKey(ctap: _Echo()).device(kinds: _nfc)],
      );

      final fido = await live().openFido();
      final answer = await fido.send(0x06, {1: 2, 2: 'x'});

      expect(fido.kind, SecurityKeyLinkKind.nfc);
      expect(answer.status, 0);
      expect(answer.map, {
        1: 6,
        2: {1: 2, 2: 'x'},
        3: 'nfc',
      });
      expect(
        phone.sent[1].hex,
        startsWith(
          '80108000000007'
          '06a2',
        ),
        reason: 'NFCCTAP_MSG, extended',
      );
    });

    test('are exchanged over USB HID, which is preferred to the smartcard interface', () async {
      await start(
        devices: [FakeKey(ctap: _Echo(), productName: 'Example Key').device(kinds: _usb)],
      );

      final fido = await live().openFido();
      final answer = await fido.send(0x04);

      expect(fido.kind, SecurityKeyLinkKind.usbHid);
      expect(fido.selectVersion, isNull);
      expect(answer.map, {1: 4, 3: 'usbHid'});
      expect(phone.sent.every((frame) => frame.link.endsWith(':usbHid') && frame.bytes.length == 64), isTrue);
      expect(phone.sent.first.hex, startsWith('ffffffff8600080102030405060708'));
    });

    test('survive a long request and a long answer over HID', () async {
      await start(
        devices: [FakeKey(ctap: _Echo()).device(kinds: _hid)],
      );
      final blob = Uint8List.fromList(List.generate(2000, (i) => i & 0xff));

      final answer = await (await live().openFido()).send(0x0a, {1: blob});

      expect((answer.map[2]! as Map)[1], blob);
    });

    test('are refused over a smartcard link by a key that keeps FIDO to NFC', () async {
      await start(
        capabilities: FakeSecurityKeys.iphone,
        devices: [
          FakeKey(ctap: _Echo()).device(kinds: {SecurityKeyLinkKind.smartcard}),
        ],
      );

      await expectLater(
        live().openFido(),
        throwsA(
          isA<FidoUnavailable>()
              .having((e) => e.reason, 'reason', FidoUnavailableReason.noApplication)
              .having((e) => e.kind, 'kind', SecurityKeyLinkKind.smartcard),
        ),
      );
      expect(live().isOpen, isTrue);
    });

    test('are carried by a smartcard link when the key answers its FIDO application there', () async {
      await start(
        capabilities: FakeSecurityKeys.iphone,
        devices: [
          FakeKey(ctap: _Echo(), fidoOverSmartcard: true).device(kinds: {SecurityKeyLinkKind.smartcard}),
        ],
      );

      expect((await (await live().openFido()).send(4)).map[3], 'smartcard');
    });

    test('are not there on a key that answers only U2F_V2', () async {
      await start(devices: [FakeKey().device(kinds: _nfc)]);

      final fido = await live().openFido();
      expect(fido.selectVersion, 'U2F_V2');
      await expectLater(fido.send(4), throwsA(isA<FidoUnavailable>().having((e) => e.reason, 'reason', FidoUnavailableReason.u2fOnly)));

      await start(devices: [FakeKey().device(kinds: _hid)]);
      await expectLater(
        live().openFido(),
        throwsA(isA<FidoUnavailable>().having((e) => e.reason, 'reason', FidoUnavailableReason.u2fOnly)),
      );
    });

    test('work on a key that selects as U2F_V2 and speaks FIDO2 too', () async {
      await start(
        devices: [FakeKey(ctap: _Echo(), selectVersion: 'U2F_V2').device(kinds: _nfc)],
      );

      final fido = await live().openFido();

      expect(fido.selectVersion, 'U2F_V2');
      expect((await fido.send(4)).status, 0);
    });

    test('are not there on a key with no FIDO application', () async {
      await start(devices: [FakeKey(fido: false).device(kinds: _nfc)]);

      await expectLater(
        live().openFido(),
        throwsA(isA<FidoUnavailable>().having((e) => e.reason, 'reason', FidoUnavailableReason.noApplication)),
      );
    });
  });

  test('a second request is sent only after the first has ended', () async {
    final echo = _Echo()..keepalives = [1, 1];
    await start(
      devices: [FakeKey(ctap: echo).device(kinds: _hid)],
    );
    final fido = await live().openFido();
    phone.sent.clear();

    final first = fido.send(0x01);
    final second = fido.send(0x02);
    final answers = await Future.wait([first, second]);

    expect([for (final answer in answers) answer.map[1]], [1, 2]);
    expect(echo.commands, [1, 2]);
    expect([for (final frame in phone.sent) frame.bytes[7]], [1, 2], reason: 'the second request left only after the first was answered');
  });

  group('time limits', () {
    test('a silent key ends the exchange with a time-out and the connection is closed', () async {
      final device = FakeKey(ctap: _Echo()).device(kinds: _nfc);
      await start(devices: [device]);
      final fido = await live().openFido();
      final connection = live();
      final start0 = phone.now();
      device.silent = true;

      await expectLater(fido.send(4), throwsA(isA<SecurityKeyTimeout>()));

      expect(phone.now().difference(start0), KeyLimits.ctap);
      expect(connection.isOpen, isFalse);
      expect(phone.openLinks, isEmpty);
      await expectLater(fido.send(4), throwsA(isA<SecurityKeyRemoved>()));
    });

    test('a silent key over HID is told to stop', () async {
      final device = FakeKey(ctap: _Echo()).device(kinds: _hid);
      await start(devices: [device]);
      final fido = await live().openFido();
      device.silent = true;

      await expectLater(fido.send(4), throwsA(isA<SecurityKeyTimeout>()));

      expect(phone.sent.last.bytes[4], 0x91, reason: 'CTAPHID_CANCEL');
      expect(live().isOpen, isFalse);
    });

    test('a smartcard command gets five seconds', () async {
      final store = _Store();
      final device = FakeKey(applets: [store]).device(kinds: _nfc);
      await start(devices: [device]);
      final card = await live().selectApplication(store.aid);
      final start0 = phone.now();
      device.silent = true;

      await expectLater(card.transmit(ApduCommand(ins: 0xca, le: 256)), throwsA(isA<SecurityKeyTimeout>()));
      expect(phone.now().difference(start0), KeyLimits.apdu);
    });

    for (final kinds in [_nfc, _hid]) {
      test('a key that keeps reporting it is working is waited for past the short limit, over ${kinds.single.name}', () async {
        final echo = _Echo()..keepalives = List.filled(30, 1);
        final key = FakeKey(ctap: echo, keepaliveEvery: const Duration(seconds: 1));
        await start(devices: [key.device(kinds: kinds)]);
        final fido = await live().openFido();
        final start0 = phone.now();

        final answer = await fido.send(4);

        expect(answer.status, 0);
        expect(phone.now().difference(start0), const Duration(seconds: 30));
      });

      test('keep-alives extend the wait to the maximum and no further, over ${kinds.single.name}', () async {
        final echo = _Echo()..hangs = 1;
        final key = FakeKey(ctap: echo, keepaliveEvery: const Duration(seconds: 1));
        await start(devices: [key.device(kinds: kinds)]);
        final fido = await live().openFido();
        final start0 = phone.now();

        await expectLater(fido.send(4), throwsA(isA<SecurityKeyTimeout>()));

        expect(phone.now().difference(start0), KeyLimits.longest);
        expect(live().isOpen, isFalse);
      });
    }
  });

  for (final kinds in [_nfc, _hid]) {
    test('says when the key waits for a touch, and stops when it answers, over ${kinds.single.name}', () async {
      final echo = _Echo()..keepalives = [1, 2, 2];
      await start(
        devices: [FakeKey(ctap: echo).device(kinds: kinds)],
      );
      final touches = <bool>[];
      live().onTouchNeeded = touches.add;
      final fido = await live().openFido();

      await fido.send(7);
      expect(touches, [true, false]);

      echo.keepalives = [1];
      await fido.send(4);
      expect(touches, [true, false], reason: 'a key that is only working asks for no touch');
    });
  }

  group('a key taken away', () {
    test('while idle ends the session and tells the screen', () async {
      final device = FakeKey(ctap: _Echo(), productName: 'Example Key').device(kinds: _usb);
      await start(devices: [device]);
      final connection = live();
      await connection.openFido();
      changes = 0;

      phone.remove(device);
      await pumpEventQueue();

      expect(hub.live, isNull);
      expect(connection.isOpen, isFalse);
      expect(connection.wasRemoved, isTrue);
      expect(changes, greaterThan(0));
    });

    test('while a list is being read fails the read, with nothing partial', () async {
      final echo = _Echo();
      final device = FakeKey(ctap: echo).device(kinds: _nfc);
      await start(devices: [device]);
      final fido = await live().openFido();
      var read = 0;
      phone.removeWhen = (frame) => frame[1] == 0x10 && ++read == 3;

      Future<List<int>> list() async => [
        for (var i = 0; i < 5; i++) (await fido.send(0x0a, {1: i})).map[1]! as int,
      ];

      await expectLater(list(), throwsA(isA<SecurityKeyRemoved>()));
      await pumpEventQueue();
      expect(hub.live, isNull);
      expect(echo.commands, hasLength(2), reason: 'the key never saw the third request');
    });

    test('before answering a change leaves the app not knowing, and the next connection reads the key again', () async {
      final echo = _Echo();
      final key = FakeKey(ctap: echo);
      final device = key.device(kinds: _hid);
      await start(devices: [device]);
      final fido = await live().openFido();
      phone
        ..removeWhen = ((frame) => frame[4] == 0x90 && frame[7] == 0x0a)
        ..removeAfterProcessing = true;

      await expectLater(fido.send(0x0a, {1: 6}), throwsA(isA<SecurityKeyRemoved>()));
      await pumpEventQueue();

      expect(echo.commands, [0x0a], reason: 'the key did act on the request');
      expect(hub.live, isNull);

      phone
        ..removeWhen = null
        ..arrive(key.device(kinds: _hid));
      await pumpEventQueue();
      expect((await (await live().openFido()).send(4)).status, 0);
    });
  });

  group('cancelling', () {
    test('a touch that is waited for tells the key to stop over HID, with no error but "cancelled"', () async {
      final echo = _Echo()..hangs = 2;
      await start(
        devices: [FakeKey(ctap: echo).device(kinds: _hid)],
      );
      final fido = await live().openFido();
      live().onTouchNeeded = (needed) {
        if (needed) unawaited(hub.cancel());
      };

      await expectLater(fido.send(7), throwsA(isA<SecurityKeyCancelled>()));

      expect(echo.cancels, 1);
      expect(phone.sent.last.bytes[4], 0x91, reason: 'CTAPHID_CANCEL');
      expect(live().isOpen, isTrue, reason: 'a plugged-in key stays connected');
      echo.hangs = null;
      expect((await fido.send(4)).status, 0);
    });

    test('over NFC closes the link', () async {
      final echo = _Echo()..hangs = 2;
      await start(
        devices: [FakeKey(ctap: echo).device(kinds: _nfc)],
      );
      final connection = live();
      final fido = await connection.openFido();
      connection.onTouchNeeded = (needed) {
        if (needed) unawaited(hub.cancel());
      };

      await expectLater(fido.send(7), throwsA(isA<SecurityKeyCancelled>()));

      expect(connection.isOpen, isFalse);
      expect(phone.calls.last, startsWith('close'));
    });

    test('the wait for a key ends it and leaves everything as it was', () async {
      await start();

      final cancelled = expectLater(hub.runOnKey((connection) async => 1), throwsA(isA<SecurityKeyCancelled>()));
      await pumpEventQueue();
      expect(hub.isWaiting, isTrue);
      await hub.cancel();

      await cancelled;
      expect(hub.isWaiting, isFalse);
      expect(hub.live, isNull);
      expect(phone.sent, isEmpty);
    });

    test('by closing the iPhone’s NFC sheet ends the request as cancelled', () async {
      await start(capabilities: FakeSecurityKeys.iphone);
      phone.cancelNextNfcSheet = true;

      await expectLater(hub.runOnKey((connection) async => 1, nfcMessage: 'Hold your key'), throwsA(isA<SecurityKeyCancelled>()));

      expect(hub.nfcSheetUp, isFalse);
      expect(holds, ['hold', 'release']);
    });
  });

  group('finding a key', () {
    test('nothing is looked for while no screen waits', () async {
      phone = FakeSecurityKeys();
      phone.arrive(FakeKey(ctap: _Echo()).device(kinds: _nfc));
      await pumpEventQueue();

      expect(phone.isWatching, isFalse);
      expect(phone.calls, isEmpty);
      expect(phone.sent, isEmpty);
    });

    test('a key held to an Android phone is found and stays connected while it is there', () async {
      await start();
      expect(phone.isWatching, isTrue);
      final device = FakeKey(ctap: _Echo()).device(kinds: _nfc);

      phone.arrive(device);
      await pumpEventQueue();
      expect(await hub.runOnKey((connection) async => (await (await connection.openFido()).send(4)).status), 0);
      expect(hub.live, isNotNull);
      expect(phone.calls.where((call) => call.startsWith('beginNfc')), isEmpty);

      phone.remove(device);
      await pumpEventQueue();
      expect(hub.live, isNull);
    });

    test('a plugged-in key is found once the system’s question is allowed, under an auto-lock hold', () async {
      final gate = Completer<void>();
      phone = FakeSecurityKeys()..permissionWaits = gate.future;
      holds = [];
      hub = SecurityKeyHub(
        phone,
        now: phone.now,
        hold: () {
          holds.add('hold');
          return () => holds.add('release');
        },
      );
      addTearDown(() => hub.stop());
      await hub.start();
      phone.arrive(FakeKey(ctap: _Echo(), productName: 'Example Key').device(kinds: _usb));
      await pumpEventQueue();

      expect(holds, ['hold']);
      expect(hub.askingPermission, isTrue);
      expect(hub.live, isNull);
      gate.complete();
      await pumpEventQueue();

      expect(holds, ['hold', 'release']);
      expect(hub.live!.device.productName, 'Example Key');
      expect(hub.live!.device.links, hasLength(2));
    });

    test('a refused question is said, and asking again can be allowed', () async {
      await start();
      phone.refusePermission = true;
      phone.arrive(FakeKey(ctap: _Echo()).device(kinds: _usb));
      await pumpEventQueue();

      expect(hub.denied, isNotNull);
      expect(hub.live, isNull);
      expect(holds, ['hold', 'release']);

      phone.refusePermission = false;
      await hub.askAgain();
      expect(hub.denied, isNull);
      expect(hub.live, isNotNull);
      expect(holds, ['hold', 'release', 'hold', 'release']);
    });

    test('a USB device that turns out not to be a key is not offered', () async {
      await start();
      phone.arrive(FakeDevice(id: 'usb:9', productName: 'Gamepad', links: const {}, needsPermission: true));
      await pumpEventQueue();

      expect(hub.live, isNull);
      expect(hub.denied, isNull);
      expect(hub.choices, isEmpty);
    });

    test('with two keys plugged in the person is asked which, and none is picked silently', () async {
      final first = FakeKey(ctap: _Echo(), productName: 'First Key').device(kinds: _usb);
      final second = FakeKey(ctap: _Echo(), productName: 'Second Key').device(kinds: _usb);
      await start(devices: [first, second]);

      expect(hub.live, isNull);
      expect([for (final device in hub.choices) device.productName], ['First Key', 'Second Key']);
      expect(phone.calls.where((call) => call.startsWith('requestPermission')), isEmpty);

      await hub.pick(hub.choices[1]);
      expect(hub.choices, isEmpty);
      expect(hub.live!.device.productName, 'Second Key');
    });

    test('on an iPhone the key is asked for last, under the system’s sheet, and let go after the action', () async {
      await start(capabilities: FakeSecurityKeys.iphone);
      phone.arrive(FakeKey(ctap: _Echo()).device(kinds: _nfc));
      await pumpEventQueue();
      expect(phone.calls.where((call) => call.startsWith('beginNfc')), isEmpty, reason: 'no read before an action asks for one');

      final status = await hub.runOnKey((connection) async {
        expect(phone.nfcSheetUp, isTrue);
        expect(holds, ['hold']);
        return (await (await connection.openFido()).send(4)).status;
      }, nfcMessage: 'Hold your key to the top of the iPhone');
      await pumpEventQueue();

      expect(status, 0);
      expect(phone.calls.where((call) => call.contains('Nfc')), ['beginNfc Hold your key to the top of the iPhone', 'endNfc']);
      expect(phone.nfcSheetUp, isFalse);
      expect(hub.live, isNull);
      expect(holds, ['hold', 'release']);
    });

    test('on an iPhone a failed action ends the sheet with its error text', () async {
      await start(capabilities: FakeSecurityKeys.iphone);
      phone.arrive(FakeKey(fido: false).device(kinds: _nfc));

      await expectLater(
        hub.runOnKey((connection) => connection.openFido(), nfcMessage: 'Hold your key', nfcFailure: 'That did not work'),
        throwsA(isA<FidoUnavailable>()),
      );

      expect(phone.calls.last, 'endNfc That did not work');
      expect(holds, ['hold', 'release']);
    });

    test('on an iPhone a plugged-in key is used as it is, and a key is asked for over NFC for what only NFC carries', () async {
      final key = FakeKey(ctap: _Echo(), productName: 'Example Key');
      await start(
        capabilities: FakeSecurityKeys.iphone,
        devices: [
          key.device(kinds: {SecurityKeyLinkKind.smartcard}),
        ],
      );
      expect(live().device.productName, 'Example Key');
      await expectLater(hub.runOnKey((connection) => connection.openFido()), throwsA(isA<FidoUnavailable>()));
      expect(phone.calls.where((call) => call.startsWith('beginNfc')), isEmpty);

      phone.arrive(key.device(kinds: _nfc));
      final kind = await hub.runOnKey((connection) async => (await connection.openFido()).kind, nfcMessage: 'Hold your key', viaNfc: true);

      expect(kind, SecurityKeyLinkKind.nfc);
    });

    test('an iPhone’s NFC session that runs out is a time-out', () async {
      await start(capabilities: FakeSecurityKeys.iphone);

      final waiting = hub.runOnKey((connection) async => 1, nfcMessage: 'Hold your key');
      await pumpEventQueue();
      phone.expireNfcSession();

      await expectLater(waiting, throwsA(isA<SecurityKeyTimeout>()));
      expect(holds, ['hold', 'release']);
    });

    test('a phone that can reach no key says so in place of waiting', () async {
      await start(capabilities: SecurityKeyCapabilities.none);
      await expectLater(hub.runOnKey((connection) async => 1), throwsA(isA<SecurityKeyUnavailable>()));

      await start(capabilities: const SecurityKeyCapabilities(nfc: true));
      await expectLater(hub.runOnKey((connection) async => 1), throwsA(isA<SecurityKeyNfcOff>()));

      await start(capabilities: FakeSecurityKeys.ipad);
      await expectLater(hub.runOnKey((connection) async => 1, viaNfc: true), throwsA(isA<SecurityKeyUnavailable>()));
    });

    test('stopping closes the session with the key and stops the search', () async {
      await start(
        devices: [FakeKey(ctap: _Echo()).device(kinds: _hid)],
      );
      final connection = live();
      await connection.openFido();
      expect(phone.openLinks, isNotEmpty);

      await hub.stop();

      expect(connection.isOpen, isFalse);
      expect(phone.openLinks, isEmpty);
      expect(phone.isWatching, isFalse);
      expect(hub.live, isNull);
    });
  });

  test('runOnKey finds a key, runs the action and lets everything go', () async {
    phone = FakeSecurityKeys();
    phone.arrive(FakeKey(ctap: _Echo()).device(kinds: _hid));

    final status = await runOnKey(phone, (connection) async => (await (await connection.openFido()).send(4)).status, now: phone.now);

    expect(status, 0);
    expect(phone.isWatching, isFalse);
    expect(phone.openLinks, isEmpty);
  });

  test('runOnKey asks which key to use when there are several', () async {
    phone = FakeSecurityKeys()
      ..arrive(FakeKey(ctap: _Echo(), productName: 'First Key').device(kinds: _hid))
      ..arrive(FakeKey(ctap: _Echo(), productName: 'Second Key').device(kinds: _hid));

    final name = await runOnKey(
      phone,
      (connection) async => connection.device.productName,
      now: phone.now,
      choose: (present) async => present.firstWhere((device) => device.productName == 'Second Key'),
    );

    expect(name, 'Second Key');
  });
}
