// The first-contact accept screen (docs/plans/add-server-spaces.md, task group 5, 5.3; the space chain section of
// docs/crypto.md, "First contact"). A chain that verifies proves nothing about people: a server could make a whole
// space of its own, with its own Owner key. So before anything else, the invitee compares the fingerprint of the
// **anchor person** (the inviter, or for a new device the confirmer) as the verified chain records it, against what that
// person's own app shows under Settings › Account security, read out or scanned.
//
// What the screen holds back until the digits match, as the spec asks: the Accept button, storing an anchor, opening or
// sealing a key, account recovery enrolment, and the space's policies and notices shown as checked. "Not now", digits
// that differ, or a scanned code that differs store nothing, offer no Accept and say that a different fingerprint means
// someone else's key is in the way. A person whose key has signed nothing since the account was admitted shows nothing
// about the chain, so no comparison is offered. An inviter who left leaves the person to pick a confirmed Owner. An
// account that made the space, or whose own current key signed after it was admitted, has nothing to compare.
//
// The logic is `firstContact` (space_contact.dart); this is its screen, built on the fingerprint view every screen of
// the plan shows a fingerprint with.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';
import 'fingerprint.dart';
import 'fingerprint_view.dart';
import 'space_contact.dart';
import 'space_overview.dart' show PoliciesSection;
import 'space_policies.dart' show LeaveFirst;
import 'space_state.dart';

/// The key of the "It matches" button, for tests.
const acceptMatchesKey = ValueKey('accept-matches');

/// The key of the "Not now" button, for tests.
const acceptNotNowKey = ValueKey('accept-not-now');

/// The key of the Accept button, for tests.
const acceptKey = ValueKey('accept-accept');

/// The key of the Decline button, for tests.
const acceptDeclineKey = ValueKey('accept-decline');

/// The key of the notice that the account must leave its other space first, for tests.
const acceptLeaveFirstKey = ValueKey('accept-leave-first');

/// The policy flags whose effect a member is told of before they accept, beside account recovery's own notice.
const _noticeFlags = ['centralOwnership', 'disableExport'];

/// The key of the Scan button, for tests.
const acceptScanKey = ValueKey('accept-scan');

/// The key of the button that picks the Owner [id], for tests.
ValueKey<String> acceptPickKey(String id) => ValueKey('accept-pick-$id');

enum _Step { compare, pick, matched, refused }

String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// The accept screen of one invitation or new device.
class AcceptSpaceSheet extends StatefulWidget {
  const AcceptSpaceSheet({
    super.key,
    required this.contact,
    required this.invited,
    required this.accountRecovery,
    required this.onCompared,
    required this.onAccept,
    required this.onDecline,
    this.pick,
    this.state,
    this.spaceName,
    this.onReject,
    this.scan,
    this.leaveFirst,
  });

  /// What the device does at first contact, from `firstContact` on the verified chain.
  final FirstContact contact;

  /// Whether the account is invited, and so compares its inviter, or a confirmed member's new device, which compares
  /// its confirmer.
  final bool invited;

  /// Whether the verified chain has account recovery on: the notice comes before the Accept button.
  final bool accountRecovery;

  /// Told once the digits matched, and nothing before: this is where the device stores its anchor, at the head it
  /// compared against.
  final Future<void> Function() onCompared;

  /// Accepts the invitation (or opens the space on the new device), after a comparison or when none was needed.
  final Future<void> Function() onAccept;

  /// Leaves the invitation unanswered: "Not now", and a comparison that failed.
  final VoidCallback onDecline;

  /// For [ContactKind.pickOwner]: the comparison with the Owner [person] the account picked (`compareWith`).
  final FirstContact Function(String person)? pick;

  /// Reads a QR code, the text of what was scanned or null when it was dismissed, with the existing scanner.
  final Future<String?> Function()? scan;

  /// The verified chain, whose policies and notices are shown once the fingerprint matched, before Accept.
  final SpaceState? state;

  /// The space's name, when it opened (only a confirmed member holds the space key, so an invitee usually has none).
  final String? spaceName;

  /// Declines the invitation for good. Without it, Decline only leaves the invitation unanswered ([onDecline]).
  final VoidCallback? onReject;

  /// The space the account has to leave before it may join this one (one space per member), or null. The Accept button is
  /// not offered while it is set, and the screen says which space to leave.
  final LeaveFirst? leaveFirst;

  @override
  State<AcceptSpaceSheet> createState() => _AcceptSpaceSheetState();
}

class _AcceptSpaceSheetState extends State<AcceptSpaceSheet> {
  late FirstContact _contact = widget.contact;
  late _Step _step = switch (widget.contact.kind) {
    ContactKind.creator || ContactKind.vouched => _Step.matched,
    ContactKind.pickOwner => _Step.pick,
    ContactKind.compare => _Step.compare,
  };
  var _scanUnreadable = false;
  var _busy = false;

