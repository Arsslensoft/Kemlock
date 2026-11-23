import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/features/breaches/hibp.dart';
import 'package:kemlock/features/settings/app_version.dart';

void main() {
  test('requests go through the client a test puts in', () {
    final client = MockClient((_) async => http.Response('', 200));
    final container = ProviderContainer(overrides: [hibpClientProvider.overrideWithValue(client)]);
    addTearDown(container.dispose);

    expect(container.read(hibpClientProvider), same(client));
  });

  test('names the app and its version as the user agent', () async {
    final container = ProviderContainer(overrides: [appVersionProvider.overrideWith((ref) async => '1.1.0')]);
    addTearDown(container.dispose);

    expect(await container.read(hibpUserAgentProvider.future), 'Kemlock/1.1.0');
  });

  test('names the app alone when the version cannot be read', () async {
    final container = ProviderContainer(overrides: [appVersionProvider.overrideWith((ref) async => throw StateError('no plugin'))]);
    addTearDown(container.dispose);

    expect(await container.read(hibpUserAgentProvider.future), 'Kemlock');
  });
}
