import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/features/spaces/space_invites.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// The invitee's answer on the server's own routes (docs/plans/add-server-spaces.md, task 5.2): accept is `POST
// .../members/me/accept` with no body and answers the member, decline is `DELETE .../members/me`. Neither uploads a bundle,
// and neither is a record of the chain.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);

  late List<http.Request> seen;

  SpaceInviteClient clientFor(Future<http.Response> Function(http.Request request) answer) {
    final session = KmSession(
      userId: bob.id,
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: bob.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    );
    final api = KmApi(
      MockClient((request) async {
        seen.add(request);
        return answer(request);
      }),
    );
    return SpaceInviteClient(
      connection: KmConnection(api: api, server: FakeSpaceServer.url, session: session, save: (_) async {}),
      server: FakeSpaceServer.url,
      space: space,
    );
  }

  setUp(() => seen = []);

  test('accepting is a POST to the member’s own accept route with no body, answered with the member', () async {
    final chain = ChainBuilder(space)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: CollectionPermission.edit});
    final server = FakeSpaceServer(space, chain);
    final records = chain.entries.length;

    await clientFor(server.handle).answer(accept: true);

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/kem/v1/spaces/$space/members/me/accept');
    expect(seen.single.bodyBytes, isEmpty, reason: 'the server takes the bundle from the account');
    expect(seen.single.headers.containsKey('Content-Type'), isFalse);
    expect(server.accepted, {bob.id});
    expect(chain.entries.length, records, reason: 'an accept is no record of the chain');
  });

  test('declining is a DELETE of the member’s own route, which drops the invitation', () async {
    final chain = ChainBuilder(space)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: CollectionPermission.edit});
    final server = FakeSpaceServer(space, chain);

    await clientFor(server.handle).answer(accept: false);

    expect(seen.single.method, 'DELETE');
    expect(seen.single.url.path, '/kem/v1/spaces/$space/members/me');
    expect(seen.single.bodyBytes, isEmpty);
    expect(server.declined, {bob.id});
    expect(server.accepted, isEmpty);
  });

  test('the answer to an accept can be the member, and a refusal is the server’s error', () async {
    final member = http.Response(jsonEncode({'user': bob.id, 'state': 'accepted'}), 200, headers: {'content-type': 'application/json'});
    await clientFor((request) async => member).answer(accept: true);

    await expectLater(
      clientFor(
        (request) async => http.Response(
          jsonEncode({'type': 'urn:kemlock:problem:not-found', 'title': 'not-found', 'status': 404}),
          404,
          headers: {'content-type': 'application/problem+json'},
        ),
      ).answer(accept: true),
      throwsA(isA<KmError>().having((e) => e.status, 'status', 404)),
    );
  });
}
