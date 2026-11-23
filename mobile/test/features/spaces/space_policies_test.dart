import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/space_policies.dart';
import 'package:kemlock/features/spaces/space_state.dart';

import 'chain_kit.dart';
import 'policy_kit.dart';

// What a space's policies are taken from, and who they apply to (docs/plans/add-server-spaces.md, task 7.1; the space
// chain section of docs/crypto.md, "Using the state"): only the verified chain's policy set, only while the chain shows
// the account a confirmed member.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final sam = Person(1);
  final ana = Person(2);
  final theo = Person(3);

  /// Sam owns the space; Ana is its Admin and Theo a Member, both confirmed. Require SSO is [sso].
  ChainBuilder chainOf({bool sso = true}) {
    final chain = ChainBuilder(space)
      ..create(sam, collection: everyone)
      ..invite(sam, ana, role: SpaceRole.admin)
      ..confirm(sam, ana)
      ..invite(sam, theo)
      ..confirm(sam, theo);
    if (sso) {
      chain.policies(sam, {'requireSso': true});
    }
    return chain;
  }

  SpacePolicies held(ChainBuilder chain, Person who) => const SpacePolicies().remembering(space, who.id, chain.state);

  group('Require SSO', () {
    test('applies to a Member, whose sign-in then offers SSO alone', () {
      expect(held(chainOf(), theo).requiresSso, isTrue);
    });

    test('never applies to the space’s Owner or an Admin, who keep every way in', () {
      expect(held(chainOf(), sam).requiresSso, isFalse);
      expect(held(chainOf(), ana).requiresSso, isFalse);
    });

    test('applies to a Custom member as it does to a Member', () {
      final chain = chainOf()..role(sam, theo, SpaceRole.custom, custom: [CustomPermission.createCollections]);

      expect(held(chain, theo).requiresSso, isTrue);
    });

    test('is off when the verified chain says off', () {
      expect(held(chainOf(sso: false), theo).requiresSso, isFalse);
    });

    test('doesn’t apply to an invitation not yet confirmed, and the space is forgotten', () {
      final chain = chainOf()..invite(sam, Person(4));

      final policies = held(chain, Person(4));

      expect(policies.spaces, isEmpty);
      expect(policies.requiresSso, isFalse);
    });

    test('stops applying once the member is removed', () {
      final chain = chainOf();
      final before = held(chain, theo);
      expect(before.requiresSso, isTrue);

      chain.remove(sam, theo);
      final after = before.remembering(space, theo.id, chain.state);

      expect(after.spaces, isEmpty);
      expect(after.requiresSso, isFalse);
    });

    test('follows the next chain: turned off by an Admin, it is off', () {
      final chain = chainOf();
      final before = held(chain, theo);

      chain.policies(ana, {'requireSso': false});

      expect(before.remembering(space, theo.id, chain.state).requiresSso, isFalse);
    });

    test('holds when any one space of several requires it', () {
      final other = uuid(0x5b);
      final plain = ChainBuilder(other)
        ..create(sam, collection: uuid(0xe1))
        ..invite(sam, theo)
        ..confirm(sam, theo);

      final policies = held(chainOf(), theo).remembering(other, theo.id, plain.state);

      expect(policies.spaces.keys, containsAll([space, other]));
      expect(policies.requiresSso, isTrue);
    });
  });

  group('the record that turned a flag on', () {
    test('is its seq while the flag is on, and null while it is off', () {
      final chain = chainOf(sso: false);
      expect(chain.state.flagSince('duplicateMatching'), isNull);

      final on = chain.policies(sam, {'duplicateMatching': true});

      expect(chain.state.flagSince('duplicateMatching'), on.entry.seq);
      expect(chain.state.flagSince('requireSso'), isNull);
    });

    test('stays while the flag stays on through other changes', () {
      final chain = chainOf(sso: false);
      final on = chain.policies(sam, {'duplicateMatching': true});

      chain.policies(ana, {'requireSso': true});

      expect(chain.state.flagSince('duplicateMatching'), on.entry.seq, reason: 'a notice shown once is not shown again');
      expect(chain.state.flagSince('requireSso'), greaterThan(on.entry.seq));
    });

    test('is a new number when the flag is turned off and on again, which is a new notice', () {
      final chain = chainOf(sso: false);
      final first = chain.policies(sam, {'duplicateMatching': true});
      chain.policies(sam, {'duplicateMatching': false});
      expect(chain.state.flagSince('duplicateMatching'), isNull);

      final second = chain.policies(sam, {'duplicateMatching': true});

      expect(chain.state.flagSince('duplicateMatching'), second.entry.seq);
      expect(second.entry.seq, greaterThan(first.entry.seq));
    });
  });

  group('no export', () {
    test('names the spaces whose verified chain forbids it, for every member of them', () {
      final policies = const SpacePolicies()
          .remembering(uuid(0x5a), theo.id, spaceWithPolicies(0x5a, theo, {'disableExport': true}))
          .remembering(uuid(0x5b), theo.id, spaceWithPolicies(0x5b, theo));

      expect(policies.noExport, {uuid(0x5a)});
      expect(policies.known, {uuid(0x5a), uuid(0x5b)}, reason: 'both chains were read');
    });

    test('does not name a space the account isn’t a member of, or hasn’t been read', () {
      final invited = const SpacePolicies().remembering(uuid(0x5a), theo.id, spaceWithPolicies(0x5a, theo, {'disableExport': true}, false));

      expect(invited.noExport, isEmpty);
      expect(invited.known, isEmpty);
    });
  });

  group('one space per member', () {
    final here = uuid(0x5a);
    final other = uuid(0x5b);

    SpacePolicies inSpace(int n, {bool single = false, String? name}) {
      final held = const SpacePolicies().remembering(uuid(n), theo.id, spaceWithPolicies(n, theo, {if (single) 'singleSpace': true}));
      return name == null ? held : held.naming(uuid(n), name);
    }

    test('asks nothing of an account that is in no other space, though the space it joins allows one', () {
      final joining = spaceWithPolicies(0x5a, theo, {'singleSpace': true}, false);

      expect(const SpacePolicies().leaveFirstFor(here, joining), isNull);
    });

    test('asks the account to leave a space it is in that allows one, before it joins another', () {
      final policies = inSpace(0x5b, single: true, name: 'Example Co');

      final leave = policies.leaveFirstFor(here, spaceWithPolicies(0x5a, theo, {}, false))!;

      expect(leave.space, other);
      expect(leave.byCurrent, isTrue);
      expect(leave.label, 'Example Co');
    });

    test('asks it to leave the space it is in when the space it would join allows only one', () {
      final policies = inSpace(0x5b);

      final leave = policies.leaveFirstFor(here, spaceWithPolicies(0x5a, theo, {'singleSpace': true}, false))!;

      expect(leave.space, other);
      expect(leave.byCurrent, isFalse);
      expect(leave.label, shortSpaceId(other), reason: 'a space with no name shows the start of its id');
    });

    test('asks nothing when neither space allows only one, or of the space it is already in', () {
      final policies = inSpace(0x5b);
      final plain = spaceWithPolicies(0x5a, theo, {}, false);

      expect(policies.leaveFirstFor(here, plain), isNull);
      expect(inSpace(0x5a, single: true).leaveFirstFor(here, plain), isNull, reason: 'it is this space itself');
    });

    test('counts an invitation as no membership: the invited space’s own rule doesn’t hold the account in it', () {
      final held = const SpacePolicies().remembering(other, theo.id, spaceWithPolicies(0x5b, theo, {'singleSpace': true}, false));

      expect(held.leaveFirstFor(here, spaceWithPolicies(0x5a, theo, {}, false)), isNull);
    });

    test('counts an invitation the account accepted as a membership, for one space per member alone', () {
      final invited = spaceWithPolicies(0x5b, theo, {'singleSpace': true, 'disableExport': true}, false);
      final held = const SpacePolicies().remembering(other, theo.id, invited, accepted: true);

      final leave = held.leaveFirstFor(here, spaceWithPolicies(0x5a, theo, {}, false))!;
      expect(leave.space, other);
      expect(leave.byCurrent, isTrue);
      expect(held.noExport, isEmpty, reason: 'its other policies don’t apply until the account is a member');
      expect(held.known, isEmpty);
      expect(held.requiresSso, isFalse);
      // The chain read again says nothing of the list, so it keeps what was known; the list saying otherwise takes it out
      expect(held.remembering(other, theo.id, invited).spaces.keys, [other]);
      expect(held.remembering(other, theo.id, invited, accepted: false).spaces, isEmpty);
    });

    test('counts an accepted invitation to a space that allows one against joining another, from either side', () {
      final plain = spaceWithPolicies(0x5b, theo, {}, false);
      final held = const SpacePolicies().remembering(other, theo.id, plain, accepted: true);

      final leave = held.leaveFirstFor(here, spaceWithPolicies(0x5a, theo, {'singleSpace': true}, false))!;

      expect(leave.space, other);
      expect(leave.byCurrent, isFalse);
    });

    test('stops counting an accepted invitation once the account is removed from the space', () {
      final chain = ChainBuilder(other)
        ..create(policyOwner, collection: uuid(0xe0 + 0x5b))
        ..invite(policyOwner, theo)
        ..policies(policyOwner, {'singleSpace': true});
      final held = const SpacePolicies().remembering(other, theo.id, chain.state, accepted: true);
      expect(held.leaveFirstBeforeMaking(), isNotNull);

      chain.remove(policyOwner, theo);

      expect(held.remembering(other, theo.id, chain.state).spaces, isEmpty);
    });
  });

  group('making a space', () {
    final other = uuid(0x5b);

    test('is open to an account in no space, or in spaces that allow more than one', () {
      expect(const SpacePolicies().leaveFirstBeforeMaking(), isNull);
      expect(const SpacePolicies().remembering(other, theo.id, spaceWithPolicies(0x5b, theo)).leaveFirstBeforeMaking(), isNull);
    });

    test('is refused to a member of a space that allows one, which it names', () {
      final held = const SpacePolicies()
          .remembering(other, theo.id, spaceWithPolicies(0x5b, theo, {'singleSpace': true}))
          .naming(other, 'Example Co');

      final blocked = held.leaveFirstBeforeMaking()!;

      expect(blocked.space, other);
      expect(blocked.label, 'Example Co');
      expect(blocked.byCurrent, isTrue);
    });

    test('is refused to an account that accepted an invitation to a space that allows one, but not to one that hasn’t', () {
      final invited = spaceWithPolicies(0x5b, theo, {'singleSpace': true}, false);

      expect(const SpacePolicies().remembering(other, theo.id, invited, accepted: true).leaveFirstBeforeMaking(), isNotNull);
      expect(const SpacePolicies().remembering(other, theo.id, invited).leaveFirstBeforeMaking(), isNull);
    });
  });

  group('being in two spaces when one allows only one', () {
    final first = uuid(0x5a);
    final second = uuid(0x5b);

    SpacePolicies inBoth({bool firstSingle = false, bool secondSingle = false}) => const SpacePolicies()
        .remembering(first, theo.id, spaceWithPolicies(0x5a, theo, {if (firstSingle) 'singleSpace': true}))
        .remembering(second, theo.id, spaceWithPolicies(0x5b, theo, {if (secondSingle) 'singleSpace': true}))
        .naming(second, 'Example Co');

    test('says which to leave one of, when the policy was turned on after the account joined a second', () {
      final leave = inBoth(secondSingle: true).leaveOne!;

      expect(leave.single, second);
      expect(leave.other, first);
      expect(leave.singleLabel, 'Example Co');
      expect(leave.otherLabel, shortSpaceId(first));
      expect(inBoth(firstSingle: true).leaveOne!.single, first);
    });

    test('says nothing when neither space allows only one, or the account is in one space, or only invited to the other', () {
      expect(inBoth().leaveOne, isNull);
      expect(const SpacePolicies().remembering(first, theo.id, spaceWithPolicies(0x5a, theo, {'singleSpace': true})).leaveOne, isNull);
      final invited = const SpacePolicies()
          .remembering(first, theo.id, spaceWithPolicies(0x5a, theo, {'singleSpace': true}))
          .remembering(second, theo.id, spaceWithPolicies(0x5b, theo, {}, false), accepted: true);
      expect(invited.leaveOne, isNull, reason: 'one of them is not a membership yet, which the invitation screen holds back');
    });
  });

  group('the master password’s minimum length', () {
    SpacePolicies asking(Map<int, int> lengths) {
      var held = const SpacePolicies();
      for (final MapEntry(:key, :value) in lengths.entries) {
        held = held.remembering(uuid(key), theo.id, spaceWithPolicies(key, theo, {'masterPassword': masterPasswordOf(value)}));
      }
      return held;
    }

    test('refuses a 12-character password where a space requires 14, and takes one of 14', () {
      final policies = asking({0x5a: 14});

      final short = policies.shortfallsOf('twelve-chars');

      expect(short, hasLength(1));
      expect(short.single.space, uuid(0x5a));
      expect(short.single.minimum, 14);
      expect(policies.shortfallsOf('fourteen-chars'), isEmpty);
    });

    test('names the space asking for the most first, and counts characters as the vault does', () {
      final policies = asking({0x5a: 14, 0x5b: 20});

      expect([for (final short in policies.shortfallsOf('twelve-chars')) short.minimum], [20, 14]);
      expect(asking({0x5a: 14}).shortfallsOf('😀' * 14), isEmpty, reason: 'fourteen characters, whatever their bytes');
    });

    test('asks nothing of a space with no minimum, or one the account isn’t a member of', () {
      final plain = const SpacePolicies().remembering(uuid(0x5a), theo.id, spaceWithPolicies(0x5a, theo, {'twoStep': true}));
      expect(plain.shortfallsOf('a'), isEmpty);
      final invited = const SpacePolicies().remembering(
        uuid(0x5a),
        theo.id,
        spaceWithPolicies(0x5a, theo, {'masterPassword': masterPasswordOf(30)}, false),
      );
      expect(invited.shortfallsOf('a'), isEmpty);
    });
  });
}
