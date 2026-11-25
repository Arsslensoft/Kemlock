import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_ports/kemlock_ports.dart';
import 'package:unified_push/unified_push.dart';
import 'package:unified_push/unified_push_tokens.dart';

const _channel = MethodChannel('com.kemlock.app/unified_push');

void _answer(Future<Object?> Function(MethodCall call) handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, handler);

/// The native side calls Dart, as the service does.
Future<void> _heard(String method, [Object? arguments]) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'com.kemlock.app/unified_push',
    message,
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  group('which endpoints the server takes', () {
    test('https on 443, written or by default, and on 8443', () {
      expect(usableEndpoint('https://ntfy.sh/upAbc123'), isTrue);
      expect(usableEndpoint('https://ntfy.example.com:443/up?x=1'), isTrue);
      expect(usableEndpoint('https://push.example.com:8443/up'), isTrue);
    });

    test('nothing else: http, another port, no host, whitespace, not a URL', () {
      expect(usableEndpoint('http://ntfy.sh/up'), isFalse);
      expect(usableEndpoint('https://ntfy.sh:8080/up'), isFalse);
      expect(usableEndpoint('https:///up'), isFalse);
      expect(usableEndpoint('https://ntfy.sh/up now'), isFalse);
      expect(usableEndpoint(''), isFalse);
      expect(usableEndpoint('::not a url::'), isFalse);
    });

    test('at most 512 characters', () {
      const start = 'https://ntfy.sh/';

      expect(usableEndpoint(start + 'a' * (512 - start.length)), isTrue);
      expect(usableEndpoint(start + 'a' * (513 - start.length)), isFalse);
    });
  });

  group('the token', () {
    test('is the endpoint, of kind unifiedpush', () async {
      _answer((call) async => call.method == 'endpoint' ? 'https://ntfy.sh/up1' : null);

      expect(await UnifiedPushTokens().pushToken(), (kind: pushKindUnifiedPush, token: 'https://ntfy.sh/up1'));
    });

    test('is null with no endpoint yet, or one the server would refuse', () async {
      expect(await UnifiedPushTokens().pushToken(), isNull);
      _answer((call) async => 'http://ntfy.sh/up1');
      expect(await UnifiedPushTokens().pushToken(), isNull);
    });
  });

  test('can receive push, and lets the person choose the distributor', () {
    final push = UnifiedPushTokens();

    expect(push.available, isTrue);
    expect(push.choosesDistributor, isTrue);
  });

  test('turns any message into a sync nudge, and a new endpoint or its loss into a changed token', () async {
    final push = UnifiedPushTokens();
    final nudges = <PushNudge>[];
    var changes = 0;
    final nudging = push.onMessage.listen(nudges.add);
    final changing = push.onTokenChanged.listen((_) => changes++);

    await _heard('message');
    await _heard('message');
    await _heard('endpoint');
    await _heard('unregistered');
    await _heard('failed', 'NETWORK');
    await Future<void>.delayed(Duration.zero);
    await nudging.cancel();
    await changing.cancel();

    expect(nudges, [PushNudge.sync, PushNudge.sync]);
    expect(changes, 2);
  });

  group('the distributors', () {
    test('are the ones installed, with the one in use', () async {
      _answer(
        (call) async => {
          'installed': [
            {'id': 'io.heckel.ntfy', 'name': 'ntfy'},
            {'id': 'org.unifiedpush.distributor.nextpush', 'name': 'NextPush'},
          ],
          'inUse': 'org.unifiedpush.distributor.nextpush',
        },
      );

      final got = await UnifiedPushTokens().distributors();

      expect(got.installed.map((one) => one.name), ['ntfy', 'NextPush']);
      expect(got.inUse, const PushDistributor(id: 'org.unifiedpush.distributor.nextpush', name: 'NextPush'));
    });

    test('have no one in use when the saved one is not installed any more', () async {
      _answer(
        (call) async => {
          'installed': [
            {'id': 'io.heckel.ntfy', 'name': 'ntfy'},
          ],
          'inUse': 'gone.distributor',
        },
      );

      expect((await UnifiedPushTokens().distributors()).inUse, isNull);
    });

    test('start, change and stop go to the native side', () async {
      final asked = <String>[];
      _answer((call) async {
        asked.add(call.method);
        return call.method != 'change';
      });
      final push = UnifiedPushTokens();

      expect(await push.start(), isTrue);
      expect(await push.change(), isFalse);
      await push.stop();
      expect(asked, ['start', 'change', 'stop']);
    });
  });
}
