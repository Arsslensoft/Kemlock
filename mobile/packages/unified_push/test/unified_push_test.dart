import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_push/unified_push.dart';

const _channel = MethodChannel('com.kemlock.app/unified_push');

void _answer(Future<Object?> Function(MethodCall call) handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, handler);

/// The native side calls Dart, as the service does.
Future<void> _heard(String method, [Object? arguments]) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage('com.kemlock.app/unified_push', message, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  group('distributors', () {
    test('lists the ones installed by name, and the one in use', () async {
      _answer(
        (call) async => {
          'installed': [
            {'id': 'io.heckel.ntfy', 'name': 'ntfy'},
            {'id': 'org.unifiedpush.distributor.nextpush', 'name': 'NextPush'},
          ],
          'inUse': 'io.heckel.ntfy',
        },
      );

      final got = await UnifiedPushChannel().distributors();

      expect(got.installed.map((d) => d.name), ['ntfy', 'NextPush']);
      expect(got.installed.first.id, 'io.heckel.ntfy');
      expect(got.inUse, 'io.heckel.ntfy');
    });

    test('names a distributor by its id when the phone gave no name, and skips an entry with no id', () async {
      _answer(
        (call) async => {
          'installed': [
            {'id': 'a.b'},
            {'name': 'nameless'},
            'junk',
          ],
        },
      );

      final got = await UnifiedPushChannel().distributors();

      expect(got.installed, [const UnifiedPushDistributor(id: 'a.b', name: 'a.b')]);
      expect(got.inUse, isNull);
    });

    test('has none where there is no plugin or it fails', () async {
      expect((await UnifiedPushChannel().distributors()).installed, isEmpty);
      _answer((call) async => throw PlatformException(code: 'noContext'));
      expect((await UnifiedPushChannel().distributors()).installed, isEmpty);
    });
  });

  group('endpoint', () {
    test('gives the endpoint the native side holds', () async {
      _answer((call) async => call.method == 'endpoint' ? 'https://ntfy.example/up1' : null);

      expect(await UnifiedPushChannel().endpoint(), 'https://ntfy.example/up1');
    });

    test('is null when there is none, an empty one, or no plugin', () async {
      expect(await UnifiedPushChannel().endpoint(), isNull);
      _answer((call) async => '');
      expect(await UnifiedPushChannel().endpoint(), isNull);
      _answer((call) async => throw PlatformException(code: 'x'));
      expect(await UnifiedPushChannel().endpoint(), isNull);
    });
  });

  group('choosing', () {
    test('start and change answer whether a distributor is in use now', () async {
      final asked = <String>[];
      _answer((call) async {
        asked.add(call.method);
        return call.method == 'start';
      });
      final push = UnifiedPushChannel();

      expect(await push.start(), isTrue);
      expect(await push.change(), isFalse);
      expect(asked, ['start', 'change']);
    });

    test('is false when no screen is there to ask on, or no plugin', () async {
      expect(await UnifiedPushChannel().start(), isFalse);
      _answer((call) async => throw PlatformException(code: 'noActivity'));
      expect(await UnifiedPushChannel().start(), isFalse);
      expect(await UnifiedPushChannel().change(), isFalse);
    });

    test('stop asks the native side, and goes quietly where there is none', () async {
      final asked = <String>[];
      _answer((call) async {
        asked.add(call.method);
        return null;
      });
      await UnifiedPushChannel().stop();
      expect(asked, ['stop']);

      _answer((call) async => throw PlatformException(code: 'x'));
      await UnifiedPushChannel().stop();
    });
  });

  test('turns what the service heard into events', () async {
    final push = UnifiedPushChannel();
    final got = <UnifiedPushEvent>[];
    final subscription = push.events.listen(got.add);

    await _heard('endpoint');
    await _heard('message');
    await _heard('failed', 'NETWORK');
    await _heard('failed');
    await _heard('unregistered');
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(got.map((event) => event.runtimeType), [
      UnifiedPushEndpointChanged,
      UnifiedPushMessage,
      UnifiedPushRegistrationFailed,
      UnifiedPushRegistrationFailed,
      UnifiedPushUnregistered,
    ]);
    expect((got[2] as UnifiedPushRegistrationFailed).reason, 'NETWORK');
    expect((got[3] as UnifiedPushRegistrationFailed).reason, 'INTERNAL_ERROR');
  });
}
