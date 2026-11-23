// Changes to a space made outside Kemlock clients, queued for an Admin's app to sign (docs/plans/add-server-spaces.md,
// design 2; the owner's decision of 2026-11-22). The server's Bitwarden-compatible routes and its SSO group sync change
// members, roles and grants with no signing key, which its own chain forbids (the space chain section of docs/crypto.md,
// S2): so it queues each change as a **pending change**, and an Owner's or Admin's app
//
// - lists a space's pending changes;
// - shows what each would do, worked out here from the verified chain, never taken from the server's words;
// - **approves** one by appending the matching chain record, made through the builders of `space_records.dart` and
//   signed with the approver's own `sig1` key, or
// - **drops** it, which discards it.
//
// Only a role the chain allows may approve: the record is run against the state and the authority rules
// (`SpaceState.apply`, `chainAuthorityProblem`) before it is offered, so a Member, or a Custom member outside their
// permissions, finds it blocked, and the server refuses it again if a client sends it anyway. A change that no longer
// makes sense in the state (the member has left since) can only be dropped.
//
// What a pending change holds is only what the outside request said: the kind, the account and the email of the person,
// and the role, grants or collection. The server never writes a record, a seal or a key for it: a change that gives
// someone access to a collection needs the holder of its key to seal it afterwards, as any grant does.
//
// The routes are the server's, under `/kem/v1/spaces/{id}/chain`: `GET /pending` for Owners and Admins, `POST /pending/{n}`
// with the body of an append, which the server applies (`422 pending-change-mismatch` when the record isn't exactly the
// queued change), and `DELETE /pending/{n}`, `204`.
//
// Pure Dart, no Flutter.

library;

import '../../crypto/account/encoding.dart';
import '../sync/kemlock/km_api.dart';
import 'space_chain.dart';
import 'space_chain_client.dart';
import 'space_records.dart';
import 'space_state.dart';
import 'space_verify.dart';

/// The kinds of change an outside request can queue, and the chain kind each is answered with.
enum PendingKind {
  addMember('add-member', ChainKind.invite),
  removeMember('remove-member', ChainKind.remove),
  role('role', ChainKind.role),
  grantSet('grant-set', ChainKind.grant),
  grantRemove('grant-remove', ChainKind.ungrant);

  const PendingKind(this.wire, this.chain);

  final String wire;
  final ChainKind chain;

  static PendingKind? fromWire(String text) {
    for (final kind in values) {
      if (kind.wire == text) {
        return kind;
      }
    }
    return null;
  }
}

/// One grant of a queued `add-member`.
typedef PendingGrant = ({String collection, String permission});

String? _optionalText(Object? value) => value is String ? value : null;

/// A change the server queued for an Admin to sign.
final class PendingChange {
  const PendingChange({
    required this.id,
    required this.kind,
    required this.source,
    required this.queuedAt,
    this.requestedByAccount,
    this.requestedByEmail,
    this.requestedVia,
    this.account,
    this.email,
    this.role,
    this.custom = const [],
    this.grants = const [],
    this.collection,
    this.permission,
  });

  /// Reads one element of the server's list: `{id, source, queuedAt, requestedBy: {account, email, via}, change: {kind,
  /// account, email, role?, custom?, grants?, collection?, permission?}}`. A kind that isn't one of [PendingKind] is
  /// kept as it is, [supported] false, so the app can show it and offer to drop it, never to approve it. Throws a
  /// [MalformedException] for anything else.
  factory PendingChange.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const MalformedException('a pending change is an object');
    }
    final rawId = json['id'];
    final String id;
    if (rawId is int && rawId >= 0) {
      id = '$rawId';
    } else if (rawId is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(rawId)) {
      id = rawId;
    } else {
      throw const MalformedException('a pending change has an id');
    }
    final change = json['change'];
    if (change is! Map<String, Object?> || change['kind'] is! String) {
      throw const MalformedException('a pending change names the change it asks for');
    }
    final by = json['requestedBy'];
    final requestedBy = by is Map<String, Object?> ? by : const <String, Object?>{};
    final custom = change['custom'];
    final grants = change['grants'];
    final queued = json['queuedAt'];
    return PendingChange(
      id: id,
      kind: change['kind']! as String,
      source: _optionalText(json['source']) ?? 'other',
      queuedAt: switch (queued) {
        final int seconds => seconds,
        final String text => (DateTime.tryParse(text)?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        _ => 0,
      },
      requestedByAccount: _optionalText(requestedBy['account']),
      requestedByEmail: _optionalText(requestedBy['email']),
      requestedVia: _optionalText(requestedBy['via']),
      account: _optionalText(change['account']),
      email: _optionalText(change['email']),
      role: _optionalText(change['role']),
      custom: [if (custom is List<Object?>) ...custom.whereType<String>()],
      grants: [
        if (grants is List<Object?>)
          for (final grant in grants)
            if (grant is Map<String, Object?> && grant['collection'] is String && grant['permission'] is String)
              (collection: grant['collection']! as String, permission: grant['permission']! as String),
      ],
      collection: _optionalText(change['collection']),
      permission: _optionalText(change['permission']),
    );
  }

  /// The server's number for it, which the routes take.
  final String id;

  /// The kind of change, as the server names it (`add-member`, `remove-member`, `role`, `grant-set`, `grant-remove`).
  final String kind;

  /// Where the change came from: `bitwarden` for the Bitwarden API, `sso` for the group sync, anything else another app.
  final String source;

  /// Unix seconds the server queued it.
  final int queuedAt;

  /// Who asked. The account is null for a request made through the Bitwarden API.
  final String? requestedByAccount;
  final String? requestedByEmail;
  final String? requestedVia;

  /// The person the change is about, by account and email.
  final String? account;
  final String? email;
  final String? role;
  final List<String> custom;
  final List<PendingGrant> grants;
  final String? collection;
  final String? permission;

  PendingKind? get pendingKind => PendingKind.fromWire(kind);

  ChainKind? get chainKind => pendingKind?.chain;

  /// Whether the app can make this change's record.
  bool get supported => pendingKind != null;
}

