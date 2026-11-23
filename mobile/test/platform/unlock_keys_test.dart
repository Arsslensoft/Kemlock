import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/unlock_keys.dart';

import '../fakes/fake_unlock_keys.dart';

const _channel = MethodChannel('com.kemlock.app/unlock');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  late List<MethodCall> calls;

  /// Answers the channel with [answer], recording each call.
  void answer(Future<Object?> Function(MethodCall call) answer) {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return answer(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  }

  test('asks the phone whether it has biometrics the key can use', () async {
    answer((_) async => true);
    expect(await const ChannelUnlockKeys().status(), isTrue);

    answer((_) async => throw PlatformException(code: 'failed'));
    expect(await const ChannelUnlockKeys().status(), isFalse);
  });

  test('hands the key, the vault and the prompt over, and takes the wrap and the key back', () async {
    answer((call) async => call.method == 'seal' ? 'd3JhcA==' : key);

    expect(await const ChannelUnlockKeys().seal('main', key, 'Turn it on'), 'd3JhcA==');
    expect(await const ChannelUnlockKeys().open('main', 'd3JhcA==', 'Unlock'), key);
    await const ChannelUnlockKeys().delete('0123456789ab');
    await const ChannelUnlockKeys().deleteAll();

    expect([for (final call in calls) call.method], ['seal', 'open', 'delete', 'deleteAll']);
    expect(
      [for (final call in calls) call.arguments],
      [
        {'vault': 'main', 'key': key, 'reason': 'Turn it on'},
        {'vault': 'main', 'wrap': 'd3JhcA==', 'reason': 'Unlock'},
        {'vault': '0123456789ab'},
        null,
      ],
    );
  });

  test('reads an iPhone, which keeps nothing beside the key, as an empty wrap', () async {
    answer((_) async => null);

    expect(await const ChannelUnlockKeys().seal('main', key, 'Turn it on'), '');
  });

  test('maps each error code the phone sends to its error', () async {
    final cases = {
      'cancelled': isA<UnlockKeyCancelled>(),
      'invalidated': isA<UnlockKeyInvalidated>(),
      'unavailable': isA<UnlockKeyUnavailable>(),
      'prompt': isA<UnlockKeyPromptFailed>().having((e) => e.message, 'message', 'Keystore said no'),
      'failed': isA<UnlockKeyFailed>().having((e) => e.message, 'message', 'Keystore said no'),
      'something new': isA<UnlockKeyFailed>().having((e) => e.message, 'message', 'Keystore said no'),
    };
    for (final MapEntry(key: code, value: matcher) in cases.entries) {
      answer((_) async => throw PlatformException(code: code, message: 'Keystore said no'));

      await expectLater(const ChannelUnlockKeys().seal('main', key, 'Turn it on'), throwsA(matcher), reason: code);
      await expectLater(const ChannelUnlockKeys().open('main', '', 'Unlock'), throwsA(matcher), reason: code);
    }
    for (final error in const [
      UnlockKeyCancelled(),
      UnlockKeyInvalidated(),
      UnlockKeyUnavailable(),
      UnlockKeyPromptFailed(),
      UnlockKeyFailed(),
    ]) {
      expect(unlockKeyError(error.code), isA<UnlockKeyError>().having((e) => e.runtimeType, 'type', error.runtimeType));
    }
  });

  test('refuses a key of the wrong length', () async {
    answer((_) async => Uint8List(16));

    await expectLater(const ChannelUnlockKeys().open('main', '', 'Unlock'), throwsA(isA<UnlockKeyFailed>()));
  });

  test('has no biometrics and keeps no key without the native side', () async {
    expect(await const ChannelUnlockKeys().status(), isFalse);
    await expectLater(const ChannelUnlockKeys().seal('main', key, 'Turn it on'), throwsA(isA<UnlockKeyUnavailable>()));
    await expectLater(const ChannelUnlockKeys().open('main', '', 'Unlock'), throwsA(isA<UnlockKeyUnavailable>()));
    await const ChannelUnlockKeys().delete('main');
    await const ChannelUnlockKeys().deleteAll();
  });

  test('can be replaced by a fake that cancels, invalidates and fails', () async {
    final fake = FakeUnlockKeys(android: true);
    final container = ProviderContainer(overrides: [fake.asOverride]);
    addTearDown(container.dispose);
    final keys = container.read(unlockKeysProvider);

    final wrap = await keys.seal('main', key, 'Turn it on');
    expect(wrap, isNotEmpty);
    expect(await keys.open('main', wrap, 'Unlock'), key);

    fake.cancelNext();
    await expectLater(keys.open('main', wrap, 'Unlock'), throwsA(isA<UnlockKeyCancelled>()));
    fake.failNext('Bad tag');
    await expectLater(keys.open('main', wrap, 'Unlock'), throwsA(isA<UnlockKeyFailed>()));
    fake.invalidate('main');
    await expectLater(keys.open('main', wrap, 'Unlock'), throwsA(isA<UnlockKeyInvalidated>()));

    expect(fake.prompts, ['Turn it on', 'Unlock', 'Unlock', 'Unlock', 'Unlock']);
    expect(fake.calls, ['seal main', 'open main', 'open main', 'open main', 'open main']);
  });
}
