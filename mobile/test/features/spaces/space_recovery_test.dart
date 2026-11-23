import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/sealed_box.dart';
import 'package:kemlock/features/spaces/chain_kind.dart';
import 'package:kemlock/features/spaces/space_recovery.dart';
import 'package:kemlock/features/spaces/space_state.dart';

import 'chain_kit.dart';

// Account recovery enrolment (docs/plans/add-server-spaces.md, task 7.2; the space chain section of docs/crypto.md, "Using
// the state"): the root key is sealed under "account-recovery" only to the chain's recovery key, only while the policy is
// on, only after first contact and only after the member agrees. Real keys: the box is opened with the recovery key's
// private half.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final sam = Person(1);
  final theo = Person(3);
  final root = Uint8List.fromList(List.generate(64, (i) => (i * 5 + 1) & 0xff));
  late ({Uint8List publicKey, Uint8List privateKey}) recovery;
  late ({Uint8List publicKey, Uint8List privateKey}) other;

  setUpAll(() async {
    recovery = await Kx1.generate(Uint8List.fromList(List.generate(Kx1.privateKeyLength, (i) => (i * 3 + 2) & 0xff)));
    other = await Kx1.generate(Uint8List.fromList(List.generate(Kx1.privateKeyLength, (i) => (i * 7 + 9) & 0xff)));
  });

  /// Sam's space, with Theo a confirmed Member, [recoveryKey] recorded by Sam and account recovery on when [on].
  SpaceState chainOf({Uint8List? recoveryKey, bool on = true, bool confirmed = true}) {
    final chain = ChainBuilder(space)
      ..create(sam, collection: everyone)
      ..invite(sam, theo);
    if (confirmed) {
      chain.confirm(sam, theo);
    }
    if (recoveryKey != null) {
      chain.add(sam, ChainKind.recoveryKey, {'key': b64urlEncode(recoveryKey)});
      if (on) {
        chain.policies(sam, {'accountRecovery': true});
      }
    }
    return chain.state;
  }

  Future<Uint8List> seal(
    SpaceState state, {
    Uint8List? offered,
    Uint8List? rootKey,
    bool agreed = true,
    bool firstContact = true,
    String? account,
  }) async => (await sealRecoveryEnrolment(
    state: state,
    account: account ?? theo.id,
    rootKey: rootKey ?? root,
    offeredKey: offered ?? recovery.publicKey,
    agreed: agreed,
    firstContact: firstContact,
  )).box;

  /// The aad of Theo's box in [state]'s space, bound to its recovery-key record.
  Uint8List aadOf(SpaceState state, {String? account}) => recoveryAad(space, account ?? theo.id, state.recoveryKeySeq!);

  Matcher refusedAs(RecoveryRefusal reason) => throwsA(isA<RecoveryRefused>().having((e) => e.reason, 'reason', reason));

  group('an enrolment', () {
    test('is the root key in the sealed box under "account-recovery", opened by the recovery key alone', () async {
      final state = chainOf(recoveryKey: recovery.publicKey);
      final box = await seal(state);
      final aad = aadOf(state);

      expect(box, hasLength(1 + 1600 + 12 + 64 + 16));
      expect(await openBox(box, recovery.privateKey, context: SealContext.accountRecovery, aad: aad), root);
      await expectLater(openBox(box, recovery.privateKey, context: SealContext.spaceKey, aad: aad), throwsA(isA<CorruptedException>()));
      await expectLater(openBox(box, other.privateKey, context: SealContext.accountRecovery, aad: aad), throwsA(isA<CorruptedException>()));
    });

    test('is bound to the space, the member and the record that set the key, and names that record', () async {
      final state = chainOf(recoveryKey: recovery.publicKey);
      final enrolment = await sealRecoveryEnrolment(
        state: state,
        account: theo.id,
        rootKey: root,
        offeredKey: recovery.publicKey,
        agreed: true,
        firstContact: true,
      );
      final keySeq = state.recoveryKeySeq!;

      expect(enrolment.keySeq, keySeq);
      expect(recoveryAad(space, theo.id, keySeq), [...uuidBytes(space), ...uuidBytes(theo.id), ...u64be(keySeq)]);
      Future<Uint8List> open(List<int> aad) => openBox(enrolment.box, recovery.privateKey, context: SealContext.accountRecovery, aad: aad);
      expect(await open(recoveryAad(space, theo.id, keySeq)), root);
      for (final aad in [
        const <int>[],
        recoveryAad(uuid(0x5b), theo.id, keySeq),
        recoveryAad(space, sam.id, keySeq),
        recoveryAad(space, theo.id, keySeq + 1),
      ]) {
        await expectLater(open(aad), throwsA(isA<CorruptedException>()));
      }
    });

    test('is sealed to the chain’s own copy of the key, which the offered one only has to equal', () async {
      final state = chainOf(recoveryKey: recovery.publicKey);

      final box = await seal(state, offered: Uint8List.fromList(recovery.publicKey));

      expect(await openBox(box, recovery.privateKey, context: SealContext.accountRecovery, aad: aadOf(state)), root);
    });
  });

  group('the record the box is bound to', () {
    /// Sam's space with Theo confirmed, [recovery] recorded and account recovery on.
    ChainBuilder recordedChain() => ChainBuilder(space)
      ..create(sam, collection: everyone)
      ..invite(sam, theo)
      ..confirm(sam, theo)
      ..add(sam, ChainKind.recoveryKey, {'key': b64urlEncode(recovery.publicKey)})
      ..policies(sam, {'accountRecovery': true});

    test('is the one that replaced the key: its keySeq moves, the box is bound to it, and the old key is refused', () async {
      final chain = recordedChain();
      final before = chain.state;
      final oldBox = await seal(before);

      final replaced = chain.add(sam, ChainKind.recoveryKey, {'key': b64urlEncode(other.publicKey)});
      final after = chain.state;

      expect(after.recoveryKeySeq, replaced.entry.seq);
      expect(after.recoveryKeySeq, greaterThan(before.recoveryKeySeq!));
      final enrolment = await sealRecoveryEnrolment(
        state: after,
        account: theo.id,
        rootKey: root,
        offeredKey: other.publicKey,
        agreed: true,
        firstContact: true,
      );
      expect(enrolment.keySeq, replaced.entry.seq);
      expect(
        await openBox(enrolment.box, other.privateKey, context: SealContext.accountRecovery, aad: aadOf(after)),
        root,
        reason: 'sealed to the new key, bound to the new record',
      );
      await expectLater(
        seal(after, offered: recovery.publicKey),
        refusedAs(RecoveryRefusal.otherKey),
        reason: 'the old key is no longer the chain’s',
      );
      // The box of the old key doesn't open under the new record's number
      await expectLater(
        openBox(oldBox, recovery.privateKey, context: SealContext.accountRecovery, aad: aadOf(after)),
        throwsA(isA<CorruptedException>()),
      );
      expect(await openBox(oldBox, recovery.privateKey, context: SealContext.accountRecovery, aad: aadOf(before)), root);
    });

    test('is the one that set the key again after it was cleared: a box from before doesn’t open with the new keySeq', () async {
      final chain = recordedChain();
      final before = chain.state;
      final oldBox = await seal(before);

      chain
        ..policies(sam, {'accountRecovery': false})
        ..recoveryKeyClear(sam);
      expect(chain.state.recoveryKey, isNull);
      final reset = chain.add(sam, ChainKind.recoveryKey, {'key': b64urlEncode(recovery.publicKey)});
      chain.policies(sam, {'accountRecovery': true});
      final after = chain.state;

      expect(after.recoveryKey, recovery.publicKey, reason: 'the same key, set again');
      expect(after.recoveryKeySeq, reset.entry.seq);
      expect(after.recoveryKeySeq, greaterThan(before.recoveryKeySeq!));
      await expectLater(
        openBox(oldBox, recovery.privateKey, context: SealContext.accountRecovery, aad: aadOf(after)),
        throwsA(isA<CorruptedException>()),
        reason: 'the old box names the old record, so a stale enrolment can’t pass for the new one',
      );
      final fresh = await seal(after);
      expect(await openBox(fresh, recovery.privateKey, context: SealContext.accountRecovery, aad: aadOf(after)), root);
    });
  });

  group('nothing is sealed', () {
    test('before the member agrees', () async {
      await expectLater(seal(chainOf(recoveryKey: recovery.publicKey), agreed: false), refusedAs(RecoveryRefusal.notAgreed));
    });

    test('to a recovery key outside the chain: another key, a key a byte off, or a short one', () async {
      final state = chainOf(recoveryKey: recovery.publicKey);
      final off = Uint8List.fromList(recovery.publicKey)..[700] ^= 1;

      await expectLater(seal(state, offered: other.publicKey), refusedAs(RecoveryRefusal.otherKey));
      await expectLater(seal(state, offered: off), refusedAs(RecoveryRefusal.otherKey));
      await expectLater(seal(state, offered: Uint8List(10)), refusedAs(RecoveryRefusal.otherKey));
    });

    test('when the chain records no recovery key, even for a key a server offers', () async {
      await expectLater(seal(chainOf(), offered: other.publicKey), refusedAs(RecoveryRefusal.off));
    });

    test('while account recovery is off, though the chain holds a recovery key', () async {
      await expectLater(seal(chainOf(recoveryKey: recovery.publicKey, on: false)), refusedAs(RecoveryRefusal.off));
    });

    test('for an id that isn’t a UUID: a refusal, never a MalformedException from the box’s binding', () async {
      final state = chainOf(recoveryKey: recovery.publicKey);

      await expectLater(seal(state, account: 'theo'), refusedAs(RecoveryRefusal.badId));
      await expectLater(seal(state, account: '${theo.id}0'), refusedAs(RecoveryRefusal.badId));
      await expectLater(seal(state, account: ''), refusedAs(RecoveryRefusal.badId));
      // First, whatever else is wrong
      await expectLater(seal(state, account: 'theo', agreed: false), refusedAs(RecoveryRefusal.badId));
    });

    test('before first contact, for a member the chain doesn’t confirm, or a root of the wrong length', () async {
      final state = chainOf(recoveryKey: recovery.publicKey);

      await expectLater(seal(state, firstContact: false), refusedAs(RecoveryRefusal.noFirstContact));
      await expectLater(seal(chainOf(recoveryKey: recovery.publicKey, confirmed: false)), refusedAs(RecoveryRefusal.notMember));
      await expectLater(seal(state, account: uuid(99)), refusedAs(RecoveryRefusal.notMember));
      await expectLater(seal(state, rootKey: Uint8List(32)), refusedAs(RecoveryRefusal.badRoot));
    });
  });

  group('who is asked', () {
    test('a confirmed member of a space with account recovery on and a recovery key', () {
      expect(recoveryAsked(chainOf(recoveryKey: recovery.publicKey), theo.id), isTrue);
    });

    test('nobody while it is off, and not an invitation, or a stranger', () {
      expect(recoveryAsked(chainOf(recoveryKey: recovery.publicKey, on: false), theo.id), isFalse);
      expect(recoveryAsked(chainOf(recoveryKey: recovery.publicKey, confirmed: false), theo.id), isFalse);
      expect(recoveryAsked(chainOf(recoveryKey: recovery.publicKey), uuid(99)), isFalse);
    });
  });
}