  Future<void> _matched() async {
    setState(() => _busy = true);
    try {
      await widget.onCompared();
      if (mounted) {
        setState(() => _step = _Step.matched);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _scan() async {
    final text = await widget.scan!();
    final bundle = _contact.bundle;
    if (text == null || bundle == null || !mounted) {
      return;
    }
    switch (checkScannedFingerprint(text, bundle)) {
      case FingerprintCheck.match:
        await _matched();
      case FingerprintCheck.mismatch:
        setState(() {
          _scanUnreadable = false;
          _step = _Step.refused;
        });
      case FingerprintCheck.unreadable:
        setState(() => _scanUnreadable = true);
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await widget.onAccept();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact = _contact;
    final person = _short(contact.person ?? '00000000');
    final who = widget.invited ? 'inviter' : 'confirmer';
    return SyncSheetFrame(
      icon: const Icon(Icons.verified_user_rounded),
      title: context.t('accept.title'),
      actions: switch (_step) {
        _Step.compare when contact.canCompare => [
          TextButton(key: acceptNotNowKey, onPressed: _busy ? null : _decline, child: Text(context.t('accept.notNow'))),
          FilledButton(key: acceptMatchesKey, onPressed: _busy ? null : _matched, child: Text(context.t('accept.matches'))),
        ],
        _Step.matched => [
          TextButton(
            key: acceptDeclineKey,
            onPressed: _busy ? null : (widget.onReject ?? widget.onDecline),
            child: Text(context.t('accept.decline')),
          ),
          // One space per member: nothing to accept until the other space is left
          if (widget.leaveFirst == null)
            FilledButton(key: acceptKey, onPressed: _busy ? null : _accept, child: Text(context.t('accept.accept'))),
        ],
        _ => [TextButton(key: acceptNotNowKey, onPressed: widget.onDecline, child: Text(context.t('accept.notNow')))],
      },
      children: [
        switch (_step) {
          _Step.pick => SheetText(context.t('accept.pick')),
          _Step.compare when !contact.canCompare => AppAlert(severity: AlertSeverity.warning, child: Text(context.t('accept.cantCompare'))),
          _Step.compare => SheetText(context.t('accept.compare', {'who': who, 'person': person})),
          _Step.matched when contact.kind == ContactKind.vouched => SheetText(context.t('accept.vouched')),
          _Step.matched when contact.kind == ContactKind.creator => SheetText(context.t('accept.creator')),
          _Step.matched => AppAlert(severity: AlertSeverity.success, child: Text(context.t('accept.matched'))),
          _Step.refused => AppAlert(severity: AlertSeverity.error, child: Text(context.t('accept.mismatch'))),
        },
        if (_step == _Step.pick)
          for (final owner in contact.candidates)
            OutlinedButton(
              key: acceptPickKey(owner),
              onPressed: () => setState(() {
                _contact = widget.pick!(owner);
                _step = _Step.compare;
              }),
              child: Text(_short(owner)),
            ),
        // The digits come from the chain's bundle for the person, never from anything the server sent beside it
        if (_step == _Step.compare && contact.canCompare) FingerprintView(fingerprint: contact.fingerprint!, showQr: false),
        if (_step == _Step.compare && contact.canCompare && widget.scan != null)
          OutlinedButton(key: acceptScanKey, onPressed: _busy ? null : () => unawaited(_scan()), child: Text(context.t('accept.scan'))),
        if (_scanUnreadable && _step == _Step.compare)
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('accept.unreadable'))),
        // Only once the digits matched: the space, its policies and the notices they require, the recovery one first and
        // all of them before the Accept button
        if (_step == _Step.matched && widget.spaceName != null) SheetText(context.t('accept.space', {'name': widget.spaceName!})),
        if (_step == _Step.matched && widget.state != null) PoliciesSection(state: widget.state!),
        if (_step == _Step.matched && widget.leaveFirst != null)
          AppAlert(
            key: acceptLeaveFirstKey,
            severity: AlertSeverity.warning,
            child: Text(
              context.t('accept.leaveFirst', {
                'side': widget.leaveFirst!.byCurrent ? 'current' : 'joined',
                'space': widget.leaveFirst!.label,
              }),
            ),
          ),
        if (_step == _Step.matched && widget.accountRecovery)
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('accept.recovery'))),
        if (_step == _Step.matched && widget.state != null)
          for (final flag in _noticeFlags)
            if (widget.state!.policies[flag] == true)
              AppAlert(
                key: ValueKey('accept-notice-$flag'),
                severity: AlertSeverity.info,
                child: Text(context.t('accept.notice', {'policy': flag})),
              ),
      ],
    );
  }

  void _decline() => widget.onDecline();
}
