// Replacing a member's own key pair in a space (the space chain section of docs/crypto.md, `rekey`): before the
// account lets go of its old private keys, it signs a `rekey` in every space, with the old key's signature and the new
// key's cosignature, so the chain's record of the member moves to the new bundle and the member keeps signing. Nobody
// compared the new fingerprint: the old key vouched for it, and the app shows "<name> replaced their keys" and offers to
// compare. A member who rekeys then awaits seals to the new bundle, and any holder (themselves included, who still hold
// the keys) seals them with `buildSealRecord` in space_seals.dart.
//
// A space with a single confirmed Owner who loses the old key before this can't be repaired by anyone, so the app warns
// while a space has only one ([soleOwnerOf]).
//
// Pure Dart, no Flutter.

library;

import 'dart:typed_data';

import '../../crypto/account/bundle.dart';
import '../../crypto/account/encoding.dart';
import '../../crypto/account/sig1.dart';
import 'space_chain.dart';
import 'space_state.dart';

/// A `rekey` of [account] in [state]'s space: [newBundle], with its self-[newBundleSignature], signed by the old `sig1`
/// private key and cosigned by the new one. The record follows [state]'s head, in its epoch. Throws a [StateError] when
/// the account isn't confirmed in the space, or the bundle isn't of a newer key version.
Future<SignedChainEntry> buildRekey({
  required SpaceState state,
  required String account,
  required KeyBundle newBundle,
  required Uint8List newBundleSignature,
  required Uint8List oldSig1PrivateKey,
  required Uint8List newSig1PrivateKey,
  required int at,
}) async {
  final member = state.member(account);
  final known = member?.bundle;
  if (member == null || !member.isConfirmed || known == null) {
    throw StateError('$account is not confirmed in the space');
  }
  if (!_isAccountOf(newBundle, account) || newBundle.keyVersion <= known.keyVersion) {
    throw StateError('a rekey is a bundle of this account and of a newer key version than ${known.keyVersion}');
  }
  final entry = SpaceChainEntry(
    space: state.space,
    seq: state.nextSeq,
    prev: state.headHash ?? chainGenesisLink,
    epoch: state.epoch,
    at: at,
    by: account,
    kind: ChainKind.rekey,
    body: {'bundle': b64urlEncode(newBundle.bytes), 'bundleSignature': b64urlEncode(newBundleSignature)},
  );
  return SignedChainEntry(
    entry,
    await Sig1.sign(oldSig1PrivateKey, entry.bytes, context: SignContext.spaceChain),
    cosignature: await Sig1.sign(newSig1PrivateKey, entry.bytes, context: SignContext.spaceChain),
  );
}

bool _isAccountOf(KeyBundle bundle, String account) => uuidText(bundle.accountId) == account;

/// The spaces in [states] (by space id) where [account] is the only confirmed Owner: a key lost there can't be
/// replaced by anyone, so the app warns while the account has only the one key pair.
List<String> soleOwnerOf(String account, Map<String, SpaceState> states) => [
  for (final entry in states.entries)
    if (entry.value.member(account)?.role == SpaceRole.owner &&
        entry.value.member(account)!.isConfirmed &&
        entry.value.confirmedOwners == 1)
      entry.key,
];
