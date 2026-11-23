import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/keys/keys.dart' show maxKeyInputLength;
import 'package:kemlock/features/contacts/lookup/lookup_http.dart';
import 'package:kemlock/platform/network.dart';

final _url = Uri.parse('https://openpgpkey.example.org/.well-known/openpgpkey/example.org/hu/abc?l=grace');

/// A server that never answers, and drops the request when told to.
class _SilentClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  var aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    final answer = Completer<http.StreamedResponse>();
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.whenComplete(() {
          aborted++;
          answer.completeError(http.RequestAbortedException(request.url));
        }),
      );
    }
    return answer.future;
  }
}

Matcher _fails(LookupFailure failure) => throwsA(isA<LookupException>().having((e) => e.failure, 'failure', failure));

void main() {
  group('a request', () {
    test('is a GET with the app’s name and what it accepts, and nothing else', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('', 404);
      });

      final response = await lookupGet(client, _url, accept: 'application/octet-stream');

      expect((response.status, response.url, response.body), (404, _url, null));
      final request = requests.single;
      expect((request.method, request.url, request.followRedirects), ('GET', _url, false));
      expect(Map.of(request.headers), {'User-Agent': 'Kemlock', 'Accept': 'application/octet-stream'});
      expect(request.bodyBytes, isEmpty);
    });

    test('gives the body of a 200 up to 1 MB', () async {
      final client = MockClient((_) async => http.Response.bytes(List.filled(maxKeyInputLength, 7), 200));

      final response = await lookupGet(client, _url, accept: 'application/octet-stream');

      expect((response.status, response.body?.length), (200, maxKeyInputLength));
    });

    test('refuses a body one byte over the cap, whether its length is said or not', () async {
      final said = MockClient((_) async => http.Response.bytes(List.filled(maxKeyInputLength + 1, 7), 200));
      final unsaid = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([
            List.filled(maxKeyInputLength, 7),
            const [7],
          ]),
          200,
        ),
      );

      await expectLater(lookupGet(said, _url, accept: 'application/octet-stream'), _fails(LookupFailure.tooLarge));
      await expectLater(lookupGet(unsaid, _url, accept: 'application/octet-stream'), _fails(LookupFailure.tooLarge));
    });

    testWidgets('that is never answered gives up after ten seconds, and is dropped', (tester) async {
      final client = _SilentClient();
      Object? failed;
      unawaited(lookupGet(client, _url, accept: 'application/octet-stream').then((_) {}, onError: (Object error) => failed = error));

      await tester.pump(const Duration(seconds: 9));
      expect(failed, isNull);

      await tester.pump(const Duration(seconds: 1));
      expect(failed, isA<LookupException>().having((e) => e.failure, 'failure', LookupFailure.unreachable));
      expect(client.aborted, 1);
    });

    test('is dropped once the search is abandoned', () async {
      final client = _SilentClient();
      final abandon = Completer<void>();
      final asked = lookupGet(client, _url, accept: 'application/octet-stream', abandon: abandon.future);

      abandon.complete();

      await expectLater(asked, _fails(LookupFailure.unreachable));
      expect((client.requests.length, client.aborted), (1, 1));
    });

    test('that fails to connect or to verify the certificate is unreachable', () async {
      for (final error in [
        const SocketException('Connection refused'),
        const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        http.ClientException('Connection closed'),
      ]) {
        final client = MockClient((_) async => throw error);

        await expectLater(lookupGet(client, _url, accept: 'application/octet-stream'), _fails(LookupFailure.unreachable), reason: '$error');
      }
    });

    test('stopped by offline mode says so', () async {
      final client = MockClient((_) async => throw OfflineException(_url));

      await expectLater(lookupGet(client, _url, accept: 'application/octet-stream'), _fails(LookupFailure.offline));
    });

    test('to an address that is not https is never made', () async {
      final client = MockClient((_) async => fail('nothing should be asked'));

      await expectLater(lookupGet(client, Uri.parse('http://example.org/key'), accept: 'x'), _fails(LookupFailure.unreachable));
    });
  });

  group('a redirect', () {
    /// A chain of https redirects /0 → /1 → … → /[last], which answers 200.
    (MockClient, List<String>) chain(int last, {String Function(int next)? location}) {
      final asked = <String>[];
      final client = MockClient((request) async {
        asked.add(request.url.path);
        final at = int.parse(request.url.path.substring(1));
        if (at == last) return http.Response('key', 200);
        return http.Response('', 302, headers: {'location': location?.call(at + 1) ?? 'https://www$at.example.org/${at + 1}'});
      });
      return (client, asked);
    }

    test('is followed three times in a row, each to https', () async {
      final (client, asked) = chain(3);

      final response = await lookupGet(client, Uri.parse('https://example.org/0'), accept: 'x', redirects: maxLookupRedirects);

      expect((response.status, response.url.toString(), String.fromCharCodes(response.body!)), (200, 'https://www2.example.org/3', 'key'));
      expect(asked, ['/0', '/1', '/2', '/3']);
    });

    test('is not followed a fourth time', () async {
      final (client, asked) = chain(4);

      final response = await lookupGet(client, Uri.parse('https://example.org/0'), accept: 'x', redirects: maxLookupRedirects);

      expect((response.status, response.body), (302, null));
      expect(asked, ['/0', '/1', '/2', '/3']);
    });

    test('to an address that is not https is not followed', () async {
      final (client, asked) = chain(1, location: (next) => 'http://www.example.org/$next');

      final response = await lookupGet(client, Uri.parse('https://example.org/0'), accept: 'x', redirects: maxLookupRedirects);

      expect((response.status, response.body), (302, null));
      expect(asked, ['/0']);
    });

    test('to a path of the same host is followed there', () async {
      final (client, asked) = chain(1, location: (next) => '/$next');

      final response = await lookupGet(client, Uri.parse('https://example.org/0'), accept: 'x', redirects: maxLookupRedirects);

      expect((response.status, response.url.toString()), (200, 'https://example.org/1'));
      expect(asked, ['/0', '/1']);
    });

    test('is never followed when the caller allows none', () async {
      final (client, asked) = chain(1);

      final response = await lookupGet(client, Uri.parse('https://example.org/0'), accept: 'x');

      expect((response.status, response.body), (302, null));
      expect(asked, ['/0']);
    });
  });
}
