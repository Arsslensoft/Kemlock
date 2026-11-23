// A server space's sheet (docs/plans/add-server-spaces.md, task group 5; "Space · Example Co"). This is where an Owner's
// or Admin's app lists the changes made outside Kemlock clients, with what each would do, and approves or drops them
// (`space_pending.dart`), and lists the items the server holds back after a key replacement, with Keep and Delete
// (`KmSpaceSync.heldItems`). Above them are the sections of task 5.1 (`space_overview.dart`): the members with their
// role and state, the collections with their grants, the policies, the keys and Leave; and the actions of tasks 5.2 to
// 5.6 (`space_actions.dart`): invite, confirm by the fingerprint, change a role or a grant, remove, leave and replace
// keys. While the home is down the actions that write chain records are disabled with the message that says so.
//
// What a change would do is worded here from the verified chain's state and the record the app would sign, never from
// the server's own description of it. A member or a collection shows by the first part of its id: their names are sealed
// under keys this sheet doesn't hold, and the id is what the chain records.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../crypto/account/bundle.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';
import 'fingerprint.dart';
import 'fingerprint_view.dart';
import 'server_spaces.dart' show HeldItemError, HeldItemProblem, HeldSpaceItem;
import 'space_actions.dart';
import 'space_chain.dart';
import 'space_invites.dart';
import 'space_notices.dart';
import 'space_overview.dart';
import 'space_pending.dart';
import 'space_state.dart';

/// The key of the Approve button of the change with [id], for tests.
ValueKey<String> approveKey(String id) => ValueKey('pending-approve-$id');

/// The key of the Drop button of the change with [id], for tests.
ValueKey<String> dropKey(String id) => ValueKey('pending-drop-$id');

/// Whether [account] may review pending changes in [state]: an Owner, an Admin, or a Custom member who manages users or
/// groups. What each change then needs is checked against the chain when it is planned, so this only decides whether
/// the list is shown.
bool mayReviewPending(SpaceState state, String account) {
  final member = state.member(account);
  if (member == null || !member.isConfirmed) {
    return false;
  }
  return switch (member.role) {
    SpaceRole.owner || SpaceRole.admin => true,
    SpaceRole.custom => member.custom.contains(CustomPermission.manageUsers) || member.custom.contains(CustomPermission.manageGroups),
    SpaceRole.member => false,
  };
}

/// The first 8 characters of [id], the whole of a shorter one, and a dash for none, so a field a change lacks shows as nothing.
String _short(String id) {
  if (id.isEmpty) {
    return '-';
  }
  return id.length <= 8 ? id : id.substring(0, 8);
}

/// The sheet of one server space. Everything it needs comes in as a function, so a screen gives it the open vault's
/// connection and keys and a test gives it a fake server.
class ServerSpaceSheet extends StatefulWidget {
  const ServerSpaceSheet({
    super.key,
    required this.state,
    required this.account,
    required this.load,
    required this.approve,
    required this.drop,
    required this.sign,
    required this.reloadState,
    required this.now,
    this.loadHeld,
    this.keepHeld,
    this.deleteHeld,
    this.actions,
    this.data = const SpaceSheetData(),
    this.confirmMember,
    this.lookupAccount,
    this.resendInvite,
    this.replaceKeys,
    this.itemCount,
    this.scan,
    this.homeDown,
    this.ownBundle,
    this.compared = false,
    this.agreeRecovery,
    this.recoveryEnrolled = false,
    this.matchingSeen = false,
    this.markMatchingSeen,
    this.onChanged,
    this.onLeft,
    this.copyOpen = false,
  });

  /// The verified chain's state, and the account whose app this is.
  final SpaceState state;
  final String account;

  /// The server's pending changes ([SpacePendingClient.list]), the answer with a signed record and the drop.
  final Future<List<PendingChange>> Function() load;
  final Future<void> Function(PendingChange change, SignedChainEntry record) approve;
  final Future<void> Function(PendingChange change) drop;

  /// Signs a record with the account's `sig1` key (`signerWith`).
  final Future<SignedChainEntry> Function(SpaceChainEntry entry) sign;

  /// Reads and verifies the chain again, which an approval has changed.
  final Future<SpaceState> Function() reloadState;

  /// Unix seconds, for the record's time.
  final int Function() now;

