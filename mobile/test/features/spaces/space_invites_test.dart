import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/features/spaces/space_invites.dart';
import 'package:kemlock/features/spaces/space_listing.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';

import 'chain_kit.dart';

// The routes of an invitation, built to the shape the server's session gave and not merged on the server yet (task 5.2):
// the lookup of an account by email, the resend, and the invitee's answer; and the list of spaces they come from.
void main() {
  final space = uuid(0x5a);
  final theo = Person(4);
  final mallory = Person(9);

  late List<http.Request> seen;

  http.Response problem(int status, String slug, {Map<String, String> headers = const {}}) => http.Response(
    jsonEncode({'type': 'urn:kemlock:problem:$slug', 'title': slug, 'status': status}),
    status,
    headers: {'content-type': 'application/problem+json', ...headers},
  );

  http.Response json(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  SpaceInviteClient clientFor(http.Response Function(http.Request request) answer) {
    final session = KmSession(
      userId: uuid(1),
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: uuid(1), refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    );
    final server = Uri.parse('https://kem.example.com');
    final api = KmApi(
      MockClient((request) async {
        seen.add(request);
        return answer(request);
      }),
    );
    return SpaceInviteClient(
      connection: KmConnection(api: api, server: server, session: session, save: (_) async {}),
      server: server,
      space: space,
      crypto: const FakeChainCrypto(),
    );
  }

  setUp(() => seen = []);

  group('looking an invitee up by email', () {
    test('answers the account and its bundle, from GET /spaces/{id}/lookup?email=', () async {
      final client = clientFor(
        (request) => json({
          'account': theo.id,
          'bundle': b64urlEncode(theo.bundle.bytes),
          'bundleSignature': b64urlEncode(theo.bundleSignature),
          'keyVersion': theo.keyVersion,
        }),
      );

      final found = await client.lookup('theo@example.com');

      expect(found!.account, theo.id);
      expect(found.bundle.fingerprintDigits, theo.bundle.fingerprintDigits);
      expect(seen.single.method, 'GET');
      expect(seen.single.url.path, '/kem/v1/spaces/$space/lookup');
      expect(seen.single.url.queryParameters, {'email': 'theo@example.com'});
    });

    test("an unknown email is no account, and an answer that isn't one account's bundle is refused", () async {
      expect(await clientFor((request) => problem(404, 'no-account')).lookup('nobody@example.com'), isNull);

      final other = clientFor(
        (request) => json({
          'account': theo.id,
          'bundle': b64urlEncode(mallory.bundle.bytes),
          'bundleSignature': b64urlEncode(mallory.bundleSignature),
          'keyVersion': mallory.keyVersion,
        }),
      );
      await expectLater(
        other.lookup('theo@example.com'),
        throwsA(isA<InviteLookupError>().having((e) => e.problem, 'problem', InviteLookupProblem.malformed)),
      );
      final garbage = clientFor((request) => json({'account': 'x', 'bundle': 'y'}));
      await expectLater(garbage.lookup('theo@example.com'), throwsA(isA<InviteLookupError>()));
    });

    test('a caller who may not look anyone up is refused, and the rate limit says how long to wait', () async {
      await expectLater(
        clientFor((request) => problem(403, 'forbidden')).lookup('theo@example.com'),
        throwsA(isA<InviteLookupError>().having((e) => e.problem, 'problem', InviteLookupProblem.notAllowed)),
      );
      await expectLater(
        clientFor((request) => problem(429, 'rate-limited', headers: {'retry-after': '30'})).lookup('theo@example.com'),
        throwsA(
          isA<InviteLookupError>()
              .having((e) => e.problem, 'problem', InviteLookupProblem.rateLimited)
              .having((e) => e.retryAfter, 'retryAfter', 30),
        ),
      );
    });
  });

  group('resending an invitation', () {
    test("posts to the member's resend route, which answers 204", () async {
      await clientFor((request) => http.Response('', 204)).resend(theo.id);

      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/kem/v1/spaces/$space/members/${theo.id}/resend');
    });

    test('is limited to once per 10 minutes, and says so', () async {
      await expectLater(
        clientFor((request) => problem(429, 'rate-limited')).resend(theo.id),
        throwsA(isA<ResendError>().having((e) => e.problem, 'problem', ResendProblem.tooSoon)),
      );
      await expectLater(
        clientFor((request) => problem(403, 'forbidden')).resend(theo.id),
        throwsA(isA<ResendError>().having((e) => e.problem, 'problem', ResendProblem.notAllowed)),
      );
    });

    test('takes only an account id', () async {
      await expectLater(clientFor((request) => http.Response('', 204)).resend('../chain'), throwsArgumentError);
    });
  });

  test("the invitee's answer goes to accept or decline", () async {
    final client = clientFor((request) => http.Response('', 204));
    await client.answer(accept: true);
    await client.answer(accept: false);

    expect(
      [for (final request in seen) '${request.method} ${request.url.path}'],
      ['POST /kem/v1/spaces/$space/members/me/accept', 'DELETE /kem/v1/spaces/$space/members/me'],
    );
  });

  group('the list of spaces', () {
    Map<String, Object?> entry(String id, {String? name, String state = 'confirmed', Object? acceptedAt}) => {
      'space': {'id': id, 'name': ?name, 'keyVersion': 1, 'createdAt': '2026-11-22T10:00:00Z'},
      'member': {
        'user': theo.id,
        'role': 'member',
        'custom': <String>[],
        'state': state,
        'invitedBy': uuid(1),
        'invitedAt': 1,
        'acceptedAt': ?acceptedAt,
      },
    };

    test("reads each space with its sealed name and the member's state", () {
      final listed = parseSpaceList([
        entry(uuid(1), name: b64urlEncode([1, 2, 3, 4])),
        entry(uuid(2), state: 'invited'),
        entry(uuid(3), state: 'invited', acceptedAt: 1700000000),
        entry(uuid(4), state: 'accepted'),
      ]);

      expect([for (final space in listed) space.id], [uuid(1), uuid(2), uuid(3), uuid(4)]);
      expect(listed.first.sealedName, [1, 2, 3, 4]);
      expect(listed[1].sealedName, isNull);
      expect([for (final space in listed) space.accepted], [false, false, true, true]);
    });

    test('leaves out what is not a space, reads a name that is not base64url as none, and refuses a list that is not an array', () {
      final listed = parseSpaceList([
        {'id': uuid(1)},
        'text',
        entry(uuid(2), name: 'not base64url!'),
      ]);

      expect(listed.single.id, uuid(2));
      expect(listed.single.sealedName, isNull);
      expect(() => parseSpaceList({'spaces': <Object?>[]}), throwsA(isA<KmError>()));
    });
  });
}
