import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// A policy is the verified chain's, never the server's (docs/plans/add-server-spaces.md, task 7.1): the list of spaces and
// the member beside it carry a flipped policy, and the policies the app holds after reading them are the chain's.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final sam = Person(1);
  final theo = Person(3);

  /// Sam's space with Theo a confirmed Member, and [sso] on or off by the chain.
  ChainBuilder chainOf({required bool sso}) {
    final chain = ChainBuilder(space)
      ..create(sam, collection: everyone)
      ..invite(sam, theo, grants: {everyone: CollectionPermission.view})
      ..confirm(sam, theo);
    if (sso) {
      chain.policies(sam, {'requireSso': true});
    }
    return chain;
  }

  /// Theo's spaces on [server], each verified chain of a space he compared reported to [onChain], and every verified chain to
  /// [onRead]. [anchors] holds what his phone stored.
  KmServerSpaces sourceOf(
    FakeSpaceServer server,
    void Function(String space, String account, SpaceState chain) onChain, {
    void Function(String space, String account, SpaceState chain)? onRead,
    void Function(String space, String account, SpaceState chain, {required bool accepted})? onInvitation,
    Map<String, Object?>? anchors,
  }) {
    var held = anchors;
    final account = KmAccount(
      accountId: theo.id,
      keyVersion: theo.keyVersion,
      rootKey: Uint8List(64),
      kx1PrivateKey: Uint8List(64),
      sig1PrivateKey: Uint8List(64),
      kx1PublicKey: theo.bundle.kx1PublicKey,
      sig1PublicKey: theo.bundle.sig1PublicKey,
    );
    final connection = KmConnection(
      api: KmApi(MockClient(server.handle)),
      server: FakeSpaceServer.url,
      session: KmSession(
        userId: theo.id,
        deviceId: '00000000-0000-4000-8000-0000000000d1',
        tokens: KmTokens(access: theo.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
      ),
      save: (_) async {},
    );
    final store = <String, Object?>{};
    return KmServerSpaces(
      accountId: theo.id,
      run: <T>(action) => action(connection, account),
      loadValue: (key) async => store[key],
      saveValue: (key, value) async => store[key] = value,
      loadAnchors: () async => held,
      saveAnchors: (value) async => held = value,
      chainCrypto: const FakeChainCrypto(),
      onChain: (space, account, chain, {collections}) => onRead?.call(space, account, chain),
      onComparedChain: (space, account, chain, {collections}) => onChain(space, account, chain),
      onInvitation: onInvitation,
    );
  }

  /// Theo's first contact with the space on [source]: the digits matched, so the chain as verified is anchored as compared.
  Future<void> compare(KmServerSpaces source) async => source.rememberAnchor(space, (await source.readContact(space)).anchor!);

  test('a policy the server flipped on in its list is ignored: the chain says off', () async {
    final server = FakeSpaceServer(space, chainOf(sso: false))
      ..listExtra = {
        'requireSso': true,
        'policies': {'requireSso': true, 'accountRecovery': true, 'disableExport': true, 'singleSpace': true},
      };
    var policies = const SpacePolicies();
    final source = sourceOf(server, (space, account, chain) => policies = policies.remembering(space, account, chain));
    await compare(source);

    final listed = await source.load();

    expect(listed.single.status, 'member');
    expect(policies.spaces.keys, [space], reason: 'the chain was read and reported');
    expect(policies.requiresSso, isFalse);
    final hold = policies.spaces[space]!;
    for (final flag in ['requireSso', 'accountRecovery', 'disableExport', 'singleSpace']) {
      expect(hold.on(flag), isFalse, reason: flag);
    }
  });

  test('a policy the server left off in its list is applied: the chain says on', () async {
    final server = FakeSpaceServer(space, chainOf(sso: true))..listExtra = {'requireSso': false, 'policies': <String, Object?>{}};
    var policies = const SpacePolicies();

    final source = sourceOf(server, (space, account, chain) => policies = policies.remembering(space, account, chain));
    await compare(source);

    await source.load();

    expect(policies.requiresSso, isTrue);
  });

  test('a space nobody compared forces nothing: its chain is read, and its policies are not counted', () async {
    final server = FakeSpaceServer(space, chainOf(sso: true));
    var policies = const SpacePolicies();
    final read = <String>[];
    final source = sourceOf(
      server,
      (space, account, chain) => policies = policies.remembering(space, account, chain),
      onRead: (space, account, chain) => read.add(space),
    );

    final listed = await source.load();

    expect(read, [space], reason: 'the chain verified');
    expect(listed.single.status, 'compare', reason: 'the row asks for a fingerprint comparison');
    expect(policies.spaces, isEmpty);
    expect(policies.requiresSso, isFalse);

    // The server lists it again and again: reading never makes the anchor, so it stays uncompared
    await source.load();
    expect(await source.isCompared(space), isFalse);
    expect(policies.requiresSso, isFalse);

    await compare(source);
    await source.load();
    expect(await source.isCompared(space), isTrue);
    expect(policies.requiresSso, isTrue, reason: 'after the comparison the chain’s policy counts');
  });

  test('an invitation the list says was accepted, in a space compared, counts for one space per member and nothing else', () async {
    final chain = ChainBuilder(space)
      ..create(sam, collection: everyone)
      ..invite(sam, theo, grants: {everyone: CollectionPermission.view})
      ..policies(sam, {'singleSpace': true, 'disableExport': true});
    final server = FakeSpaceServer(space, chain)..accepted.add(theo.id);
    var policies = const SpacePolicies();
    final source = sourceOf(
      server,
      (space, account, chain) => policies = policies.remembering(space, account, chain),
      onInvitation: (space, account, chain, {required accepted}) =>
          policies = policies.remembering(space, account, chain, accepted: accepted),
    );

    await source.load();
    expect(policies.spaces, isEmpty, reason: 'a space nobody compared counts for nothing, accepted or not');

    await compare(source);
    await source.load();
    expect(policies.leaveFirstBeforeMaking(), isNotNull, reason: 'accepted, so he is in the space as far as one space per member goes');
    expect(policies.noExport, isEmpty, reason: 'its other policies apply to a confirmed member only');

    server.accepted.clear();
    await source.load();
    expect(policies.spaces, isEmpty, reason: 'an invitation not accepted is no membership');
  });
}