  /// The items the server holds back ([KmSpaceSync.heldItems]), and the keep and the delete that release one. Left out,
  /// the sheet shows no held list.
  final Future<List<HeldSpaceItem>> Function()? loadHeld;
  final Future<void> Function(String id)? keepHeld;
  final Future<void> Function(String id)? deleteHeld;

  /// What a member does here (`KmSpaceSync.actions`). Without it the sheet only shows the space.
  final SpaceActions? actions;

  /// The names, offers and times the chain doesn't hold.
  final SpaceSheetData data;

  /// Confirms [member] on the offer they made, after the digits matched: makes the `confirm` with this account's key and
  /// seals the keys (`SpaceActions.confirm`).
  final Future<SpaceState> Function(String member, MemberOffer offer)? confirmMember;

  /// The account that has [email] and its bundle, or null when none does (`SpaceInviteClient.lookup`, which throws an
  /// [InviteLookupError] when the server refuses or limits it), and sending an invitation again (`SpaceInviteClient.resend`,
  /// which throws a [ResendError] for the once-per-10-minutes limit).
  final Future<InviteeLookup?> Function(String email)? lookupAccount;
  final Future<void> Function(String member)? resendInvite;

  /// Replaces the keys the chain marks (`KmSpaceSync.replaceKeys`), reporting progress.
  final Future<void> Function(void Function(String progress) onProgress)? replaceKeys;

  /// How many items [collection] holds on this phone, for what a removed member could open.
  final int Function(String collection)? itemCount;

  /// Reads a QR code with the existing scanner: the text of what was scanned, or null when it was dismissed.
  final Future<String?> Function()? scan;

  /// The name of the home server while it can't be reached: chain records go only to the home, so the actions that write
  /// them wait, and say so, while items keep syncing (design decision 5).
  final String? homeDown;

  /// This account's own bundle, whose fingerprint it reads out while it waits to be confirmed.
  final KeyBundle? ownBundle;

  /// Whether a fingerprint was compared for this space (first contact), on this device or another of the account. The notices
  /// the chain's policies owe a member, account recovery and duplicate matching, are shown only for a space that was: a chain
  /// nobody compared proves nothing about people, and a server could have made it up.
  final bool compared;

  /// Agrees to account recovery and seals the account's root key to the chain's recovery key (`sealRecoveryEnrolment`),
  /// which throws when it could not be done. Without it the recovery notice has no Agree button, and only Leave.
  final Future<void> Function()? agreeRecovery;

  /// Whether the account agreed already: the notice then says so.
  final bool recoveryEnrolled;

  /// Whether the member was told that server matching of duplicates is on, and the call that remembers they were. Without
  /// the call the notice is only ever shown as details.
  final bool matchingSeen;
  final Future<void> Function()? markMatchingSeen;

  /// Told with the chain's new state after a change, and when this account left the space.
  final void Function(SpaceState state)? onChanged;
  final VoidCallback? onLeft;

  /// Whether this phone still syncs the space's WebDAV copy (a moved or joined space whose copy isn't closed): a second collection
  /// or a grant that hides passwords closes it on every phone, so the sheet says so before it makes one.
  final bool copyOpen;

  @override
  State<ServerSpaceSheet> createState() => _ServerSpaceSheetState();
}

class _ServerSpaceSheetState extends State<ServerSpaceSheet> {
  late SpaceState _state = widget.state;
  List<PendingChange> _changes = const [];
  var _loaded = false;
  var _failed = false;
  var _sendFailed = false;
  String? _busy;
  List<HeldSpaceItem> _held = const [];
  var _heldLoaded = false;
  var _heldFailed = false;
  var _heldSendFailed = false;
  HeldItemProblem? _heldProblem;
  String? _heldBusy;

  @override
  void initState() {
    super.initState();
    if (mayReviewPending(_state, widget.account)) {
      unawaited(_read());
    } else {
      _loaded = true;
    }
    if (widget.loadHeld != null && _confirmed) {
      unawaited(_readHeld());
    } else {
      _heldLoaded = true;
    }
  }

  Future<void> _read() async {
    try {
      final changes = await widget.load();
      if (mounted) {
        setState(() {
          _changes = changes;
          _loaded = true;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loaded = true;
        });
      }
    }
  }

