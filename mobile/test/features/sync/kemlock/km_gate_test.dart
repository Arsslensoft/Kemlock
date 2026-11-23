// Every Kemlock Server request passes the offline-mode gate (openspec:
// add-offline-mode), through the client the app hands the API.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/vault/vault_registry.dart';

final _server = Uri.parse('https://kem.example.com');

({ProviderContainer container, List<String?> made, List<http.Request> sent}) _container({required bool offline}) {
  final kv = KeyValueStore.memory();
  if (offline) kv.setItem(keyOffline, jsonEncode({'on': true}));
  final made = <String?>[];
  final sent = <http.Request>[];
  final container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      vwPlainClientFactoryProvider.overrideWithValue((pin) {
        made.add(pin);
        return MockClient((request) async {
          sent.add(request);
          return http.Response(
            jsonEncode({
              'server': 'kemlock-server',
              'apiVersions': ['v1'],
            }),
            200,
          );
        });
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, made: made, sent: sent);
}

void main() {
  test('while offline mode is on, no request is made and no client is opened', () async {
    final s = _container(offline: true);
    final client = s.container.read(kemlockClientFactoryProvider)(null);

    await expectLater(KmApi(client).config(_server), throwsA(isA<KmError>().having((e) => e.problem, 'problem', KmProblem.network)));

    expect(s.made, isEmpty);
    expect(s.sent, isEmpty);
  });

  test('with offline mode off the request goes through, with the certificate pin the server was set up with', () async {
    final s = _container(offline: false);
    final client = s.container.read(kemlockClientFactoryProvider)('AA:BB');

    await KmApi(client).config(_server);

    expect(s.made, ['AA:BB']);
    expect(s.sent, hasLength(1));
  });

  test('turning offline mode on stops the next request of a client already made', () async {
    final kv = KeyValueStore.memory();
    final container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        vwPlainClientFactoryProvider.overrideWithValue(
          (pin) => MockClient(
            (_) async => http.Response(
              jsonEncode({
                'server': 'kemlock-server',
                'apiVersions': ['v1'],
              }),
              200,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final api = KmApi(container.read(kemlockClientFactoryProvider)(null));
    await api.config(_server);

    kv.setItem(keyOffline, jsonEncode({'on': true}));

    await expectLater(api.config(_server), throwsA(isA<KmError>().having((e) => e.problem, 'problem', KmProblem.network)));
  });
}