/// What a change would do, in plain facts for the sheet to word.
final class PendingEffect {
  const PendingEffect({
    required this.kind,
    this.member,
    this.role,
    this.collection,
    this.grantee,
    this.permission,
    this.replaces = const {},
  });

  final ChainKind kind;
  final String? member;
  final SpaceRole? role;
  final String? collection;
  final Grantee? grantee;
  final CollectionPermission? permission;

  /// The keys the change marks for replacement: whoever loses access held them.
  final Set<KeyRef> replaces;
}

/// Why a change can't be approved.
enum PendingBlock {
  /// The app can't make a record of this kind, or the request is not in the shape of its kind.
  unsupported,

  /// It makes no sense in the space as the chain has it now: the member left, the grant is gone.
  cantApply,

  /// The chain doesn't allow this member to make it.
  notAllowed,
}

/// A pending change worked into the record that would answer it, checked against the state.
final class PendingPlan {
  const PendingPlan({required this.change, this.entry, this.effect, this.block, this.detail});

  final PendingChange change;

  /// The record to sign, when one could be made.
  final SpaceChainEntry? entry;
  final PendingEffect? effect;
  final PendingBlock? block;

  /// The reason, for the logs.
  final String? detail;

  /// Whether the signer may approve it now.
  bool get canApprove => entry != null && block == null;
}

String _account(PendingChange change) {
  final value = change.account;
  if (value == null || !isUuidText(value)) {
    throw const MalformedException('the change names the account it is about');
  }
  return value;
}

String _collection(PendingChange change) {
  final value = change.collection;
  if (value == null || !isUuidText(value)) {
    throw const MalformedException('the change names a collection');
  }
  return value;
}

SpaceRole _role(PendingChange change) {
  final role = SpaceRole.fromWire(change.role ?? '');
  if (role == null) {
    throw const MalformedException('a role is owner, admin, custom or member');
  }
  return role;
}

CollectionPermission _permission(String? text) {
  final permission = CollectionPermission.fromWire(text ?? '');
  if (permission == null) {
    throw MalformedException('not a collection permission: $text');
  }
  return permission;
}

Set<CustomPermission> _custom(PendingChange change) => {
  for (final item in change.custom) CustomPermission.fromWire(item) ?? (throw const MalformedException('not a custom permission')),
};

