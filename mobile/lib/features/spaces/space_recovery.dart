// Account recovery enrolment (docs/plans/add-server-spaces.md, task 7.2; the space chain section of docs/crypto.md, "Using
// the state": "Account recovery enrolment seals the member's root key under the "account-recovery" context only to the
// chain's recovery key, only while accountRecovery is on, only after first contact, and only after the member agrees").
//
// A space whose Owner recorded a recovery key and turned the policy on lets its admins reset a member's master password
// and open their vault. That works only if the member's root key was sealed to the recovery key, which is the sealed box
// of crypto.md under the context "account-recovery". Nothing is sealed until the member has agreed, and the key it is
// sealed to is the one the verified chain records: a key the server hands over, or one that differs from the chain's by a
// byte, is refused before anything is sealed. The reset itself is the web vault's (the plan's "Out of scope").
//
// The box is bound to the space, the member and the chain record that set the recovery key, as Kemlock Server pins it:
// `aad = space id (16) || account id (16) || u64be(seq of that record)` ([recoveryAad]). A box moved to another space or
// member, or kept past a replaced recovery key, doesn't open. It goes to `PUT /kem/v1/spaces/{id}/members/me/recovery` as
// `{box, keySeq}`, which the server refuses with 409 `stale-recovery-key` when `keySeq` isn't the chain's current record.
//
// Pure Dart, no Flutter.

library;

import 'dart:typed_data';

import '../../crypto/account/encoding.dart' show isUuidText, u64be, uuidBytes;
import '../../crypto/account/keys.dart' show rootKeyLength;
import '../../crypto/account/sealed_box.dart';
import '../../crypto/bytes.dart' show constantTimeEquals;
import 'space_state.dart';

/// Why an enrolment was not made.
enum RecoveryRefusal {
  /// The member hasn't agreed.
  notAgreed,

  /// This device hasn't done first contact with the space: no fingerprint was compared (`SpaceAnchors.hasCompared`). An anchor
  /// alone is not it, since reading a chain stores none and a server could make a chain up.
  noFirstContact,

  /// The verified chain doesn't show the account a confirmed member.
  notMember,

  /// The verified chain has account recovery off.
  off,

  /// The verified chain records no recovery key, which no Owner signed.
  noKey,

  /// The key offered isn't the chain's recovery key.
  otherKey,

  /// The root key isn't the length of one.
  badRoot,

  /// The space's or the account's id isn't a UUID, so the box can't be bound to them ([recoveryAad] needs both as 16 bytes).
  badId,
}

/// An enrolment that was refused, before anything was sealed.
class RecoveryRefused implements Exception {
  const RecoveryRefused(this.reason);

  final RecoveryRefusal reason;

  @override
  String toString() => 'RecoveryRefused(${reason.name})';
}

/// Whether [state] asks [account] to enrol: account recovery is on in the verified chain and the account is a confirmed
/// member. A chain that has the policy on without a recovery key can't be (the chain refuses such a record), and here
/// it asks for nothing.
bool recoveryAsked(SpaceState state, String account) {
  final me = state.member(account);
  return me != null && me.isConfirmed && state.policies['accountRecovery'] == true && state.recoveryKey != null;
}

/// The extra binding of an enrolment box: `space id (16) || account id (16) || u64be(keySeq)`, where [keySeq] is the `seq`
/// of the chain record that set the recovery key. An admin's client opens the box with the same.
Uint8List recoveryAad(String space, String account, int keySeq) =>
    Uint8List.fromList([...uuidBytes(space), ...uuidBytes(account), ...u64be(keySeq)]);

/// An enrolment: the box, and the `seq` of the recovery-key record it is bound to, which the PUT carries as `keySeq`.
typedef RecoveryEnrolment = ({Uint8List box, int keySeq});

/// Seals [rootKey], the 64-byte root of the member's account, to the recovery key the verified chain [state] records
/// for [account], and gives the box (`sealBox` under `"account-recovery"`, with [recoveryAad]) and its `keySeq`.
///
/// [offeredKey] is the recovery key the caller was given by whoever it came from (the server, a list); it is only compared
/// with the chain's, and the box is made to the chain's own copy. Refused, with [RecoveryRefused] and nothing sealed,
/// when the member hasn't [agreed], when this device hasn't done first contact ([firstContact]: a fingerprint of the space was
/// compared here or on another device of the account, `SpaceAnchors.hasCompared`, never just an anchor), when the chain doesn't
/// show [account] confirmed, when it has account recovery off or no recovery key, or when
/// [offeredKey] isn't the chain's.
Future<RecoveryEnrolment> sealRecoveryEnrolment({
  required SpaceState state,
  required String account,
  required Uint8List rootKey,
  required Uint8List offeredKey,
  required bool agreed,
  required bool firstContact,
}) async {
  // Before anything else: an id that isn't a UUID would make `uuidBytes` throw a MalformedException, which is no refusal
  if (!isUuidText(state.space) || !isUuidText(account)) {
    throw const RecoveryRefused(RecoveryRefusal.badId);
  }
  if (!agreed) {
    throw const RecoveryRefused(RecoveryRefusal.notAgreed);
  }
  if (!firstContact) {
    throw const RecoveryRefused(RecoveryRefusal.noFirstContact);
  }
  final me = state.member(account);
  if (me == null || !me.isConfirmed) {
    throw const RecoveryRefused(RecoveryRefusal.notMember);
  }
  if (state.policies['accountRecovery'] != true) {
    throw const RecoveryRefused(RecoveryRefusal.off);
  }
  final chainKey = state.recoveryKey;
  final keySeq = state.recoveryKeySeq;
  if (chainKey == null || keySeq == null) {
    throw const RecoveryRefused(RecoveryRefusal.noKey);
  }
  if (!constantTimeEquals(chainKey, offeredKey)) {
    throw const RecoveryRefused(RecoveryRefusal.otherKey);
  }
  if (rootKey.length != rootKeyLength) {
    throw const RecoveryRefused(RecoveryRefusal.badRoot);
  }
  final box = await sealBox(chainKey, rootKey, context: SealContext.accountRecovery, aad: recoveryAad(state.space, account, keySeq));
  return (box: box, keySeq: keySeq);
}
