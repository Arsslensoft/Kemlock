import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/bundle.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/sig1.dart';
import 'package:kemlock/features/spaces/chain_body.dart' show defaultPolicies;
import 'package:kemlock/features/spaces/space_chain.dart';
import 'package:kemlock/features/spaces/space_rekey.dart';
import 'package:kemlock/features/spaces/space_seals.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart';

import 'chain_kit.dart';

Uint8List _seq(int n, int start) => Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xff));

// A member replaces their own key pair (the space chain section, `rekey` and its test case 10): the record is signed by
// the old key and cosigned by the new one, and the next record is signed with the new key and not the old one.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = uuid(1);
  final kx1 = _seq(Kx1.publicKeyLength, 3);

  group('with real sig1 keys', () {
    late ({Uint8List publicKey, Uint8List privateKey}) oldPair;
    late ({Uint8List publicKey, Uint8List privateKey}) newPair;
    late KeyBundle first;
    late KeyBundle second;
    late SignedChainEntry create;
    late SpaceState afterCreate;

    setUpAll(() async {
      oldPair = await Sig1.generate(_seq(64, 1));
      newPair = await Sig1.generate(_seq(64, 70));
      first = KeyBundle(accountId: uuidBytes(alice), keyVersion: 1, kx1PublicKey: kx1, sig1PublicKey: oldPair.publicKey);
      second = KeyBundle(accountId: uuidBytes(alice), keyVersion: 2, kx1PublicKey: kx1, sig1PublicKey: newPair.publicKey);
      create = await signChainEntry(
        SpaceChainEntry(
          space: space,
          seq: 0,
          prev: chainGenesisLink,
          epoch: 1,
          at: 5,
          by: alice,
          kind: ChainKind.create,
          body: {
            'bundle': b64urlEncode(first.bytes),
            'bundleSignature': b64urlEncode(await signBundle(first, oldPair.privateKey)),
            'collection': {'id': everyone, 'nameHash': hash64()},
            'member': alice,
            'nameHash': hash64(),
            'seals': [commitment(KeyRef.collection(everyone), 1, 1, makes: true), commitment(const KeyRef.space(), 1, 1, makes: true)],
          },
        ),
        oldPair.privateKey,
      );
      afterCreate = SpaceState.empty(space).apply(create.entry);
    });

    Future<SignedChainEntry> rekey() async => buildRekey(
      state: afterCreate,
      account: alice,
      newBundle: second,
      newBundleSignature: await signBundle(second, newPair.privateKey),
      oldSig1PrivateKey: oldPair.privateKey,
      newSig1PrivateKey: newPair.privateKey,
      at: 6,
    );

    Future<SignedChainEntry> next(SignedChainEntry rekeyed, Uint8List signingKey) async => signChainEntry(
      SpaceChainEntry(
        space: space,
        seq: 2,
        prev: rekeyed.entry.hashed,
        epoch: 1,
        at: 7,
        by: alice,
        kind: ChainKind.policies,
        body: {
          'policies': {...defaultPolicies(), 'requireSso': true},
        },
      ),
      signingKey,
    );

    test('the only Owner replaces their keys: the rekey is accepted, then the new key signs and the old key does not', () async {
      final rekeyed = await rekey();
      expect(rekeyed.cosignature, isNotNull);
      expect(rekeyed.entry.kind, ChainKind.rekey);
      expect(rekeyed.entry.seq, 1);
      expect(rekeyed.entry.prev, create.entry.hashed);
      // It travels as a wire form with its cosignature, and reads back
      expect(SignedChainEntry.fromJson(rekeyed.toJson()).cosignature, rekeyed.cosignature);

      final chain = [create, rekeyed];
      final result = await verifyChain(space: space, entries: chain);
      expect(result.ok, isTrue, reason: result.detail);
      expect(result.state.member(alice)!.bundle!.keyVersion, 2);
      expect(result.state.member(alice)!.rekeySeq, 1);

      final withNew = await verifyChain(space: space, entries: [...chain, await next(rekeyed, newPair.privateKey)]);
      expect(withNew.ok, isTrue, reason: withNew.detail);
      final withOld = await verifyChain(space: space, entries: [...chain, await next(rekeyed, oldPair.privateKey)]);
      expect(withOld.problem, ChainProblem.badSignature);
      expect(withOld.problemSeq, 2);
    });

    test('a rekey whose cosignature is by another key is a bad signature', () async {
      final rekeyed = await rekey();
      final other = await Sig1.generate(_seq(64, 140));
      final forged = SignedChainEntry(
        rekeyed.entry,
        rekeyed.signature,
        cosignature: await Sig1.sign(other.privateKey, rekeyed.entry.bytes, context: SignContext.spaceChain),
      );
      final result = await verifyChain(space: space, entries: [create, forged]);
      expect(result.problem, ChainProblem.badSignature);
      expect(result.problemSeq, 1);
    });

    test('a rekey whose signature is by the new key alone is a bad signature', () async {
      final rekeyed = await rekey();
      final swapped = SignedChainEntry(rekeyed.entry, rekeyed.cosignature!, cosignature: rekeyed.cosignature);
      final result = await verifyChain(space: space, entries: [create, swapped]);
      expect(result.problem, ChainProblem.badSignature);
    });

    test('refuses to build one for an account that isn\'t confirmed, or for a bundle that isn\'t newer or isn\'t theirs', () async {
      Future<SignedChainEntry> build({String? account, KeyBundle? bundle, SpaceState? state}) async => buildRekey(
        state: state ?? afterCreate,
        account: account ?? alice,
        newBundle: bundle ?? second,
        newBundleSignature: Uint8List(Sig1.signatureLength),
        oldSig1PrivateKey: oldPair.privateKey,
        newSig1PrivateKey: newPair.privateKey,
        at: 6,
      );
      await expectLater(build(account: uuid(2)), throwsStateError);
      await expectLater(build(bundle: first), throwsStateError);
      await expectLater(
        build(
          bundle: KeyBundle(accountId: uuidBytes(uuid(2)), keyVersion: 2, kx1PublicKey: kx1, sig1PublicKey: newPair.publicKey),
        ),
        throwsStateError,
      );
    });
  });

  group('after a rekey', () {
    // Seals are made to real kx1 keys, which a filler of the right length is not
    late Person a;
    late Person b;
    late Person b2;

    setUpAll(() async {
      a = Person(1, kx1PublicKey: await Kx1.publicKeyOf(_seq(96, 11)));
      b = Person(2, kx1PublicKey: await Kx1.publicKeyOf(_seq(96, 77)));
      b2 = Person(2, keyVersion: 2, kx1PublicKey: await Kx1.publicKeyOf(_seq(96, 120)));
    });

    test('the member awaits seals to the new bundle, and any holder seals them, themselves included', () async {
      final chain = ChainBuilder(space)
        ..create(a)
        ..invite(a, b, grants: {everyone: CollectionPermission.edit})
        ..confirm(a, b)
        ..seal(a, [const KeyRef.space(), KeyRef.collection(everyone)])
        ..rekey(b, b2);
      final state = chain.state;
      expect(state.holds(const KeyRef.space(), b.id), isTrue);
      expect(state.awaiting(const KeyRef.space()), [b.id]);
      expect(state.awaiting(KeyRef.collection(everyone)), [b.id]);
      final record = (await buildSealRecord(
        state: state,
        signer: a.id,
        keys: {const KeyRef.space(): _seq(32, 1), KeyRef.collection(everyone): _seq(32, 2)},
        at: 9,
      ))!;
      expect(record.boxes[const KeyRef.space()]!.keys, [b.id]);
      chain.add(a, ChainKind.seal, record.entry.body);
      expect(chain.state.awaiting(const KeyRef.space()), isEmpty);
      expect(chain.state.sealOf(const KeyRef.space(), b.id)!.bundleVersion, 2);
    });

    test('lists the spaces where the account is the only confirmed Owner, for the warning', () {
      final sole = ChainBuilder(space)..create(a);
      final shared = ChainBuilder(uuid(0x5b))
        ..create(a)
        ..invite(a, b)
        ..confirm(a, b)
        ..role(a, b, SpaceRole.owner);
      final other = ChainBuilder(uuid(0x5c))
        ..create(b)
        ..invite(b, a)
        ..confirm(b, a);
      final states = {space: sole.state, uuid(0x5b): shared.state, uuid(0x5c): other.state};
      expect(soleOwnerOf(a.id, states), [space]);
      expect(soleOwnerOf(b.id, states), [uuid(0x5c)]);
    });
  });
}
