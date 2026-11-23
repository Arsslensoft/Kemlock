import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/sig1.dart';
import 'package:kemlock/features/spaces/space_actions.dart';
import 'package:kemlock/features/spaces/space_members.dart';
import 'package:kemlock/features/spaces/space_overview.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// What the members route tells an admin beside the chain (docs/plans/add-server-spaces.md, task 5.3): the bundle of a member
// who accepted, whose signature is checked before it is offered for the fingerprint comparison, and the confirmation
// that is built over exactly that bundle; and a confirmed member whose key version changed, who needs a fresh comparison.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);
  final mallory = Person(9);

  /// The members route as Alice's phone, or [who]'s, reads it from a server whose chain is [chain].
  SpaceMembersClient clientFor(FakeSpaceServer server, {Person? who}) {
    final caller = who ?? alice;
    final session = KmSession(
      userId: caller.id,
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: caller.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    );
    return SpaceMembersClient(
      connection: KmConnection(api: KmApi(MockClient(server.handle)), server: FakeSpaceServer.url, session: session, save: (_) async {}),
      server: FakeSpaceServer.url,
      space: space,
      crypto: const FakeChainCrypto(),
    );
  }

  Map<String, Object?> facts(Person who, {Person? bundleOf, Person? signedBy, bool needs = false, int? keyVersion}) {
    final bundle = (bundleOf ?? who).bundle;
    return {
      'email': '${who.id.substring(30)}@example.com',
      'name': 'Member ${who.id.substring(30)}',
      'publicBundle': b64urlEncode(bundle.bytes),
      'bundleSignature': b64urlEncode(fakeSignature((signedBy ?? bundleOf ?? who).bundle.sig1PublicKey, 'bundle', bundle.bytes)),
      'userKeyVersion': keyVersion ?? bundle.keyVersion,
      'needsReconfirmation': needs,
    };
  }

  ChainBuilder invited() => ChainBuilder(space)
    ..create(alice, collection: everyone)
    ..invite(alice, bob, grants: {everyone: CollectionPermission.edit});

  group('a member who accepted', () {
    test('is offered with the bundle the server holds once its signature checks, named as the server names them', () async {
      final chain = invited();
      final server = FakeSpaceServer(space, chain)
        ..accepted.add(bob.id)
        ..memberFacts[bob.id] = facts(bob);

      final members = await clientFor(server).read(chain.state);

      expect(members.offers.keys, [bob.id]);
      expect(members.offers[bob.id]!.bundle.fingerprintDigits, bob.bundle.fingerprintDigits);
      expect(members.offers[bob.id]!.bundleSignature, bob.bundleSignature);
      expect(members.names[bob.id], 'Member ${bob.id.substring(30)}');
      expect(members.reconfirm, isEmpty);
    });

    test('is not offered before they accepted, with a signature of another key, or with another account’s bundle', () async {
      final chain = invited();

      final waiting = FakeSpaceServer(space, chain)..memberFacts[bob.id] = facts(bob);
      expect((await clientFor(waiting).read(chain.state)).offers, isEmpty, reason: 'invited, not accepted');

      final forged = FakeSpaceServer(space, chain)
        ..accepted.add(bob.id)
        ..memberFacts[bob.id] = facts(bob, signedBy: mallory);
      expect((await clientFor(forged).read(chain.state)).offers, isEmpty, reason: 'the bundle is not signed by its own key');

      final swapped = FakeSpaceServer(space, chain)
        ..accepted.add(bob.id)
        ..memberFacts[bob.id] = facts(bob, bundleOf: mallory);
      expect((await clientFor(swapped).read(chain.state)).offers, isEmpty, reason: 'the bundle is another account’s');

      final stale = FakeSpaceServer(space, chain)
        ..accepted.add(bob.id)
        ..memberFacts[bob.id] = facts(bob, keyVersion: bob.keyVersion + 1);
      expect((await clientFor(stale).read(chain.state)).offers, isEmpty, reason: 'the key version is not the bundle’s');
    });

    test('is offered to Admins and Owners only; a member who manages no one is told nothing', () async {
      final chain = invited()..confirm(alice, bob);
      final server = FakeSpaceServer(space, chain)..memberFacts[bob.id] = facts(bob, needs: true, bundleOf: bob.withNewKeys());

      final members = await clientFor(server, who: bob).read(chain.state);

      expect(members.offers, isEmpty);
      expect(members.names, isEmpty);
    });

    test('is confirmed over exactly the bundle that was offered and compared', () async {
      final chain = invited();
      final server = FakeSpaceServer(space, chain)
        ..accepted.add(bob.id)
        ..memberFacts[bob.id] = facts(bob);
      final offer = (await clientFor(server).read(chain.state)).offers[bob.id]!;
      final keys = await Sig1.generate();

      final action = await buildConfirmAction(
        state: chain.state,
        by: alice.id,
        member: bob.id,
        bundle: offer.bundle,
        bundleSignature: offer.bundleSignature,
        confirmerSig1PrivateKey: keys.privateKey,
        at: 1,
      );

      expect(action.entry.body['bundle'], b64urlEncode(bob.bundle.bytes));
      expect(action.entry.body['bundleSignature'], b64urlEncode(bob.bundleSignature));
      expect(action.entry.body['member'], bob.id);
    });
  });

  group('a confirmed member whose key version changed', () {
    test('needs a fresh comparison, of the new bundle when the chain does not hold it yet', () async {
      final chain = invited()..confirm(alice, bob);
      final server = FakeSpaceServer(space, chain)..memberFacts[bob.id] = facts(bob, bundleOf: bob.withNewKeys(), needs: true);

      final members = await clientFor(server).read(chain.state);

      expect(members.reconfirm, {bob.id});
      expect(members.offers[bob.id]!.bundle.keyVersion, bob.keyVersion + 1);
      expect(memberStatus(chain.state.member(bob.id)!, accepted: false, reconfirm: members.reconfirm.contains(bob.id)), 'reconfirm');
    });

    test('is only marked when the chain already records the bundle, and is not marked when nothing changed', () async {
      final chain = invited()..confirm(alice, bob);

      final recorded = FakeSpaceServer(space, chain)..memberFacts[bob.id] = facts(bob, needs: true);
      final marked = await clientFor(recorded).read(chain.state);
      expect(marked.reconfirm, {bob.id});
      expect(marked.offers, isEmpty, reason: 'there is no newer bundle to confirm');

      final unchanged = FakeSpaceServer(space, chain)..memberFacts[bob.id] = facts(bob);
      final quiet = await clientFor(unchanged).read(chain.state);
      expect(quiet.reconfirm, isEmpty);
      expect(memberStatus(chain.state.member(bob.id)!, accepted: false), 'confirmed');
    });
  });
}
