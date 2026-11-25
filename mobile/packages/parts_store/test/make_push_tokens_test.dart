import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/push_tokens.dart';
import 'package:unified_push/unified_push_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the store build gets UnifiedPush on Android', () {
    final push = makePushTokens(platform: TargetPlatform.android);

    expect(push, isA<UnifiedPushTokens>());
    expect(push.available, isTrue);
    expect(push.choosesDistributor, isTrue);
  });

  test('keeps APNs on iOS, and has no push elsewhere', () {
    expect(makePushTokens(platform: TargetPlatform.iOS), isA<ChannelPushTokens>());
    expect(makePushTokens(platform: TargetPlatform.iOS).available, isTrue);
    for (final platform in [TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.fuchsia]) {
      expect(makePushTokens(platform: platform).available, isFalse, reason: '$platform');
    }
  });

  test('is UnifiedPush when no platform is given, as the tests run as Android', () {
    expect(defaultTargetPlatform, TargetPlatform.android);
    expect(makePushTokens(), isA<UnifiedPushTokens>());
  });
}
