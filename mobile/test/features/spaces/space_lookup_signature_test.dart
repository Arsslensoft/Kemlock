import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/features/spaces/space_invites.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// The lookup of an invitee also answers `bundleSignature` and `keyVersion` beside `{account, bundle}` (docs/plans/
// add-server-spaces.md, task 5.2): the signature is checked, and the key version compared with the bundle's, before an
// invitation is built over the bundle, and an answer without them is refused.
void main() {
  final space = uuid(0x5a);
  final theo = Person(4);
  final mallory = Person(9);

  SpaceInviteClient clientFor(Map<String, Object?> answer) {
    final session = KmSession(
      userId: uuid(1),
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: uuid(1), refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    );
    final api = KmApi(MockClient((request) async => http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'})));
    return SpaceInviteClient(
      connection: KmConnection(api: api, server: FakeSpaceServer.url, session: session, save: (_) async {}),
      server: FakeSpaceServer.url,
      space: space,
      crypto: const FakeChainCrypto(),
    );
  }

  Map<String, Object?> answerFor(Person who, {Object? signature, Object? keyVersion}) => {
    'account': who.id,
    'bundle': b64urlEncode(who.bundle.bytes),
    'bundleSignature': ?signature,
    'keyVersion': ?keyVersion,
  };

  Matcher refused() => throwsA(isA<InviteLookupError>().having((e) => e.problem, 'problem', InviteLookupProblem.malformed));

  test('takes a bundle whose signature is its own and whose key version is the bundle’s', () async {
    final found = await clientFor(answerFor(theo, signature: b64urlEncode(theo.bundleSignature), keyVersion: theo.keyVersion))
        .lookup('theo@example.com');

    expect(found!.account, theo.id);
    expect(found.bundle.fingerprintDigits, theo.bundle.fingerprintDigits);
  });

  test('refuses a bundle signed by another key, so no invitation is built over it', () async {
    await expectLater(clientFor(answerFor(theo, signature: b64urlEncode(mallory.bundleSignature))).lookup('theo@example.com'), refused());
  });

  test('refuses a key version that is not the bundle’s, and a signature or version of the wrong kind', () async {
    await expectLater(clientFor(answerFor(theo, keyVersion: theo.keyVersion + 1)).lookup('theo@example.com'), refused());
    await expectLater(clientFor(answerFor(theo, signature: 7)).lookup('theo@example.com'), refused());
    await expectLater(clientFor(answerFor(theo, keyVersion: '1')).lookup('theo@example.com'), refused());
  });

  test('refuses an answer without the signature or the key version', () async {
    await expectLater(clientFor(answerFor(theo)).lookup('theo@example.com'), refused());
    await expectLater(clientFor(answerFor(theo, keyVersion: theo.keyVersion)).lookup('theo@example.com'), refused());
    await expectLater(clientFor(answerFor(theo, signature: b64urlEncode(theo.bundleSignature))).lookup('theo@example.com'), refused());
  });
}
