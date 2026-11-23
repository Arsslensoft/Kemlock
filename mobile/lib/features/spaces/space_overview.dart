// The sections of a server space's sheet that show the verified chain (docs/plans/add-server-spaces.md, task 5.1; the
// mockup "Space · Example Co"): the members with their role and state, the collections with their grants, the policies
// and the keys. Every fact comes from the state the chain derives, never from the server's own lists: the server adds
// only what the chain can't hold, which is who accepted an invitation and what a person is called (their names are sealed
// under keys the sheet may not hold, so a member or a collection without a name shows by the first part of its id).
//
// What a button offers is decided by dry-running the record it would make against the state and the authority table
// (`checkAction`), so a member sees an action only when the chain would take it.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../crypto/account/bundle.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';
import 'space_actions.dart';
import 'space_records.dart';
import 'space_state.dart';

/// What the server tells beside the chain, for a member who accepted an invitation: the bundle it holds for them and its
/// self-signature, which the confirmation compares and records. Nothing here is trusted until a `confirm` carries it.
typedef MemberOffer = ({KeyBundle bundle, Uint8List bundleSignature});

/// The names and offers a sheet shows, which the chain doesn't hold.
class SpaceSheetData {
  const SpaceSheetData({
    this.spaceName,
    this.collectionNames = const {},
    this.memberNames = const {},
    this.offers = const {},
    this.reconfirm = const {},
    this.recordTimes = const {},
  });

  /// The space's name, when its sealed name opened and is the chain's.
  final String? spaceName;

  /// By collection id, the names that opened and are the chain's.
  final Map<String, String> collectionNames;

  /// By account id, what the person is called (their email or name); the first part of the id when none is known.
  final Map<String, String> memberNames;

  /// By account id, the members who accepted an invitation and wait to be confirmed.
  final Map<String, MemberOffer> offers;

  /// The confirmed members whose key version changed, and who need a fresh comparison of their fingerprint. One of them
  /// whose new bundle the chain doesn't record yet also has an offer.
  final Set<String> reconfirm;

  /// By `seq`, the time the record was made, to date a key.
  final Map<int, int> recordTimes;

  String member(String account) => memberNames[account] ?? shortId(account);

  String collection(String id) => collectionNames[id] ?? shortId(id);
}

/// The first part of [id], the whole of a shorter one.
String shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// The key of the button [name] for [id], for tests.
ValueKey<String> actionKey(String name, String id) => ValueKey('$name-$id');

/// Whether the chain would take the record [make] builds: it makes sense in [state] and its signer may make it.
bool allows(SpaceState state, ChainAction Function() make) {
  try {
    return checkAction(state, make().entry).problem == null;
  } catch (_) {
    return false;
  }
}

/// The state a member row shows: the chain's status, with what the server adds for an invitation that was accepted, and
/// the replacement of a key pair that nobody compared, and a confirmed member the server says needs a fresh comparison.
String memberStatus(SpaceMember member, {required bool accepted, bool reconfirm = false}) {
  if (member.status == MemberStatus.removed) {
    return 'removed';
  }
  if (member.status == MemberStatus.invited) {
    return accepted ? 'accepted' : 'invited';
  }
  if (reconfirm) {
    return 'reconfirm';
  }
  return member.rekeySeq != null ? 'rekeyed' : 'confirmed';
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: context.palette.divider),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: children),
    ),
  );
}

Widget _title(BuildContext context, String id) => Text(
  context.t(id),
  style: AppType.body1.copyWith(color: context.palette.text, fontWeight: FontWeight.w700),
);

/// The members: each with their role and state, and what the viewer may do about them.
class MembersSection extends StatelessWidget {
  const MembersSection({
    super.key,
    required this.state,
    required this.account,
    required this.data,
    required this.enabled,
    required this.onConfirm,
    required this.onRemove,
    required this.onRole,
    this.onResend,
    required this.onInvite,
  });

  final SpaceState state;
  final String account;
  final SpaceSheetData data;

  /// False while a change is on its way, or the home is down.
  final bool enabled;
  final void Function(String member) onConfirm;
  final void Function(String member) onRemove;
  final void Function(String member, SpaceRole role) onRole;

