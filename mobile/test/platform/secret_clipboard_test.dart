import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/secret_clipboard.dart';

import '../fakes/fake_clipboard.dart';

void main() {
  late List<String?> writes;
  late FakeSensitiveClipboard phone;

  setUp(() {
    writes = [];
    phone = FakeSensitiveClipboard();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
      return null;
    });
  });

  SecretClipboard clipboard(Duration? delay) => SecretClipboard(() => delay, channel: phone);

  testWidgets('copies through the phone, then clears its own copy after the delay', (tester) async {
    final secret = clipboard(const Duration(minutes: 1));

    expect(await secret.copy('123456'), isTrue);
    expect(phone.copies, [(text: '123456', seconds: 60)]);
    await tester.pump(const Duration(seconds: 59));
    expect(phone.clears, isEmpty);
    await tester.pump(const Duration(seconds: 1));

    // The token of the copy goes back, so a later copy elsewhere is left alone
    expect(phone.clears, ['copy-1']);
    expect(writes, isEmpty);
  });

  testWidgets('counts the delay from the last copy', (tester) async {
    final secret = clipboard(const Duration(seconds: 30));

    await secret.copy('111111');
    await tester.pump(const Duration(seconds: 20));
    await secret.copy('222222');
    await tester.pump(const Duration(seconds: 20));
    expect(phone.clears, isEmpty);
    await tester.pump(const Duration(seconds: 10));

    expect(phone.clears, ['copy-2']);
  });

  testWidgets('leaves the clipboard alone when the delay is never, and asks no expiry', (tester) async {
    final secret = clipboard(null);

    await secret.copy('123456');
    await tester.pump(const Duration(hours: 1));

    expect(phone.copies, [(text: '123456', seconds: null)]);
    expect(phone.clears, isEmpty);
    expect(writes, isEmpty);
  });

  testWidgets('reads the delay at each copy', (tester) async {
    var delay = const Duration(seconds: 10);
    final secret = SecretClipboard(() => delay, channel: phone);

    await secret.copy('111111');
    delay = const Duration(minutes: 2);
    await secret.copy('222222');

    expect(phone.copies.map((copy) => copy.seconds), [10, 120]);
    // flutter_test checks for timers before tear-downs run
    secret.dispose();
  });

  testWidgets('copies the ordinary way and clears blindly where the phone has no sensitive copy', (tester) async {
    phone.error = MissingPluginException();
    final secret = clipboard(const Duration(seconds: 30));

    expect(await secret.copy('123456'), isTrue);
    await tester.pump(const Duration(seconds: 29));
    expect(writes, ['123456']);
    await tester.pump(const Duration(seconds: 1));

    expect(writes, ['123456', '']);
  });

  testWidgets('clears blindly when the phone can’t say whose copy it is', (tester) async {
    final secret = clipboard(const Duration(seconds: 10));

    await secret.copy('123456');
    phone.error = PlatformException(code: 'failed');
    await tester.pump(const Duration(seconds: 10));

    expect(writes, ['']);
  });

  testWidgets('reports a copy the phone refused', (tester) async {
    phone.error = PlatformException(code: 'failed');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => throw PlatformException(code: 'denied'),
    );

    expect(await clipboard(const Duration(seconds: 30)).copy('123456'), isFalse);
  });
}
