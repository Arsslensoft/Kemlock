import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/no_push.dart';
import 'package:unified_push/unified_push_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the free build gets UnifiedPush on Android: free software, and no Google service', () {
    final push = makePushTokens(platform: TargetPlatform.android);

    expect(push, isA<UnifiedPushTokens>());
    expect(push.available, isTrue);
  });

  test('has no push on any other platform', () {
    for (final platform in TargetPlatform.values.where((platform) => platform != TargetPlatform.android)) {
      expect(makePushTokens(platform: platform), isA<NoPushTokens>(), reason: '$platform');
    }
  });
}
