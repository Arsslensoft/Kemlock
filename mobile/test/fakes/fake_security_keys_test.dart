import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';

import 'fake_security_keys.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

const _second = Duration(seconds: 1);

void main() {
  FakeDevice nfcKey(ScriptedLink link) => FakeDevice(id: 'nfc:1', links: {SecurityKeyLinkKind.nfc: link});
  FakeDevice usbKey(ScriptedLink hid, [ScriptedLink? ccid]) =>
      FakeDevice(id: 'usb:7', productName: 'Example Key', links: {SecurityKeyLinkKind.usbHid: hid, SecurityKeyLinkKind.usbCcid: ?ccid});

  test('stands in for the phone through the provider, with the capabilities the test sets', () async {
    final phone = FakeSecurityKeys(phone: FakeSecurityKeys.ipad);
    final container = ProviderContainer(overrides: [phone.asOverride]);
    addTearDown(container.dispose);

    final capabilities = await container.read(securityKeysProvider).capabilities();
    expect(capabilities.nfc, isFalse);
    expect(capabilities.smartcards, isTrue);

    phone.phone = SecurityKeyCapabilities.none;
    expect((await phone.capabilities()).any, isFalse);
  });

  test('scripts a link of each kind and records every frame sent, in order', () async {
    final phone = FakeSecurityKeys();
    final nfc = ScriptedLink(extendedLength: false)
      ..reply([0x90, 0x00])
      ..reply([0x6a, 0x82]);
    final hid = ScriptedLink(frameSize: 64)
      ..frames([
        [1, 2],
      ])
      ..frames([
        [3],
        [4],
      ]);
    final ccid = ScriptedLink(frameSize: 3072);
    final events = <SecurityKeyEvent>[];
    final subscription = phone.watch().listen(events.add);
    phone.arrive(nfcKey(nfc));
    phone.arrive(usbKey(hid, ccid));
    await pumpEventQueue();

    final found = [for (final event in events) (event as SecurityKeyArrived).device];
    expect(found[0].id, 'nfc:1');
    expect(found[0].link(SecurityKeyLinkKind.nfc)!.extendedLength, isFalse);
    expect(found[1].needsPermission, isTrue);
    expect(found[1].links, isEmpty, reason: 'a USB key says nothing of itself before the system’s question');
    expect(found[1].productName, 'Example Key');
    expect((await phone.present()).map((device) => device.id), ['usb:7'], reason: 'only plugged-in keys are present before a read');

    final links = await phone.requestPermission('usb:7');
    expect([for (final link in links) '${link.id} ${link.frameSize}'], ['usb:7:usbHid 64', 'usb:7:usbCcid 3072']);
    expect((await phone.present()).single.links, hasLength(2));

    await phone.open('nfc:1:nfc');
    expect(await phone.transceive('nfc:1:nfc', _bytes([0, 0xa4, 4, 0]), timeout: _second), [0x90, 0x00]);
    await phone.write('usb:7:usbHid', [
      _bytes([9]),
      _bytes([8]),
    ]);
    expect(await phone.transceive('nfc:1:nfc', _bytes([0, 0xb0]), timeout: _second), [0x6a, 0x82]);
    await phone.write('usb:7:usbCcid', [
      _bytes([0x62]),
    ]);
    expect(await phone.read('usb:7:usbHid', _second), [
      [1, 2],
    ]);
    expect(await phone.read('usb:7:usbHid', _second), [
      [3],
      [4],
    ]);
    await phone.close('nfc:1:nfc');

    expect(
      [for (final frame in phone.sent) '$frame'],
      ['nfc:1:nfc 00a40400', 'usb:7:usbHid 09', 'usb:7:usbHid 08', 'nfc:1:nfc 00b0', 'usb:7:usbCcid 62'],
    );
    expect(phone.calls, ['watch', 'present', 'requestPermission usb:7', 'present', 'open nfc:1:nfc', 'close nfc:1:nfc']);
    await subscription.cancel();
    expect(phone.calls.last, 'stopWatch');
  });

  test('a key taken away mid-exchange is the removed error, and the watch stream says it left', () async {
    final phone = FakeSecurityKeys();
    final events = <SecurityKeyEvent>[];
    final subscription = phone.watch().listen(events.add);
    addTearDown(subscription.cancel);
    final link = ScriptedLink()..reply([0x90, 0x00]);
    phone.arrive(nfcKey(link));
    phone.removeWhen = (frame) => frame[1] == 0xb0;

    expect(await phone.transceive('nfc:1:nfc', _bytes([0, 0xa4]), timeout: _second), [0x90, 0x00]);
    await expectLater(phone.transceive('nfc:1:nfc', _bytes([0, 0xb0]), timeout: _second), throwsA(isA<SecurityKeyRemoved>()));
    await expectLater(phone.transceive('nfc:1:nfc', _bytes([0, 0xa4]), timeout: _second), throwsA(isA<SecurityKeyRemoved>()));
    await expectLater(phone.open('nfc:1:nfc'), throwsA(isA<SecurityKeyRemoved>()));
    await pumpEventQueue();

    expect(events.last, isA<SecurityKeyLeft>().having((e) => e.deviceId, 'device', 'nfc:1'));
    expect(phone.sent, hasLength(3), reason: 'frames to a key that is gone are still recorded');
  });

  test('a key that leaves after acting on a frame keeps the app from hearing the answer', () async {
    final phone = FakeSecurityKeys();
    final hid = ScriptedLink(frameSize: 64);
    phone.arrive(usbKey(hid));
    phone
      ..removeWhen = ((frame) => frame[0] == 2)
      ..removeAfterProcessing = true;

    await phone.write('usb:7:usbHid', [
      _bytes([1]),
    ]);
    await expectLater(
      phone.write('usb:7:usbHid', [
        _bytes([2]),
        _bytes([3]),
      ]),
      throwsA(isA<SecurityKeyRemoved>()),
    );
    await expectLater(phone.read('usb:7:usbHid', _second), throwsA(isA<SecurityKeyRemoved>()));
    expect([for (final frame in phone.sent) frame.hex], ['01', '02']);
  });

  test('a key that goes silent is the timeout error, after the time limit has passed on the fake clock', () async {
    final phone = FakeSecurityKeys();
    final nfc = nfcKey(ScriptedLink()..reply([0x90, 0x00]));
    final usb = usbKey(
      ScriptedLink()..frames([
        [1],
      ]),
    );
    phone
      ..arrive(nfc)
      ..arrive(usb);
    final start = phone.now();
    nfc.silent = true;
    usb.silent = true;

    await expectLater(phone.transceive('nfc:1:nfc', _bytes([0]), timeout: const Duration(seconds: 5)), throwsA(isA<SecurityKeyTimeout>()));
    expect(phone.now().difference(start), const Duration(seconds: 5));

    await phone.write('usb:7:usbHid', [
      _bytes([1]),
    ]);
    expect(await phone.read('usb:7:usbHid', const Duration(seconds: 10)), isEmpty);
    expect(phone.now().difference(start), const Duration(seconds: 15));

    usb.silent = false;
    expect(await phone.read('usb:7:usbHid', _second), hasLength(1));
    expect(await phone.read('usb:7:usbHid', _second), isEmpty, reason: 'a script that ran out waits like a key with nothing to say');
    expect(phone.now().difference(start), const Duration(seconds: 16));
  });

  test('a refused USB question is the denied error, and asking again can be allowed', () async {
    final phone = FakeSecurityKeys()..refusePermission = true;
    phone.arrive(usbKey(ScriptedLink()));

    await expectLater(phone.requestPermission('usb:7'), throwsA(isA<SecurityKeyDenied>()));
    expect((await phone.present()).single.needsPermission, isTrue);

    phone.refusePermission = false;
    expect(await phone.requestPermission('usb:7'), hasLength(1));
    expect((await phone.present()).single.needsPermission, isFalse);
    await expectLater(phone.requestPermission('usb:9'), throwsA(isA<SecurityKeyRemoved>()));
  });

  test('on an iPhone a key held to the phone is found only by a read, which the person can cancel', () async {
    final phone = FakeSecurityKeys(phone: FakeSecurityKeys.iphone);
    final events = <SecurityKeyEvent>[];
    final subscription = phone.watch().listen(events.add);
    addTearDown(subscription.cancel);
    final key = nfcKey(ScriptedLink()..reply([0x90, 0x00]));
    phone.arrive(key);
    await pumpEventQueue();
    expect(events, isEmpty, reason: 'nothing is read before the person starts a read');

    phone.cancelNextNfcSheet = true;
    await phone.beginNfc('Hold your key to the top of the iPhone');
    await pumpEventQueue();
    expect(events.single, isA<SecurityKeySessionEnded>().having((e) => e.error, 'error', isA<SecurityKeyCancelled>()));
    expect(phone.nfcSheetUp, isFalse);

    events.clear();
    await phone.beginNfc('Hold your key to the top of the iPhone');
    await pumpEventQueue();
    expect(events.single, isA<SecurityKeyArrived>());
    expect(phone.nfcSheetUp, isTrue);
    expect(await phone.transceive('nfc:1:nfc', _bytes([0, 0xa4]), timeout: _second), [0x90, 0x00]);

    await phone.endNfc();
    await pumpEventQueue();
    expect(events[1], isA<SecurityKeyLeft>());
    expect(events[2], isA<SecurityKeySessionEnded>().having((e) => e.error, 'error', isNull));
    await expectLater(phone.transceive('nfc:1:nfc', _bytes([0]), timeout: _second), throwsA(isA<SecurityKeyRemoved>()));

    events.clear();
    phone.arrive(key);
    await phone.beginNfc('Again');
    await pumpEventQueue();
    phone.expireNfcSession();
    await pumpEventQueue();
    expect(events.last, isA<SecurityKeySessionEnded>().having((e) => e.error, 'error', isA<SecurityKeyTimeout>()));
    expect(phone.calls.where((call) => call.startsWith('beginNfc')), hasLength(3));
  });

  test('an iPad cannot start an NFC read', () async {
    final phone = FakeSecurityKeys(phone: FakeSecurityKeys.ipad);

    await expectLater(phone.beginNfc('Hold your key'), throwsA(isA<SecurityKeyUnavailable>()));
  });
}