  /// Reads the list and the chain again, after an answer or a refusal: the space may have moved on.
  Future<void> _refresh() async {
    try {
      final state = await widget.reloadState();
      if (mounted) {
        setState(() => _state = state);
      }
    } catch (_) {
      // The list is still shown against the state this sheet has
    }
    await _read();
  }

  Future<void> _approve(PendingPlan plan) async {
    setState(() {
      _busy = plan.change.id;
      _sendFailed = false;
    });
    try {
      await widget.approve(plan.change, await approvePending(plan, widget.sign));
    } catch (_) {
      if (mounted) {
        setState(() => _sendFailed = true);
      }
    }
    await _refresh();
    if (mounted) {
      setState(() => _busy = null);
    }
  }

  Future<void> _drop(PendingChange change) async {
    setState(() {
      _busy = change.id;
      _sendFailed = false;
    });
    try {
      await widget.drop(change);
    } catch (_) {
      if (mounted) {
        setState(() => _sendFailed = true);
      }
    }
    await _read();
    if (mounted) {
      setState(() => _busy = null);
    }
  }

  bool get _confirmed => _state.member(widget.account)?.isConfirmed ?? false;

  Future<void> _readHeld() async {
    final load = widget.loadHeld;
    if (load == null) {
      return;
    }
    try {
      final items = await load();
      if (mounted) {
        setState(() {
          _held = items;
          _heldLoaded = true;
          _heldFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _heldFailed = true;
          _heldLoaded = true;
        });
      }
    }
  }

