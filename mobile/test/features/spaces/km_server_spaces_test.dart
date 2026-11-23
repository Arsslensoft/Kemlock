import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/sig1.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// The Spaces sheet's source against the fake server, with the account's real keys: a space made by appending its `create`
// to the chain route of a new id (the server makes the space from it), and the list's real name, opened from the sealed
// `kem1` name through the chain's commitment (docs/plans/add-server-spaces.md, tasks 5.1 and 5.2).
void main() {
  test('makes a space as records[0] of the new id’s chain route, and the list then shows the name the server holds', () async {
    final sigKeys = await Sig1.generate();
    final kxPrivate = Uint8List.fromList(List.generate(Kx1.privateKeyLength, (i) => (i * 7 + 3) & 0xff));
    final accountId = uuid(1);
    final account = KmAccount(
      accountId: accountId,
      keyVersion: 1,
      rootKey: Uint8List(64),
      kx1PrivateKey: kxPrivate,
      sig1PrivateKey: sigKeys.privateKey,
      kx1PublicKey: await Kx1.publicKeyOf(kxPrivate),
      sig1PublicKey: sigKeys.publicKey,
    );
    final server = FakeSpaceServer(uuid(0x5a), ChainBuilder(uuid(0x5a)));
    final seen = <String>[];
    final connection = KmConnection(
      api: KmApi(
        MockClient((request) async {
          seen.add('${request.method} ${request.url.path}');
          return server.handle(request);
        }),
      ),
      server: FakeSpaceServer.url,
      session: KmSession(
        userId: accountId,
        deviceId: '00000000-0000-4000-8000-0000000000d1',
        tokens: KmTokens(access: accountId, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
      ),
      save: (_) async {},
    );
    final store = <String, Object?>{};
    // What the phone keeps of the chains it accepted: the maker's own first contact is recorded here
    Map<String, Object?>? anchors;
    KmServerSpaces sourceOf() => KmServerSpaces(
      accountId: accountId,
      run: <T>(action) => action(connection, account),
      loadValue: (key) async => store[key],
      saveValue: (key, value) async => store[key] = value,
      loadAnchors: () async => anchors,
      saveAnchors: (value) async => anchors = value,
    );

    final made = await sourceOf().make('Example Co');

    expect(made.name, 'Example Co');
    expect(made.status, 'owner');
    expect(
      [
        for (final request in seen)
          if (request.startsWith('POST')) request,
      ],
      ['POST /kem/v1/spaces/${made.id}/chain'],
      reason: 'no unchained POST /spaces',
    );
    final space = server.created[made.id]!;
    expect(space.records.single.entry.kind, ChainKind.create);
    expect(space.records.single.entry.seq, 0);
    expect({for (final seal in space.seals) seal['member']}, {accountId}, reason: 'the keys are sealed to the maker alone');
    expect(space.names.keys, contains('space'));
    expect(space.names, hasLength(2), reason: 'the space’s name and "Everyone"');

    // The maker is its own anchor: first contact is recorded for the space it made, since its chain begins with its record
    expect(await sourceOf().isCompared(made.id), isTrue);

    // A new source, which remembers nothing this phone made: the name is the server's, opened through the chain
    final listed = await sourceOf().load();

    expect(listed, hasLength(1));
    expect(listed.single.id, made.id);
    expect(listed.single.name, 'Example Co');
    expect(listed.single.status, 'owner');
  });

  test('refuses to make a space for a member of one that allows one per member, and asks the server nothing', () async {
    final source = KmServerSpaces(
      accountId: uuid(1),
      run: <T>(action) => Future<T>.error(StateError('nothing may be asked of the server')),
      loadValue: (key) async => null,
      saveValue: (key, value) async {},
      makeBlockedBy: () => const LeaveFirst(space: '5a5a5a5a-0000-4000-8000-000000000001', name: 'Example Co', byCurrent: true),
    );

    await expectLater(source.make('Another'), throwsA(isA<SingleSpaceRefused>().having((e) => e.leaveFirst.label, 'label', 'Example Co')));
  });
}
