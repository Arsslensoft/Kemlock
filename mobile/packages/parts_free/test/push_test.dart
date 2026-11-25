import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/no_push.dart';

void main() {
  test('the free build has no push: no token, no nudges, and nothing to register', () async {
    const push = NoPushTokens();

    expect(push.available, isFalse);
    expect(push.choosesDistributor, isFalse);
    expect(await push.pushToken(), isNull);
    expect(await push.onMessage.isEmpty, isTrue);
    expect(await push.onTokenChanged.isEmpty, isTrue);
    expect((await push.distributors()).installed, isEmpty);
    expect(await push.start(), isFalse);
    expect(await push.change(), isFalse);
    await push.stop();
  });
}