  /// Sends an invitation again. Null when nothing is wired to do it, and then no button is shown.
  final void Function(String member)? onResend;
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    final members = state.members.values.where((member) => member.inSpace).toList()..sort((a, b) => a.id.compareTo(b.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _title(context, 'space.members.title'),
        for (final member in members) _row(context, member),
        if (onInvite != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('space-invite'),
              onPressed: enabled ? onInvite : null,
              child: Text(context.t('space.invite')),
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, SpaceMember member) {
    final p = context.palette;
    final you = member.id == account;
    final status = memberStatus(member, accepted: data.offers.containsKey(member.id), reconfirm: data.reconfirm.contains(member.id));
    final manageable = !you && allows(state, () => buildRemoveAction(state: state, by: account, member: member.id, at: 0));
    final resend = onResend;
    final roles = [
      for (final role in const [SpaceRole.owner, SpaceRole.admin, SpaceRole.member])
        if (role != member.role &&
            !you &&
            allows(
              state,
              () => ChainAction(
                entry: buildRole(state: state, by: account, member: member.id, role: role, at: 0),
              ),
            ))
          role,
    ];
    return _Card(
      children: [
        Text(
          you ? '${data.member(member.id)} · ${context.t('space.member.you')}' : data.member(member.id),
          key: actionKey('member', member.id),
          style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
        ),
        Text(
          '${context.t('space.pending.role', {'role': member.role.wire})} · ${context.t('space.member.status', {'status': status})}',
          style: AppType.caption.copyWith(color: p.textSecondary),
        ),
        if (manageable || roles.isNotEmpty)
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            overflowSpacing: 8,
            children: [
              if (resend != null && manageable && member.status == MemberStatus.invited && !data.offers.containsKey(member.id))
                TextButton(
                  key: actionKey('member-resend', member.id),
                  onPressed: enabled ? () => resend(member.id) : null,
                  child: Text(context.t('space.member.resend')),
                ),
              if (manageable)
                TextButton(
                  key: actionKey('member-remove', member.id),
                  onPressed: enabled ? () => onRemove(member.id) : null,
                  child: Text(context.t(member.isConfirmed ? 'space.member.remove' : 'space.member.revoke')),
                ),
              if (roles.isNotEmpty && member.isConfirmed)
                PopupMenuButton<SpaceRole>(
                  key: actionKey('member-role', member.id),
                  enabled: enabled,
                  tooltip: context.t('space.member.role'),
                  onSelected: (role) => onRole(member.id, role),
                  itemBuilder: (context) => [
                    for (final role in roles) PopupMenuItem(value: role, child: Text(context.t('space.pending.role', {'role': role.wire}))),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text(context.t('space.member.role'), style: AppType.body2.copyWith(color: context.palette.primary)),
                  ),
                ),
              if (manageable &&
                  data.offers.containsKey(member.id) &&
                  (member.status == MemberStatus.invited || (member.isConfirmed && data.reconfirm.contains(member.id))))
                FilledButton(
                  key: actionKey('member-confirm', member.id),
                  onPressed: enabled ? () => onConfirm(member.id) : null,
                  child: Text(context.t('space.member.confirm')),
                ),
            ],
          ),
      ],
    );
  }
}

/// The collections: each with who has access and at what level, with a menu to change it for whoever may grant it.
class CollectionsSection extends StatelessWidget {
  const CollectionsSection({
    super.key,
    required this.state,
    required this.account,
    required this.data,
    required this.enabled,
    required this.onGrant,
    required this.onUngrant,
  });

  final SpaceState state;
  final String account;
  final SpaceSheetData data;
  final bool enabled;
  final void Function(String collection, Grantee grantee, CollectionPermission permission) onGrant;
  final void Function(String collection, Grantee grantee) onUngrant;

  bool _mayGrant(String collection) {
    final me = state.member(account);
    if (me == null || !me.isConfirmed) {
      return false;
    }
    return me.role == SpaceRole.owner || me.role == SpaceRole.admin || (state.accessOf(account, collection)?.manage ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final ids = state.collections.keys.toList()..sort();
    final anyHidden = state.grants.values.any((grants) => grants.values.any((permission) => permission.hidesPasswords));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _title(context, 'space.collections.title'),
        for (final id in ids) _collection(context, id),
        if (anyHidden) SheetText(context.t('space.collection.hidden')),
      ],
    );
  }

