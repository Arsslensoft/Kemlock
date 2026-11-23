import 'package:kemlock/features/spaces/chain_body.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_policies_provider.dart';
import 'package:kemlock/features/spaces/space_state.dart';

import 'chain_kit.dart';

/// Sam, the Owner of the spaces [spaceWithPolicies] makes.
final policyOwner = Person(1);

/// The `masterPassword` member of a `policies` record asking for [minLength] characters.
Map<String, Object?> masterPasswordOf(int minLength) => {
  ...defaultPolicies()['masterPassword']! as Map<String, Object?>,
  'minLength': minLength,
};

/// A space (its id is `uuid(n)`) whose Owner is [policyOwner], where [member] is a confirmed Member and Sam's `policies`
/// record sets [changes] over the defaults. With no [changes] the space has no policy on.
SpaceState spaceWithPolicies(int n, Person member, [Map<String, Object?> changes = const {}, bool confirmed = true]) {
  final chain = ChainBuilder(uuid(n))
    ..create(policyOwner, collection: uuid(0xe0 + n))
    ..invite(policyOwner, member);
  if (confirmed) {
    chain.confirm(policyOwner, member);
  }
  if (changes.isNotEmpty) {
    chain.policies(policyOwner, changes);
  }
  return chain.state;
}

/// The policies a phone holds of its verified spaces, set in place of the reports a run would make.
class HeldPolicies extends SpacePoliciesNotifier {
  HeldPolicies(this._held);

  final SpacePolicies _held;

  @override
  SpacePolicies build() => _held;
}