  /// Keeps or deletes a held item, then reads the list again: the server releases it, or the problem is shown.
  Future<void> _release(HeldSpaceItem item, {required bool keep}) async {
    final action = keep ? widget.keepHeld : widget.deleteHeld;
    if (action == null) {
      return;
    }
    setState(() {
      _heldBusy = item.id;
      _heldProblem = null;
      _heldSendFailed = false;
    });
    try {
      await action(item.id);
    } on HeldItemError catch (e) {
      if (mounted) {
        setState(() => _heldProblem = e.problem);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _heldSendFailed = true);
      }
    }
    await _readHeld();
    if (mounted) {
      setState(() => _heldBusy = null);
    }
  }

  // ─── The member actions ────────────────────────────────────────────────

  _View _view = _View.main;
  String? _target;
  String? _problem;
  var _working = false;
  var _replacing = false;
  String? _progress;
  var _resent = false;
  var _agreeing = false;
  var _agreeFailed = false;
  late var _agreed = widget.recoveryEnrolled;
  late var _matchingSeen = widget.matchingSeen;
  var _lookupFailed = false;
  String? _lookupProblem;
  InviteeLookup? _found;
  String _foundEmail = '';
  var _mismatch = false;
  var _unreadable = false;
  final _email = TextEditingController();
  SpaceRole _inviteRole = SpaceRole.member;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  bool get _homeUp => widget.homeDown == null;

  /// Whether a change may be started: this sheet can make records, none is on its way and the home answers.
  bool get _canAct => widget.actions != null && !_working && !_replacing && _homeUp && _confirmed;

  /// Runs [change], shows what refused it, and takes the chain it answers.
  Future<bool> _make(Future<SpaceState> Function() change) async {
    setState(() {
      _working = true;
      _problem = null;
      _resent = false;
    });
    var done = false;
    try {
      final next = await change();
      done = true;
      if (mounted) {
        setState(() => _state = next);
      }
      widget.onChanged?.call(next);
    } on SpaceActionError catch (e) {
      if (mounted) {
        setState(() => _problem = e.problem.name);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'other');
      }
    }
    if (mounted) {
      setState(() => _working = false);
    }
    return done;
  }

  void _back() => setState(() {
    _view = _View.main;
    _target = null;
    _mismatch = false;
    _unreadable = false;
    _lookupFailed = false;
    _lookupProblem = null;
    _found = null;
    _foundEmail = '';
    _email.clear();
  });

  /// Grants [permission] on [collection], after telling the person that a grant which hides passwords closes the space's WebDAV copy
  /// while this phone still syncs it.
  Future<void> _grant(String collection, Grantee grantee, CollectionPermission permission) async {
    if (widget.copyOpen && permission.hidesPasswords) {
      final confirmed = await showConfirmDialog(
        context,
        title: context.t('space.bridge.warn.title'),
        body: Text(context.t('space.bridge.warn.body')),
        confirmLabel: context.t('space.bridge.warn.confirm'),
        cancelLabel: context.t('space.leave.cancel'),
      );
      if (!mounted || !confirmed) {
        return;
      }
    }
    await _make(() => widget.actions!.grant(collection, grantee, permission));
  }

  Future<void> _invite() async {
    final lookup = widget.lookupAccount;
    final actions = widget.actions;
    final email = _email.text.trim();
    if (lookup == null || actions == null || email.isEmpty) {
      return;
    }
    setState(() {
      _working = true;
      _lookupFailed = false;
      _lookupProblem = null;
      _problem = null;
    });
    InviteeLookup? found;
    String? problem;
    try {
      found = await lookup(email);
    } on InviteLookupError catch (e) {
      problem = e.problem.name;
    } catch (_) {
      problem = 'other';
    }
    if (!mounted) {
      return;
    }
    if (problem != null) {
      setState(() {
        _working = false;
        _lookupProblem = problem;
      });
      return;
    }
    if (found == null) {
      setState(() {
        _working = false;
        _lookupFailed = true;
      });
      return;
    }
    // Who would be invited is shown first; nothing is made until it is confirmed here
    setState(() {
      _working = false;
      _found = found;
      _foundEmail = email;
      _view = _View.inviteReview;
    });
  }

  /// Makes the `invite` record for the account the lookup found. It grants and seals no key: the fingerprint is compared
  /// later, when the member has accepted and is confirmed.
  Future<void> _sendInvite() async {
    final actions = widget.actions;
    final found = _found;
    if (actions == null || found == null) {
      return;
    }
    // "Everyone" goes with the invitation, as the first collection of a space nobody configures
    final grants = {for (final id in _state.collections.keys.take(1)) id: CollectionPermission.edit};
    if (await _make(() => actions.invite(found.account, _inviteRole, grants: grants))) {
      _back();
    }
  }

  Future<void> _resend(String member) async {
    final resend = widget.resendInvite;
    if (resend == null) {
      return;
    }
    setState(() {
      _working = true;
      _problem = null;
      _resent = false;
    });
    try {
      await resend(member);
      if (mounted) {
        setState(() => _resent = true);
      }
    } on ResendError catch (e) {
      // At most once per 10 minutes, and the server's own word for it
      if (mounted) {
        setState(() => _problem = e.problem.name);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'other');
      }
    }
    if (mounted) {
      setState(() => _working = false);
    }
  }

  Future<void> _confirmTarget() async {
    final member = _target;
    final confirm = widget.confirmMember;
    final offer = member == null ? null : widget.data.offers[member];
    if (member == null || confirm == null || offer == null) {
      return;
    }
    if (await _make(() => confirm(member, offer))) {
      _back();
    }
  }

  Future<void> _scanTarget() async {
    final scan = widget.scan;
    final offer = _target == null ? null : widget.data.offers[_target!];
    if (scan == null || offer == null) {
      return;
    }
    final text = await scan();
    if (text == null || !mounted) {
      return;
    }
    switch (checkScannedFingerprint(text, offer.bundle)) {
      case FingerprintCheck.match:
        await _confirmTarget();
      case FingerprintCheck.mismatch:
        setState(() {
          _mismatch = true;
          _unreadable = false;
        });
      case FingerprintCheck.unreadable:
        setState(() => _unreadable = true);
    }
  }

  Future<void> _removeTarget() async {
    final member = _target;
    final actions = widget.actions;
    if (member == null || actions == null) {
      return;
    }
    if (await _make(() => actions.remove(member))) {
      _back();
    }
  }

  Future<void> _leave() async {
    final actions = widget.actions;
    if (actions == null) {
      return;
    }
    if (await _make(actions.leave)) {
      widget.onLeft?.call();
    }
  }

  /// The member agrees to account recovery: this phone seals the account's root key to the chain's recovery key.
  Future<void> _agreeRecovery() async {
    final agree = widget.agreeRecovery;
    if (agree == null || _agreeing) {
      return;
    }
    setState(() {
      _agreeing = true;
      _agreeFailed = false;
    });
    try {
      await agree();
      if (mounted) {
        setState(() => _agreed = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _agreeFailed = true);
      }
    }
    if (mounted) {
      setState(() => _agreeing = false);
    }
  }

  /// The member read the matching notice: it stays in the details, and it isn't shown as new again.
  void _seeMatching() {
    final mark = widget.markMatchingSeen;
    if (mark == null) {
      return;
    }
    setState(() => _matchingSeen = true);
    unawaited(mark().catchError((Object _) {}));
  }

  Future<void> _replaceKeys() async {
    final replace = widget.replaceKeys;
    if (replace == null) {
      return;
    }
    final replacing = context.t('space.keys.replacing');
    final replaced = context.t('space.keys.replaced');
    setState(() {
      _replacing = true;
      _problem = null;
      _progress = replacing;
    });
    try {
      await replace((progress) {
        if (mounted) {
          setState(() => _progress = progress);
        }
      });
      final next = await widget.reloadState();
      if (mounted) {
        setState(() {
          _state = next;
          _progress = replaced;
        });
      }
      widget.onChanged?.call(next);
    } catch (_) {
      if (mounted) {
        setState(() {
          _progress = null;
          _problem = 'keys';
        });
      }
    }
    if (mounted) {
      setState(() => _replacing = false);
    }
  }

  /// What a member could open, for the words before a removal: each collection they have access to, with its items.
  String _opens(BuildContext context, String member) {
    final count = widget.itemCount;
    final list = [
      for (final collection in _state.collectionsOf(member).toList()..sort())
        if (count == null)
          widget.data.collection(collection)
        else
          context.t('space.remove.item', {
            'name': widget.data.collection(collection),
            'items': context.t('space.remove.items', {'form': count(collection) == 1 ? 'one' : 'other', 'items': count(collection)}),
          }),
    ];
    return list.isEmpty ? 'none' : list.join(', ');
  }

  bool get _onlyOwner {
    final me = _state.member(widget.account);
    return me != null && me.isConfirmed && me.role == SpaceRole.owner && _state.confirmedOwners == 1;
  }

  List<Widget> _mainChildren(BuildContext context) {
    final reviews = mayReviewPending(_state, widget.account);
    final me = _state.member(widget.account);
    final waiting = me != null && me.status == MemberStatus.invited;
    final mayInvite =
        widget.actions != null &&
        widget.lookupAccount != null &&
        _confirmed &&
        allows(_state, () => buildInviteAction(state: _state, by: widget.account, member: _probe, role: SpaceRole.member, at: 0));
    final mayReplace = widget.replaceKeys != null && _confirmed && _homeUp && !_working;
    return [
      if (me != null) SheetText(context.t('space.overview', {'role': me.role.wire})),
      if (waiting) ...[
        AppAlert(severity: AlertSeverity.info, child: Text(context.t('space.waiting.title'))),
        SheetText(context.t('space.waiting.body')),
        if (widget.ownBundle != null) FingerprintView(fingerprint: widget.ownBundle!.fingerprint),
      ],
      if (widget.homeDown != null)
        AppAlert(severity: AlertSeverity.warning, child: Text(context.t('space.homeDown', {'home': widget.homeDown!}))),
      if (_problem != null)
        AppAlert(
          severity: AlertSeverity.error,
          child: Text(_problem == 'keys' ? context.t('space.keys.failed') : context.t('space.error', {'problem': _problem!})),
        ),
      if (_resent) AppAlert(severity: AlertSeverity.success, child: Text(context.t('space.member.resent'))),
      if (_working) const LinearProgressIndicator(),
      if (!waiting) ...[
        MembersSection(
          state: _state,
          account: widget.account,
          data: widget.data,
          enabled: _canAct,
          onInvite: mayInvite ? () => setState(() => _view = _View.invite) : null,
          onConfirm: (member) => setState(() {
            _view = _View.confirm;
            _target = member;
          }),
          onRemove: (member) => setState(() {
            _view = _View.remove;
            _target = member;
          }),
          onRole: (member, role) => unawaited(_make(() => widget.actions!.setRole(member, role))),
          onResend: widget.resendInvite == null ? null : (member) => unawaited(_resend(member)),
        ),
        CollectionsSection(
          state: _state,
          account: widget.account,
          data: widget.data,
          enabled: _canAct,
          onGrant: (collection, grantee, permission) => unawaited(_grant(collection, grantee, permission)),
          onUngrant: (collection, grantee) => unawaited(_make(() => widget.actions!.ungrant(collection, grantee))),
        ),
        PoliciesSection(state: _state),
        // Only for a space this device compared: the notices come from a policy set that nobody vouched for otherwise
        if (widget.compared)
          RecoveryNoticeSection(
            state: _state,
            account: widget.account,
            enrolled: _agreed,
            busy: _agreeing,
            failed: _agreeFailed,
            onAgree: widget.agreeRecovery == null ? null : () => unawaited(_agreeRecovery()),
            onLeave: widget.actions == null || _working || _replacing || _onlyOwner || !_homeUp
                ? null
                : () => setState(() => _view = _View.leave),
          ),
        if (widget.compared)
          MatchingNoticeSection(
            state: _state,
            account: widget.account,
            seen: _matchingSeen,
            onSeen: widget.markMatchingSeen == null ? null : _seeMatching,
          ),
        KeysSection(
          state: _state,
          data: widget.data,
          onReplace: mayReplace ? _replaceKeys : null,
          replacing: _replacing,
          progress: _progress,
        ),
      ],
      if (_state.member(widget.account)?.inSpace ?? false) ...[
        if (_onlyOwner) AppAlert(severity: AlertSeverity.info, child: Text(context.t('space.leave.onlyOwner'))),
        if (widget.actions != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('space-leave'),
              style: TextButton.styleFrom(foregroundColor: context.palette.error),
              onPressed: _working || _replacing || _onlyOwner || !_homeUp ? null : () => setState(() => _view = _View.leave),
              child: Text(context.t('space.leave')),
            ),
          ),
      ],
      if (!reviews) AppAlert(severity: AlertSeverity.info, child: Text(context.t('space.pending.reviewers'))),
      if (reviews) ...[
        SheetText(context.t('space.pending.title')),
        SheetText(context.t('space.pending.body')),
        if (!_loaded) const LinearProgressIndicator(),
        if (_failed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.pending.failed'))),
        if (_sendFailed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.pending.sendFailed'))),
        if (_loaded && !_failed && _changes.isEmpty) SheetText(context.t('space.pending.none')),
        for (final change in _changes)
          _PendingTile(
            plan: planPending(state: _state, change: change, by: widget.account, at: widget.now()),
            busy: _busy != null,
            onApprove: _approve,
            onDrop: _drop,
          ),
      ],
      if (widget.loadHeld != null && _confirmed) ...[
        SheetText(context.t('space.held.title')),
        SheetText(context.t('space.held.body')),
        if (!_heldLoaded) const LinearProgressIndicator(),
        if (_heldFailed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.held.failed'))),
        if (_heldSendFailed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.held.sendFailed'))),
        if (_heldProblem != null)
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('space.held.problem', {'problem': _heldProblem!.name}))),
        if (_heldLoaded && !_heldFailed && _held.isEmpty) SheetText(context.t('space.held.none')),
        for (final item in _held)
          _HeldTile(
            item: item,
            busy: _heldBusy != null,
            onKeep: (held) => _release(held, keep: true),
            onDelete: (held) => _release(held, keep: false),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final close = FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('space.sheet.close')));
    final name = _target == null ? '' : widget.data.member(_target!);
    final offer = _target == null ? null : widget.data.offers[_target!];
    final cancel = TextButton(
      key: const ValueKey('space-back'),
      onPressed: _working ? null : _back,
      child: Text(context.t('space.leave.cancel')),
    );
    switch (_view) {
      case _View.main:
        return SyncSheetFrame(
          icon: const Icon(Icons.groups_rounded),
          title: widget.data.spaceName ?? context.t('space.title'),
          actions: [close],
          children: _mainChildren(context),
        );
      case _View.invite:
        return SyncSheetFrame(
          icon: const Icon(Icons.person_add_alt_1_rounded),
          title: context.t('space.invite.title'),
          actions: [
            cancel,
            FilledButton(
              key: const ValueKey('space-invite-send'),
              onPressed: _working ? null : () => unawaited(_invite()),
              child: Text(context.t('space.invite.button')),
            ),
          ],
          children: [
            SheetText(context.t('space.invite.body')),
            TextField(
              enableIMEPersonalizedLearning: false,
              key: const ValueKey('space-invite-email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: context.t('space.invite.email')),
            ),
            DropdownButtonFormField<SpaceRole>(
              key: const ValueKey('space-invite-role'),
              initialValue: _inviteRole,
              decoration: InputDecoration(labelText: context.t('space.invite.role')),
              items: [
                for (final role in const [SpaceRole.member, SpaceRole.admin])
                  DropdownMenuItem(value: role, child: Text(context.t('space.pending.role', {'role': role.wire}))),
              ],
              onChanged: (role) => setState(() => _inviteRole = role ?? SpaceRole.member),
            ),
            if (_lookupFailed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.invite.unknown'))),
            if (_lookupProblem != null)
              AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.invite.lookupFailed', {'problem': _lookupProblem!}))),
            if (_problem != null) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.error', {'problem': _problem!}))),
            if (_working) const LinearProgressIndicator(),
          ],
        );
      case _View.inviteReview:
        final found = _found;
        return SyncSheetFrame(
          icon: const Icon(Icons.person_add_alt_1_rounded),
          title: context.t('space.invite.reviewTitle'),
          actions: [
            // Back to the form, where the email can be changed; nothing was made
            TextButton(
              key: const ValueKey('space-invite-review-back'),
              onPressed: _working ? null : () => setState(() => _view = _View.invite),
              child: Text(context.t('space.leave.cancel')),
            ),
            FilledButton(
              key: const ValueKey('space-invite-confirm'),
              onPressed: _working || found == null ? null : () => unawaited(_sendInvite()),
              child: Text(context.t('space.invite.send')),
            ),
          ],
          children: [
            if (found != null)
              SheetText(
                context.t('space.invite.review', {
                  'email': _foundEmail,
                  'role': context.t('space.pending.role', {'role': _inviteRole.wire}),
                  'account': shortId(found.account),
                }),
              ),
            SheetText(context.t('space.invite.reviewKeys')),
            if (_problem != null) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.error', {'problem': _problem!}))),
            if (_working) const LinearProgressIndicator(),
          ],
        );
      case _View.confirm:
        return SyncSheetFrame(
          icon: const Icon(Icons.verified_user_rounded),
          title: context.t('space.confirm.title', {'name': name}),
          actions: [
            TextButton(
              key: const ValueKey('space-confirm-not-now'),
              onPressed: _working ? null : _back,
              child: Text(context.t('space.confirm.notNow')),
            ),
            if (offer != null && !_mismatch)
              FilledButton(
                key: const ValueKey('space-confirm-matches'),
                onPressed: _working ? null : () => unawaited(_confirmTarget()),
                child: Text(context.t('space.confirm.matches')),
              ),
          ],
          children: [
            if (offer != null && !_mismatch) ...[
              SheetText(context.t('space.confirm.body', {'name': name})),
              // The digits are those of the bundle the server gave, which is what the confirmation will record
              FingerprintView(fingerprint: offer.bundle.fingerprint, showQr: false),
              if (widget.scan != null)
                OutlinedButton(
                  key: const ValueKey('space-confirm-scan'),
                  onPressed: _working ? null : () => unawaited(_scanTarget()),
                  child: Text(context.t('space.confirm.scan')),
                ),
            ],
            if (_mismatch) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.confirm.mismatch'))),
            if (_unreadable) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('space.confirm.unreadable'))),
            if (_problem != null)
              AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.confirm.failed', {'problem': _problem!}))),
            if (_working) const LinearProgressIndicator(),
          ],
        );
      case _View.remove:
        final target = _target == null ? null : _state.member(_target!);
        final revoke = target != null && !target.isConfirmed;
        return SyncSheetFrame(
          icon: const Icon(Icons.person_remove_rounded),
          title: context.t(revoke ? 'space.remove.revokeTitle' : 'space.remove.title', {'name': name}),
          actions: [
            cancel,
            FilledButton(
              key: const ValueKey('space-remove-confirm'),
              style: FilledButton.styleFrom(backgroundColor: context.palette.error),
              onPressed: _working ? null : () => unawaited(_removeTarget()),
              child: Text(context.t(revoke ? 'space.remove.revokeButton' : 'space.remove.button')),
            ),
          ],
          children: [
            if (!revoke) ...[
              SheetText(context.t('space.remove.opens', {'list': _opens(context, _target ?? '')})),
              SheetText(context.t('space.remove.body')),
            ],
            if (_problem != null) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.error', {'problem': _problem!}))),
            if (_working) const LinearProgressIndicator(),
          ],
        );
      case _View.leave:
        return SyncSheetFrame(
          icon: const Icon(Icons.logout_rounded),
          title: context.t('space.leave.title'),
          actions: [
            cancel,
            FilledButton(
              key: const ValueKey('space-leave-confirm'),
              style: FilledButton.styleFrom(backgroundColor: context.palette.error),
              onPressed: _working ? null : () => unawaited(_leave()),
              child: Text(context.t('space.leave.button')),
            ),
          ],
          children: [
            SheetText(context.t('space.leave.body')),
            if (_problem != null) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.error', {'problem': _problem!}))),
            if (_working) const LinearProgressIndicator(),
          ],
        );
    }
  }
}

/// A member no account has, for asking the chain whether a record of this kind would be taken.
const _probe = '00000000-0000-4000-8000-0000000000ff';

enum _View { main, invite, inviteReview, confirm, remove, leave }

class _PendingTile extends StatelessWidget {
  const _PendingTile({required this.plan, required this.busy, required this.onApprove, required this.onDrop});

  final PendingPlan plan;
  final bool busy;
  final void Function(PendingPlan plan) onApprove;
  final void Function(PendingChange change) onDrop;

  String _effect(BuildContext context) {
    final effect = plan.effect;
    if (effect == null) {
      return context.t('space.pending.effect', {'kind': 'other'});
    }
    final person = plan.change.email ?? _short(effect.member ?? effect.grantee?.id ?? '');
    return context.t('space.pending.effect', {
      'kind': effect.kind.wire,
      'member': person,
      'role': context.t('space.pending.role', {'role': effect.role?.wire ?? 'member'}),
      'collection': _short(effect.collection ?? ''),
      'grantee': person,
      'permission': context.t('space.pending.permission', {'permission': _permissionName(effect.permission)}),
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final change = plan.change;
    final block = plan.block;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: p.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(
              _effect(context),
              style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
            ),
            Text(
              context.t('space.pending.source', {
                'source': change.source == 'bitwarden' || change.source == 'sso' ? change.source : 'other',
              }),
            ),
            if (plan.effect?.replaces.isNotEmpty ?? false) Text(context.t('space.pending.replaces')),
            if (block != null)
              AppAlert(severity: AlertSeverity.warning, child: Text(context.t('space.pending.block', {'block': block.name}))),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                TextButton(
                  key: dropKey(change.id),
                  onPressed: busy ? null : () => onDrop(change),
                  child: Text(context.t('space.pending.drop')),
                ),
                FilledButton(
                  key: approveKey(change.id),
                  onPressed: busy || !plan.canApprove ? null : () => onApprove(plan),
                  child: Text(context.t('space.pending.approve')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The name a permission takes in the messages, which no ICU selector has a hyphen in.
String _permissionName(CollectionPermission? permission) => switch (permission) {
  CollectionPermission.view => 'view',
  CollectionPermission.viewHidePasswords => 'viewHidePasswords',
  CollectionPermission.edit => 'edit',
  CollectionPermission.editHidePasswords => 'editHidePasswords',
  CollectionPermission.manage => 'manage',
  null => 'view',
};

/// The key of the Keep button of the held item with [id], for tests.
ValueKey<String> keepKey(String id) => ValueKey('held-keep-$id');

/// The key of the Delete button of the held item with [id], for tests.
ValueKey<String> deleteKey(String id) => ValueKey('held-delete-$id');

class _HeldTile extends StatelessWidget {
  const _HeldTile({required this.item, required this.busy, required this.onKeep, required this.onDelete});

  final HeldSpaceItem item;
  final bool busy;
  final void Function(HeldSpaceItem item) onKeep;
  final void Function(HeldSpaceItem item) onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = item.name;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: p.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(
              context.t('space.held.item', {'named': name == null ? 'no' : 'yes', 'name': name ?? ''}),
              style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
            ),
            if (!item.canKeep) Text(context.t('space.held.cantKeep')),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                TextButton(
                  key: deleteKey(item.id),
                  onPressed: busy ? null : () => onDelete(item),
                  child: Text(context.t('space.held.delete')),
                ),
                FilledButton(
                  key: keepKey(item.id),
                  onPressed: busy || !item.canKeep ? null : () => onKeep(item),
                  child: Text(context.t('space.held.keep')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
