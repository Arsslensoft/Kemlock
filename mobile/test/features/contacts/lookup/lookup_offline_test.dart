import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/contacts/lookup/lookup_http.dart';
import 'package:kemlock/platform/network.dart';

/// The lookup's client and name resolver behind offline mode's gate (openspec: add-key-lookup, decision 5): the
/// gate covers HTTP clients, and the resolver passes the same gate itself.
void main() {
  late ProviderContainer container;
  late List<Uri> requested;
  late List<String> resolved;

  setUp(() {
    requested = [];
    resolved = [];
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(KeyValueStore.memory()),
        plainClientProvider.overrideWithValue(
          () => MockClient((request) async {
            requested.add(request.url);
            return http.Response('', 404);
          }),
        ),
        plainHostResolverProvider.overrideWithValue((host) async {
          resolved.add(host);
          return true;
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  final url = Uri.parse('https://openpgpkey.example.org/.well-known/openpgpkey/example.org/hu/abc?l=grace');

  test('with offline mode on, neither a request nor a name resolution leaves the phone', () async {
    container.read(offlineProvider.notifier).set(true);

    await expectLater(container.read(keyLookupClientProvider).get(url), throwsA(isA<OfflineException>()));
    await expectLater(container.read(hostResolverProvider)('openpgpkey.example.org'), throwsA(isA<OfflineException>()));
    await expectLater(lookupGet(container.read(keyLookupClientProvider), url, accept: 'x'), throwsA(isA<LookupException>()));

    expect(requested, isEmpty);
    expect(resolved, isEmpty);
  });

  test('with offline mode off, both go through', () async {
    final response = await container.read(keyLookupClientProvider).get(url);
    final resolves = await container.read(hostResolverProvider)('openpgpkey.example.org');

    expect((response.statusCode, resolves), (404, true));
    expect(requested, [url]);
    expect(resolved, ['openpgpkey.example.org']);
  });

  test('the switch counts from the moment it is turned on', () async {
    final client = container.read(keyLookupClientProvider);
    final resolve = container.read(hostResolverProvider);
    await resolve('openpgpkey.example.org');

    container.read(offlineProvider.notifier).set(true);

    await expectLater(resolve('example.org'), throwsA(isA<OfflineException>()));
    await expectLater(client.get(url), throwsA(isA<OfflineException>()));
    expect(resolved, ['openpgpkey.example.org']);
    expect(requested, isEmpty);
  });
}
