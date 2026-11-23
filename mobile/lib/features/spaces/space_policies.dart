// What the spaces' policies ask of this device (docs/plans/add-server-spaces.md, task group 7; the space chain section of
// docs/crypto.md, "Using the state": "Policies and recovery come from the chain's policy set").
//
// A policy is read from one place only: the policy set of a space's verified chain (`SpaceState.policies`), which an
// Owner or an Admin signed. Nothing the server says beside the chain, in a list of spaces or in an answer of its own,
// is looked at. A space counts only while the verified chain shows this account a confirmed member of it: an invitation
// has no force, and a space the account left, or can't be checked, is forgotten.
//
// [SpacePolicies] holds the chains each run of a space verified (`KmSpaceSync.onChain`), in memory. Until a space has
// reported its chain, none of its policies is known and none is applied here; the callers that must fail closed (an
// export) say so themselves.
//
// Pure Dart, no Flutter.

library;

import 'space_state.dart';

/// One space's verified chain and the account whose app this is.
class SpacePolicyHold {
  const SpacePolicyHold({required this.chain, required this.account, this.name, this.email, this.accepted = false});

  final SpaceState chain;
  final String account;

  /// The email the account signed in with, as the vault's Kemlock settings had it when the chain was read, or null. Sign-in
  /// knows only the email typed, so this is how a space's policy is tied to the account that signs in.
  final String? email;

  /// The space's name when the chain's commitment opened it, else null.
  final String? name;

  /// Whether the server's list says the account accepted its invitation to the space. The chain doesn't record it, and only
  /// one space per member reads it ([acceptedInvitation]).
  final bool accepted;

  /// The account's place in the space as the chain has it, or null when it has none.
  SpaceMember? get me => chain.member(account);

  /// Whether the chain shows the account a confirmed member, which is when the space's policies apply to it.
  bool get applies => me?.isConfirmed ?? false;

  /// Whether the chain shows the account invited and the list says it accepted: not a member yet, but on its way to being
  /// one, which one space per member counts as being in the space.
  bool get acceptedInvitation => accepted && me?.status == MemberStatus.invited;

  /// Whether the account is in the space as far as one space per member goes: a confirmed member, or one who accepted.
  bool get inForOneSpace => applies || acceptedInvitation;

  /// Whether the account is a Member of the space, not an Owner or an Admin. A Custom member has no more rights over
  /// the space's policies than a Member, so it counts as one.
  bool get isMember {
    final role = me?.role;
    return role == SpaceRole.member || role == SpaceRole.custom;
  }

  /// Whether the verified chain has [flag] on.
  bool on(String flag) => chain.policies[flag] == true;

  SpacePolicyHold named(String? name) =>
      SpacePolicyHold(chain: chain, account: account, name: name ?? this.name, email: email, accepted: accepted);
}

