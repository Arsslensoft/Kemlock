import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/no_push.dart';

void main() {
  test('the free build has no push: no token, no nudges, and nothing to register', () async {
    const push = NoPushTokens();

    expect(push.available, isFalse);
    expect(await push.token(), isNull);
    expect(await push.onMessage.isEmpty, isTrue);
  });
}
