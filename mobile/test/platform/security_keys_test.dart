import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';

const _channel = MethodChannel('com.kemlock.app/security_keys');
const _events = EventChannel('com.kemlock.app/security_keys/events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  /// Answers the method channel with [answer], recording each call.
  void answer(Future<Object?> Function(MethodCall call) answer) {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return answer(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  }

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  test('reads what the phone can reach a key with', () async {
    answer((_) async => {'nfc': true, 'nfcOn': false, 'usb': true, 'smartcards': false, 'readsOnRequest': false});

    final capabilities = await ChannelSecurityKeys().capabilities();

    expect(
      [capabilities.nfc, capabilities.nfcOn, capabilities.usb, capabilities.smartcards, capabilities.readsOnRequest],
      [true, false, true, false, false],
    );
    expect(capabilities.any, isTrue);
    expect(capabilities.plugsIn, isTrue);
  });

  test('hands each call over with its arguments and reads the answers', () async {
    answer(
      (call) async => switch (call.method) {
        'present' => [
          {'device': 'usb:1002', 'product': ' Example Key ', 'needsPermission': true, 'links': <Object?>[]},
          {'no': 'device'},
        ],
        'requestPermission' => [
          {'id': 'usb:1002:hid', 'kind': 'usbHid', 'frameSize': 64},
          {'id': 'usb:1002:ccid', 'kind': 'usbCcid', 'extendedLength': true, 'frameSize': 3072},
          {'id': 'usb:1002:x', 'kind': 'a kind from the future'},
        ],
        'transceive' => bytes([0x90, 0x00]),
        'read' => [
          bytes([1, 2]),
          bytes([3]),
        ],
        _ => null,
      },
    );
    final keys = ChannelSecurityKeys();

    final present = await keys.present();
    expect(present, hasLength(1));
    expect(present.single.id, 'usb:1002');
    expect(present.single.productName, 'Example Key');
    expect(present.single.needsPermission, isTrue);

    final links = await keys.requestPermission('usb:1002');
    expect(
      [for (final link in links) '${link.id} ${link.kind.name} ${link.extendedLength} ${link.frameSize}'],
      ['usb:1002:hid usbHid false 64', 'usb:1002:ccid usbCcid true 3072'],
    );

    await keys.beginNfc('Hold your key');
    await keys.setNfcMessage('Reading');
    await keys.endNfc();
    await keys.endNfc(error: 'No key');
    await keys.open('nfc:1');
    expect(await keys.transceive('nfc:1', bytes([0, 0xa4, 4, 0]), timeout: const Duration(seconds: 5)), [0x90, 0x00]);
    await keys.write('usb:1002:hid', [
      bytes([1]),
      bytes([2]),
    ]);
    expect(await keys.read('usb:1002:hid', const Duration(milliseconds: 250)), [
      [1, 2],
      [3],
    ]);
    await keys.close('nfc:1');

    expect(
      [for (final call in calls) call.method],
      ['present', 'requestPermission', 'beginNfc', 'setNfcMessage', 'endNfc', 'endNfc', 'open', 'transceive', 'write', 'read', 'close'],
    );
    expect(
      [for (final call in calls.skip(1)) call.arguments],
      [
        {'device': 'usb:1002'},
        {'message': 'Hold your key'},
        {'message': 'Reading'},
        {'error': null},
        {'error': 'No key'},
        {'link': 'nfc:1'},
        {
          'link': 'nfc:1',
          'data': bytes([0, 0xa4, 4, 0]),
          'timeoutMs': 5000,
        },
        {
          'link': 'usb:1002:hid',
          'frames': [
            bytes([1]),
            bytes([2]),
          ],
        },
        {'link': 'usb:1002:hid', 'timeoutMs': 250},
        {'link': 'nfc:1'},
      ],
    );
  });

  test('maps each error code the phone sends to its error', () async {
    final cases = {
      'cancelled': isA<SecurityKeyCancelled>(),
      'unavailable': isA<SecurityKeyUnavailable>(),
      'nfcOff': isA<SecurityKeyNfcOff>(),
      'denied': isA<SecurityKeyDenied>(),
      'removed': isA<SecurityKeyRemoved>(),
      'timeout': isA<SecurityKeyTimeout>(),
      'noApplication': isA<SecurityKeyNoApplication>(),
      'notDeclared': isA<SecurityKeyNotDeclared>(),
      'failed': isA<SecurityKeyFailed>().having((e) => e.message, 'message', 'Tag was lost'),
      'something new': isA<SecurityKeyFailed>().having((e) => e.message, 'message', 'Tag was lost'),
    };
    final keys = ChannelSecurityKeys();
    for (final MapEntry(key: code, value: matcher) in cases.entries) {
      answer((_) async => throw PlatformException(code: code, message: 'Tag was lost'));

      await expectLater(keys.open('nfc:1'), throwsA(matcher), reason: code);
      await expectLater(keys.transceive('nfc:1', bytes([0]), timeout: Duration.zero), throwsA(matcher), reason: code);
      await expectLater(keys.write('usb:1:hid', const []), throwsA(matcher), reason: code);
      await expectLater(keys.read('usb:1:hid', Duration.zero), throwsA(matcher), reason: code);
      await expectLater(keys.requestPermission('usb:1'), throwsA(matcher), reason: code);
      await expectLater(keys.beginNfc('Hold your key'), throwsA(matcher), reason: code);
      await expectLater(keys.present(), throwsA(matcher), reason: code);
    }
    const errors = [
      SecurityKeyCancelled(),
      SecurityKeyUnavailable(),
      SecurityKeyNfcOff(),
      SecurityKeyDenied(),
      SecurityKeyRemoved(),
      SecurityKeyTimeout(),
      SecurityKeyNoApplication(),
      SecurityKeyNotDeclared(),
      SecurityKeyFailed(),
    ];
    for (final error in errors) {
      expect(securityKeyError(error.code).runtimeType, error.runtimeType);
    }
    expect({for (final error in errors) error.code}, hasLength(errors.length));
  });

  test('tidying up never throws, whatever the phone answers', () async {
    answer((_) async => throw PlatformException(code: 'removed'));
    final keys = ChannelSecurityKeys();

    await keys.close('nfc:1');
    await keys.endNfc();
    await keys.setNfcMessage('Reading');
    expect((await keys.capabilities()).any, isFalse);
  });

  test('reports no NFC and no USB, and never throws, without the native side', () async {
    final keys = ChannelSecurityKeys();

    final capabilities = await keys.capabilities();
    expect(capabilities.nfc, isFalse);
    expect(capabilities.usb, isFalse);
    expect(capabilities.smartcards, isFalse);
    expect(capabilities.any, isFalse);
    expect(await keys.present(), isEmpty);
    await keys.close('nfc:1');
    await keys.endNfc();
    await expectLater(keys.open('nfc:1'), throwsA(isA<SecurityKeyUnavailable>()));
    await expectLater(keys.beginNfc('Hold your key'), throwsA(isA<SecurityKeyUnavailable>()));

    final events = <SecurityKeyEvent>[];
    final subscription = keys.watch().listen(events.add);
    await pumpEventQueue();
    await subscription.cancel();
    expect(events, isEmpty);
  });

  test('tells keys arriving and leaving, and stops the native search when the stream is cancelled', () async {
    final log = <String>[];
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          log.add('listen');
          sink = events;
        },
        onCancel: (arguments) => log.add('cancel'),
      ),
    );
    addTearDown(() => messenger.setMockStreamHandler(_events, null));
    final keys = ChannelSecurityKeys();

    expect(log, isEmpty, reason: 'nothing is searched for before someone listens');
    final events = <SecurityKeyEvent>[];
    final subscription = keys.watch().listen(events.add);
    await pumpEventQueue();
    expect(log, ['listen']);

    sink!.success({
      'event': 'arrived',
      'device': 'nfc:7',
      'links': [
        {'id': 'nfc:7', 'kind': 'nfc', 'extendedLength': true},
      ],
    });
    sink!.success({'event': 'an event from the future'});
    sink!.success({'event': 'left', 'device': 'nfc:7'});
    sink!.success({'event': 'sessionEnded', 'code': 'cancelled'});
    sink!.success({'event': 'sessionEnded'});
    await pumpEventQueue();

    expect(events, hasLength(4));
    final arrived = events[0] as SecurityKeyArrived;
    expect(arrived.device.id, 'nfc:7');
    expect(arrived.device.productName, isNull);
    expect(arrived.device.isNfc, isTrue);
    expect(arrived.device.link(SecurityKeyLinkKind.nfc)!.extendedLength, isTrue);
    expect((events[1] as SecurityKeyLeft).deviceId, 'nfc:7');
    expect((events[2] as SecurityKeySessionEnded).error, isA<SecurityKeyCancelled>());
    expect((events[3] as SecurityKeySessionEnded).error, isNull);

    await subscription.cancel();
    await pumpEventQueue();
    expect(log, ['listen', 'cancel']);
  });
}