  Widget _collection(BuildContext context, String id) {
    final p = context.palette;
    final info = state.collections[id]!;
    final grants = (state.grants[id] ?? const <String, CollectionPermission>{}).entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final mayGrant = _mayGrant(id);
    final without = [
      for (final member in state.members.values)
        if (member.inSpace && !grants.any((grant) => Grantee.parse(grant.key) == Grantee.user(member.id))) member.id,
    ]..sort();
    return _Card(
      children: [
        Text(
          data.collection(id),
          key: actionKey('collection', id),
          style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
        ),
        Text(
          context.t('space.collection.keyVersion', {'version': info.keyVersion}),
          style: AppType.caption.copyWith(color: p.textSecondary),
        ),
        if (grants.isEmpty) Text(context.t('space.collection.none'), style: AppType.body2.copyWith(color: p.textSecondary)),
        for (final grant in grants) _grant(context, id, Grantee.parse(grant.key), grant.value, mayGrant),
        if (mayGrant && without.isNotEmpty)
          PopupMenuButton<String>(
            key: actionKey('collection-give', id),
            enabled: enabled,
            tooltip: context.t('space.collection.give'),
            onSelected: (member) => onGrant(id, Grantee.user(member), CollectionPermission.view),
            itemBuilder: (context) => [for (final member in without) PopupMenuItem(value: member, child: Text(data.member(member)))],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(context.t('space.collection.give'), style: AppType.body2.copyWith(color: p.primary)),
            ),
          ),
      ],
    );
  }

  Widget _grant(BuildContext context, String collection, Grantee grantee, CollectionPermission permission, bool mayGrant) {
    final label = grantee.isGroup ? context.t('space.collection.group') : data.member(grantee.id);
    final text = Text('$label · ${context.t('space.pending.permission', {'permission': permissionName(permission)})}');
    if (!mayGrant) {
      return text;
    }
    return PopupMenuButton<CollectionPermission?>(
      key: actionKey('grant-$collection', grantee.id),
      enabled: enabled,
      onSelected: (next) => next == null ? onUngrant(collection, grantee) : onGrant(collection, grantee, next),
      itemBuilder: (context) => [
        for (final option in CollectionPermission.values)
          if (option != permission)
            PopupMenuItem<CollectionPermission?>(
              value: option,
              child: Text(context.t('space.pending.permission', {'permission': permissionName(option)})),
            ),
        PopupMenuItem<CollectionPermission?>(value: null, child: Text(context.t('space.collection.take'))),
      ],
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: text),
    );
  }
}

/// The name a permission takes in the messages, which no ICU selector has a hyphen in.
String permissionName(CollectionPermission permission) => switch (permission) {
  CollectionPermission.view => 'view',
  CollectionPermission.viewHidePasswords => 'viewHidePasswords',
  CollectionPermission.edit => 'edit',
  CollectionPermission.editHidePasswords => 'editHidePasswords',
  CollectionPermission.manage => 'manage',
};

/// The policies the chain records, as the space's admins signed them. A flag that is on is listed; the server's own
/// word for a policy is never read.
class PoliciesSection extends StatelessWidget {
  const PoliciesSection({super.key, required this.state});

  final SpaceState state;

  @override
  Widget build(BuildContext context) {
    final policies = state.policies;
    final on = [
      for (final flag in policies.keys)
        if (policies[flag] == true) flag,
    ]..sort();
    final master = policies['masterPassword'];
    final minLength = master is Map<String, Object?> && master['minLength'] is int ? master['minLength']! as int : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        _title(context, 'space.policies.title'),
        if (on.isEmpty && minLength == 0) SheetText(context.t('space.policy.none')),
        for (final flag in on)
          Text(
            '${context.t('space.policy.flag', {'policy': flag})} · ${context.t('space.policy.state', {'on': 'yes'})}',
            key: actionKey('policy', flag),
          ),
        if (minLength > 0) Text(context.t('space.policy.minLength', {'length': minLength})),
      ],
    );
  }
}

/// The keys: the space key's version and date, each collection's version, and "Keys need replacing" with the button that
/// replaces them for whoever the chain lets.
class KeysSection extends StatelessWidget {
  const KeysSection({
    super.key,
    required this.state,
    required this.data,
    required this.onReplace,
    required this.replacing,
    required this.progress,
  });

  final SpaceState state;
  final SpaceSheetData data;

  /// Replaces the keys, or null when this member may not or the home is down.
  final VoidCallback? onReplace;
  final bool replacing;
  final String? progress;

  @override
  Widget build(BuildContext context) {
    final seq = state.commitmentsOf(const KeyRef.space()).isEmpty ? null : state.commitmentsOf(const KeyRef.space()).last.seq;
    final at = seq == null ? null : data.recordTimes[seq];
    final date = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true).toIso8601String().substring(0, 10);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _title(context, 'space.keys.title'),
        Text(
          date == null
              ? context.t('space.keys.space', {'version': state.spaceKeyVersion})
              : context.t('space.keys.spaceDated', {'version': state.spaceKeyVersion, 'date': date}),
          key: const ValueKey('space-key-version'),
        ),
        if (state.keysNeedReplacing) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('space.keys.need'))),
        if (replacing) const LinearProgressIndicator(),
        if (progress != null) SheetText(progress!),
        if (state.keysNeedReplacing && onReplace != null)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('keys-replace'),
              onPressed: replacing ? null : onReplace,
              child: Text(context.t('space.keys.replace')),
            ),
          ),
      ],
    );
  }
}
