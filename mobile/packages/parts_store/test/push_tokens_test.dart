import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/push_tokens.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

const _channel = MethodChannel('com.kemlock.app/push');

/// The native side calls Dart with a nudge, as APNs' handler does.
Future<void> _nudge(Object? arguments) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall('nudge', arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage('com.kemlock.app/push', message, (_) {});
}

void _answer(Future<Object?> Function(MethodCall call) handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, handler);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  group('on Android, where there is no push (no Firebase), as in the free build', () {
    test('says it has no push, gives no token and has no nudges', () async {
      final push = ChannelPushTokens(platform: TargetPlatform.android);

      expect(push.available, isFalse);
      expect(await push.pushToken(), isNull);
      expect(await push.onMessage.isEmpty, isTrue);
    });

    test('never asks the native side for anything, even when it has a token to give', () async {
      final asked = <String>[];
      _answer((call) async {
        asked.add(call.method);
        return 'token-1';
      });
      final push = ChannelPushTokens(platform: TargetPlatform.android);

      expect(await push.pushToken(), isNull);
      expect(push.available, isFalse);
      expect(asked, isEmpty);
    });

    test('is the build the test runs as when no platform is given', () async {
      expect(defaultTargetPlatform, TargetPlatform.android);
      final push = ChannelPushTokens();

      expect(push.available, isFalse);
      expect(await push.pushToken(), isNull);
    });

    test('has no push on any platform but iOS', () async {
      for (final platform in TargetPlatform.values.where((platform) => platform != TargetPlatform.iOS)) {
        final push = ChannelPushTokens(platform: platform);

        expect(push.available, isFalse, reason: '$platform');
        expect(await push.pushToken(), isNull, reason: '$platform');
      }
    });
  });

  group('on iOS, where push is APNs', () {
    test('can receive push', () {
      expect(ChannelPushTokens(platform: TargetPlatform.iOS).available, isTrue);
    });

    test('has no distributor to choose, and is ready as it is', () async {
      final push = ChannelPushTokens(platform: TargetPlatform.iOS);

      expect(push.choosesDistributor, isFalse);
      expect((await push.distributors()).installed, isEmpty);
      expect(await push.start(), isTrue);
      expect(await push.change(), isFalse);
      expect(await push.onTokenChanged.isEmpty, isTrue);
      await push.stop();
    });

    test('gives the token the native side has', () async {
      _answer((call) async => call.method == 'token' ? 'token-1' : null);
      final push = ChannelPushTokens(platform: TargetPlatform.iOS);

      expect(await push.pushToken(), (kind: pushKindApns, token: 'token-1'));
      expect(push.available, isTrue);
    });

    test('has no token where there is no native side, or it has none to give', () async {
      expect(await ChannelPushTokens(platform: TargetPlatform.iOS).pushToken(), isNull);
      _answer((call) async => '');
      expect(await ChannelPushTokens(platform: TargetPlatform.iOS).pushToken(), isNull);
      _answer((call) async => throw PlatformException(code: 'denied'));
      expect(await ChannelPushTokens(platform: TargetPlatform.iOS).pushToken(), isNull);
    });

    test('turns each nudge into its type, and drops one of a type it does not know', () async {
      final push = ChannelPushTokens(platform: TargetPlatform.iOS);
      final got = <PushNudge>[];
      final subscription = push.onMessage.listen(got.add);

      await _nudge('sync');
      await _nudge({'type': 'approval'});
      await _nudge('something-else');
      await _nudge(null);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(got, [PushNudge.sync, PushNudge.approval]);
    });
  });
}