/// Works [change] into the record [by] would sign at [at] (Unix seconds), and checks it against [state], the verified
/// chain: the record has to make sense where it lands, and the signer has to be allowed to make it. Never throws: a
/// change that can't be approved gives a plan with its [PendingPlan.block].
PendingPlan planPending({required SpaceState state, required PendingChange change, required String by, required int at}) {
  final SpaceChainEntry entry;
  final PendingEffect effect;
  try {
    switch (change.pendingKind) {
      case PendingKind.addMember:
        final invited = _role(change);
        entry = buildInvite(
          state: state,
          by: by,
          member: _account(change),
          role: invited,
          custom: _custom(change),
          grants: {for (final grant in change.grants) grant.collection: _permission(grant.permission)},
          at: at,
        );
        effect = PendingEffect(kind: ChainKind.invite, member: entry.body['member']! as String, role: invited);
      case PendingKind.removeMember:
        entry = buildRemove(state: state, by: by, member: _account(change), at: at);
        effect = PendingEffect(kind: ChainKind.remove, member: entry.body['member']! as String, replaces: _replaced(entry));
      case PendingKind.role:
        final role = _role(change);
        entry = buildRole(state: state, by: by, member: _account(change), role: role, custom: _custom(change), at: at);
        effect = PendingEffect(kind: ChainKind.role, member: entry.body['member']! as String, role: role);
      case PendingKind.grantSet:
        final permission = _permission(change.permission);
        final grantee = Grantee.user(_account(change));
        entry = buildGrant(state: state, by: by, collection: _collection(change), grantee: grantee, permission: permission, at: at);
        effect = PendingEffect(
          kind: ChainKind.grant,
          collection: entry.body['collection']! as String,
          grantee: grantee,
          permission: permission,
        );
      case PendingKind.grantRemove:
        final grantee = Grantee.user(_account(change));
        entry = buildUngrant(state: state, by: by, collection: _collection(change), grantee: grantee, at: at);
        effect = PendingEffect(
          kind: ChainKind.ungrant,
          collection: entry.body['collection']! as String,
          grantee: grantee,
          replaces: _replaced(entry),
        );
      case null:
        return PendingPlan(change: change, block: PendingBlock.unsupported, detail: 'the app makes no record of kind ${change.kind}');
    }
  } on MalformedException catch (e) {
    return PendingPlan(change: change, block: PendingBlock.unsupported, detail: e.message);
  } on ChainRefusal catch (e) {
    return PendingPlan(change: change, block: PendingBlock.cantApply, detail: e.detail);
  }
  final SpaceState after;
  try {
    after = state.apply(entry);
  } on ChainRefusal catch (e) {
    return PendingPlan(change: change, entry: entry, effect: effect, block: PendingBlock.cantApply, detail: e.detail);
  }
  final problem = chainAuthorityProblem(state, after, entry);
  return PendingPlan(
    change: change,
    entry: entry,
    effect: effect,
    block: problem == null ? null : PendingBlock.notAllowed,
    detail: problem,
  );
}

Set<KeyRef> _replaced(SpaceChainEntry entry) {
  final replace = entry.body['replace'];
  return {
    if (replace is List<Object?>)
      for (final ref in replace.whereType<String>()) KeyRef.parse(ref),
  };
}

/// The signed record that answers [plan], made through [sign] (`signerWith` the account's `sig1` key in the app).
/// A [StateError] when the plan can't be approved, as a failed future: the call itself never throws.
Future<SignedChainEntry> approvePending(PendingPlan plan, Future<SignedChainEntry> Function(SpaceChainEntry entry) sign) async {
  final entry = plan.entry;
  if (!plan.canApprove || entry == null) {
    throw StateError('a change that is blocked is dropped, never approved');
  }
  return sign(entry);
}

/// A space's pending changes on one server: the list, the answer with a signed record, and the drop.
class SpacePendingClient {
  SpacePendingClient({required this.connection, required this.server, required this.space})
    : _routes = SpaceChainClient(connection: connection, server: server, space: space);

  final KmConnection connection;
  final Uri server;
  final String space;
  final SpaceChainClient _routes;

  KmApi get _api => connection.api;

  /// The changes waiting for an Owner's or Admin's app, in the server's order. One that can't be read is left out of the
  /// list rather than stopping the others.
  Future<List<PendingChange>> list() async {
    final raw = await connection.call((token) => _api.callValue('GET', server, '/spaces/$space/chain/pending', token: token));
    if (raw is! List<Object?>) {
      throw const KmError(KmProblem.server, message: 'a list of pending changes');
    }
    final changes = <PendingChange>[];
    for (final item in raw) {
      try {
        changes.add(PendingChange.fromJson(item));
      } on MalformedException {
        continue;
      }
    }
    return changes;
  }

  /// Answers [change] with the signed [record], which the server appends to the chain and applies. A head that moved
  /// and a record the server refuses are a [ChainAppendError] for the caller to show, after which the list and the state
  /// are read again.
  Future<ChainAppended> approve(PendingChange change, SignedChainEntry record) => _routes.approvePending(change.id, {
    'records': [record.toJson()],
    'seals': <Object?>[],
    'names': <Object?>[],
  });

  /// Drops [change]: the server discards it (204) and nothing changes in the space.
  Future<void> drop(PendingChange change) async {
    final route = '/spaces/$space/chain/pending/${Uri.encodeComponent(change.id)}';
    await connection.call((token) => _api.call('DELETE', server, route, token: token));
  }
}
