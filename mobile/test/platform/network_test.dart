import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/breaches/pwned_passwords.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/vaultwarden/vaultwarden_sheet.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/platform/network.dart';

/// A client that counts what reaches it, and whether it was closed.
class CountingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(Stream.value('ok'.codeUnits), 200);
  }

  @override
  void close() => closed = true;
}

void main() {
  late KeyValueStore store;
  late ProviderContainer container;

  setUp(() {
    store = KeyValueStore.memory();
    container = ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
  });

  group('the switch', () {
    test('is off while nothing is stored', () {
      expect(container.read(offlineProvider), isFalse);
      expect(container.read(networkGateProvider).offline, isFalse);
    });

    test('writes {"on":true} when turned on and removes the key when turned off', () {
      container.read(offlineProvider.notifier).set(true);
      expect(store.getItem('backmycodes_offline'), '{"on":true}');
      expect(container.read(offlineProvider), isTrue);
      expect(container.read(networkGateProvider).offline, isTrue);

      container.read(offlineProvider.notifier).set(false);
      expect(store.storedKeys(), isNot(contains('backmycodes_offline')));
      expect(container.read(offlineProvider), isFalse);
    });

    test('is on from the start when the phone stored it', () {
      store.setItem('backmycodes_offline', '{"on":true}');
      expect(container.read(offlineProvider), isTrue);
    });

    test('reads anything else as off', () {
      for (final raw in ['', 'not json', '[]', '{"on":false}', '{"on":"yes"}', '{}']) {
        store.setItem('backmycodes_offline', raw);
        expect(readOffline(store), isFalse, reason: raw);
      }
    });

    test('tells who watches it', () async {
      final heard = <bool>[];
      container.listen(offlineProvider, (_, on) => heard.add(on));

      container.read(offlineProvider.notifier).set(true);
      await container.pump();
      container.read(offlineProvider.notifier).set(false);
      await container.pump();

      expect(heard, [true, false]);
    });
  });

  group('the gate', () {
    test('lets a check through while off and throws while on', () {
      final gate = container.read(networkGateProvider);
      expect(gate.check, returnsNormally);

      container.read(offlineProvider.notifier).set(true);

      final url = Uri.parse('https://example.org/x');
      expect(
        () => gate.check(url),
        throwsA(
          isA<OfflineException>().having((e) => e.uri, 'uri', url).having((e) => e, 'a client exception', isA<http.ClientException>()),
        ),
      );
    });
  });

  group('a gated client', () {
    test('passes a request through while offline mode is off', () async {
      final inner = CountingClient();
      final client = GatedClient(() => inner, container.read(networkGateProvider));

      final response = await client.get(Uri.parse('https://example.org/a'));

      expect(response.body, 'ok');
      expect(inner.requests.single.url.path, '/a');
    });

    test('throws without calling the inner client while offline mode is on', () async {
      final inner = CountingClient();
      var made = 0;
      final client = GatedClient(() {
        made++;
        return inner;
      }, container.read(networkGateProvider));
      container.read(offlineProvider.notifier).set(true);

      await expectLater(client.get(Uri.parse('https://example.org/a')), throwsA(isA<OfflineException>()));
      await expectLater(client.post(Uri.parse('https://example.org/a'), body: 'x'), throwsA(isA<OfflineException>()));

      expect(inner.requests, isEmpty);
      expect(made, 0, reason: 'the inner client is not even made');
    });

    test('stops a client that was used before offline mode was turned on, and lets it go on after', () async {
      final inner = CountingClient();
      final client = GatedClient(() => inner, container.read(networkGateProvider));
      await client.get(Uri.parse('https://example.org/a'));

      container.read(offlineProvider.notifier).set(true);
      await expectLater(client.get(Uri.parse('https://example.org/b')), throwsA(isA<OfflineException>()));
      container.read(offlineProvider.notifier).set(false);
      await client.get(Uri.parse('https://example.org/c'));

      expect(inner.requests.map((r) => r.url.path), ['/a', '/c']);
    });

    test('closes the inner client on close', () async {
      final inner = CountingClient();
      final client = GatedClient(() => inner, container.read(networkGateProvider));
      await client.get(Uri.parse('https://example.org/a'));

      client.close();

      expect(inner.closed, isTrue);
    });

    test('is what gatedClientProvider gives, over the plain client', () async {
      final seen = <Uri>[];
      final scoped = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(store),
          plainClientProvider.overrideWithValue(
            () => MockClient((request) async {
              seen.add(request.url);
              return http.Response('', 200);
            }),
          ),
        ],
      );
      addTearDown(scoped.dispose);
      final client = scoped.read(gatedClientProvider);

      await client.get(Uri.parse('https://example.org/a'));
      scoped.read(offlineProvider.notifier).set(true);
      await expectLater(client.get(Uri.parse('https://example.org/b')), throwsA(isA<OfflineException>()));

      expect(seen.map((u) => u.path), ['/a']);
    });
  });

  group('the providers that make a client', () {
    late List<http.Request> reached;
    late ProviderContainer wired;

    setUp(() {
      reached = [];
      http.Client mock() => MockClient((request) async {
        reached.add(request);
        return http.Response('', 404);
      });
      wired = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(store),
          plainClientProvider.overrideWithValue(mock),
          vwPlainClientFactoryProvider.overrideWithValue((_) => mock()),
        ],
      );
      addTearDown(wired.dispose);
    });

    const dav = DavAccount(url: 'https://dav.example.org/Kemlock/', username: 'me', password: 'pw');
    final server = Uri.parse('https://vault.example.org');

    Future<void> webDavRead() async {
      try {
        await wired.read(webDavProvider).readFile(dav, 'backmycodes-sync.json');
      } on DavError {
        // No answer, as while offline
      }
    }

    Future<void> prelogin() async {
      try {
        await VwApi(wired.read(vwClientFactoryProvider)(null)).prelogin(server, 'me@example.org');
      } on VwError {
        // The mock is no Vaultwarden, and offline nothing answers
      }
    }

    Future<void> pwnedRange() async {
      try {
        await wired.read(pwnedPasswordsProvider).timesLeaked('password');
      } on LeakCheckError {
        // A 404, or no answer while offline
      }
    }

    test('reach the network while offline mode is off', () async {
      await webDavRead();
      await prelogin();
      await pwnedRange();

      expect(reached.map((r) => r.url.host), ['dav.example.org', 'vault.example.org', 'api.pwnedpasswords.com']);
    });

    test('send nothing while offline mode is on', () async {
      wired.read(offlineProvider.notifier).set(true);

      await webDavRead();
      await prelogin();
      await pwnedRange();

      expect(reached, isEmpty);
    });

    test('refuse the certificate probe while offline mode is on', () async {
      wired.read(offlineProvider.notifier).set(true);

      await expectLater(wired.read(vwCertificateProbeProvider)(server), throwsA(isA<OfflineException>()));
    });
  });

  group('the backstop main installs', () {
    test('makes a dart:io client while offline mode is off and refuses while it is on', () {
      final gate = container.read(networkGateProvider);
      HttpOverrides.runWithHttpOverrides(() {
        final client = HttpClient();
        expect(client, isA<HttpClient>());
        client.close(force: true);

        container.read(offlineProvider.notifier).set(true);
        expect(HttpClient.new, throwsA(isA<OfflineException>()));
        expect(http.Client.new, throwsA(isA<OfflineException>()), reason: 'package:http makes a dart:io client');

        container.read(offlineProvider.notifier).set(false);
        HttpClient().close(force: true);
      }, GatedHttpOverrides(gate));
    });
  });
}