/// The start of a space's id, which names a space whose name isn't known.
String shortSpaceId(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// The space an account has to leave before it joins another, and which side asks it.
class LeaveFirst {
  const LeaveFirst({required this.space, required this.name, required this.byCurrent});

  /// The space to leave and its name when the chain's name opened.
  final String space;
  final String? name;

  /// What to call the space: its name, or the start of its id.
  String get label => name ?? shortSpaceId(space);

  /// Whether the space to leave is the one that allows only one space per member, and not the space to join.
  final bool byCurrent;
}

/// Two spaces the account is in, one of which allows only one space per member: it has to leave one of them.
class LeaveOne {
  const LeaveOne({required this.single, required this.singleName, required this.other, required this.otherName});

  /// The space that allows one space per member, and the other space the account is in; each with its name when it opened.
  final String single;
  final String? singleName;
  final String other;
  final String? otherName;

  String get singleLabel => singleName ?? shortSpaceId(single);
  String get otherLabel => otherName ?? shortSpaceId(other);
}

/// Making a space was refused: [leaveFirst] allows one space per member and the account is in it.
class SingleSpaceRefused implements Exception {
  const SingleSpaceRefused(this.leaveFirst);

  final LeaveFirst leaveFirst;

  @override
  String toString() => 'SingleSpaceRefused(${leaveFirst.space})';
}

/// A space that asks for a longer master password than the one given, and how long.
class PasswordShortfall {
  const PasswordShortfall({required this.space, required this.name, required this.minimum});

  final String space;
  final String? name;
  final int minimum;

  /// What to call the space: its name, or the start of its id.
  String get label => name ?? shortSpaceId(space);
}

/// The spaces' policies as the verified chains give them, by the space's id.
class SpacePolicies {
  const SpacePolicies([this.spaces = const {}]);

  final Map<String, SpacePolicyHold> spaces;

  /// The spaces the account is a confirmed member of, whose policies apply.
  Iterable<MapEntry<String, SpacePolicyHold>> get _applying => spaces.entries.where((entry) => entry.value.applies);

  /// Whether a space the account is a Member of requires single sign-on: sign-in then offers SSO alone. An Owner or an
  /// Admin of the space is exempt, so a space they run never takes their other ways in from them.
  bool get requiresSso => _applying.any((entry) => entry.value.isMember && entry.value.on('requireSso'));

  /// [requiresSso] for the account that signs in with [email] alone: a chain was read for the account the vault is signed in as, so
  /// the spaces held for another account say nothing about whoever signs in as someone else. The email is compared as typed,
  /// without case or surrounding spaces; a space held with no email counts for no one.
  bool requiresSsoFor(String email) {
    final typed = email.trim().toLowerCase();
    return _applying.any(
      (entry) => entry.value.email?.trim().toLowerCase() == typed && entry.value.isMember && entry.value.on('requireSso'),
    );
  }

  /// The spaces whose verified chain forbids exporting their items, for every member of them.
  Set<String> get noExport => {
    for (final entry in _applying)
      if (entry.value.on('disableExport')) entry.key,
  };

  /// The spaces the account is a confirmed member of and whose chain was read, so whose policies are known.
  Set<String> get known => {for (final entry in _applying) entry.key};

  /// The spaces the account is in as far as one space per member goes: those it is a confirmed member of, and those whose
  /// invitation it accepted and waits to be confirmed in (the chain shows it invited, the server's list says accepted).
  Iterable<MapEntry<String, SpacePolicyHold>> get _inSpaces => spaces.entries.where((entry) => entry.value.inForOneSpace);

  /// The space the account has to leave before it may join [joining], whose verified chain is [chain], or null when it may
  /// join. One space per member: a space the account is a confirmed member of that allows only one (`singleSpace`), or the
  /// space it would join allowing only one while the account is in another. Only the spaces the phone read and verified
  /// are known; an invitation the account hasn't accepted is no membership, and one it accepted counts as one.
  LeaveFirst? leaveFirstFor(String joining, SpaceState chain) {
    final others = _inSpaces.where((entry) => entry.key != joining).toList();
    if (others.isEmpty) {
      return null;
    }
    for (final entry in others) {
      if (entry.value.on('singleSpace')) {
        return LeaveFirst(space: entry.key, name: entry.value.name, byCurrent: true);
      }
    }
    if (chain.policies['singleSpace'] == true) {
      return LeaveFirst(space: others.first.key, name: others.first.value.name, byCurrent: false);
    }
    return null;
  }

  /// The space that forbids making another, or null when the account may make a space: one it is in (or accepted an invitation
  /// to) that allows only one space per member. The server has to enforce it too: this is the app's own rule.
  LeaveFirst? leaveFirstBeforeMaking() {
    for (final entry in _inSpaces) {
      if (entry.value.on('singleSpace')) {
        return LeaveFirst(space: entry.key, name: entry.value.name, byCurrent: true);
      }
    }
    return null;
  }

  /// The two spaces the account has to leave one of, or null: it is a confirmed member of two spaces and one of them allows only
  /// one space per member. That happens when a space turns the policy on after the account joined a second, or when the other
  /// was joined on another phone.
  LeaveOne? get leaveOne {
    final confirmed = _applying.toList();
    if (confirmed.length < 2) {
      return null;
    }
    for (final single in confirmed) {
      if (single.value.on('singleSpace')) {
        final other = confirmed.firstWhere((entry) => entry.key != single.key);
        return LeaveOne(single: single.key, singleName: single.value.name, other: other.key, otherName: other.value.name);
      }
    }
    return null;
  }

  /// The spaces whose minimum master password length [password] doesn't reach, the longest asked for first. A space asks
  /// nothing when its minimum is 0. The length counts characters, as the vault's own minimum does.
  List<PasswordShortfall> shortfallsOf(String password) {
    final length = password.runes.length;
    final short = <PasswordShortfall>[];
    for (final entry in _applying) {
      final master = entry.value.chain.policies['masterPassword'];
      final minimum = master is Map<String, Object?> && master['minLength'] is int ? master['minLength']! as int : 0;
      if (length < minimum) {
        short.add(PasswordShortfall(space: entry.key, name: entry.value.name, minimum: minimum));
      }
    }
    short.sort((a, b) => b.minimum.compareTo(a.minimum));
    return short;
  }

  /// The name of [space] when its chain's name opened, else null.
  String? nameOf(String space) => spaces[space]?.name;

  /// These policies with [space]'s verified [chain] for [account]. A chain that doesn't show the account confirmed
  /// takes the space out instead: its policies don't apply to someone who isn't a member. The exception is an invitation the
  /// server's list says the account [accepted] (null keeps what was known, and a read of a chain alone says nothing of it):
  /// the space is kept for one space per member and for it alone.
  SpacePolicies remembering(String space, String account, SpaceState chain, {String? email, bool? accepted}) {
    final held = spaces[space];
    final hold = SpacePolicyHold(
      chain: chain,
      account: account,
      name: held?.name,
      email: email ?? held?.email,
      accepted: accepted ?? held?.accepted ?? false,
    );
    if (!hold.inForOneSpace) {
      return forgetting(space);
    }
    return SpacePolicies({...spaces, space: hold});
  }

  /// These policies with [space]'s name, when the space is known.
  SpacePolicies naming(String space, String name) {
    final hold = spaces[space];
    return hold == null ? this : SpacePolicies({...spaces, space: hold.named(name)});
  }

  SpacePolicies forgetting(String space) => spaces.containsKey(space) ? SpacePolicies({...spaces}..remove(space)) : this;
}
