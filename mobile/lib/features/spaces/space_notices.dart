// The notices a space's policies owe a member, kept in the space's details (docs/plans/add-server-spaces.md, task group
// 7). Each is worded from the verified chain's policy set, never from anything the server says beside it.
//
// - Account recovery (7.2): where the chain has it on, the member is told what it means and asks to agree or leave. Nothing
//   is sealed until they agree (`space_recovery.dart`); the notice before Accept on the invitation is the accept sheet's.
// - Duplicate matching (7.3): where the chain has server matching on, each member is told once what the server can learn,
//   and the notice stays under the space's details.

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';
import 'space_recovery.dart';
import 'space_state.dart';

/// The key of the Agree button of the recovery notice, for tests.
const recoveryAgreeKey = ValueKey('space-recovery-agree');

/// The key of the Leave button of the recovery notice, for tests.
const recoveryLeaveKey = ValueKey('space-recovery-leave');

Widget _title(BuildContext context, String id) => Text(
  context.t(id),
  style: AppType.body1.copyWith(color: context.palette.text, fontWeight: FontWeight.w700),
);

/// What account recovery means to a member, with "Agree" and "Leave the space". It shows only for a confirmed member of a
/// space whose verified chain has account recovery on and records a recovery key ([recoveryAsked]).
class RecoveryNoticeSection extends StatelessWidget {
  const RecoveryNoticeSection({
    super.key,
    required this.state,
    required this.account,
    this.enrolled = false,
    this.busy = false,
    this.failed = false,
    this.onAgree,
    this.onLeave,
  });

  final SpaceState state;
  final String account;

  /// Whether the member agreed already and their root key was sealed.
  final bool enrolled;

  /// Whether an agreement is being made now.
  final bool busy;

  /// Whether the last agreement failed, with nothing sealed.
  final bool failed;

  /// Agrees and enrols, or null where this phone can't enrol yet: no Agree button is offered then.
  final VoidCallback? onAgree;

  /// Starts leaving the space, or null where it can't be left from here.
  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    if (!recoveryAsked(state, account)) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        _title(context, 'space.recovery.title'),
        if (enrolled)
          AppAlert(severity: AlertSeverity.success, child: Text(context.t('space.recovery.agreed')))
        else ...[
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('space.recovery.body'))),
          if (failed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('space.recovery.failed'))),
          if (busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 8,
            children: [
              if (onAgree != null)
                FilledButton(key: recoveryAgreeKey, onPressed: busy ? null : onAgree, child: Text(context.t('space.recovery.agree'))),
              if (onLeave != null)
                TextButton(
                  key: recoveryLeaveKey,
                  style: TextButton.styleFrom(foregroundColor: context.palette.error),
                  onPressed: busy ? null : onLeave,
                  child: Text(context.t('space.recovery.leave')),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The key of the notice that server matching of duplicates is on, for tests.
const matchingNoticeKey = ValueKey('space-matching-notice');

/// The key of the "Got it" button of the matching notice, for tests.
const matchingGotItKey = ValueKey('space-matching-got-it');

/// The key under which the vault's settings remember that the member saw [space]'s matching notice
/// (`KemlockTarget.matchingSeen`). It can't be a key of the duplicate cleaner's own notices, which are `space:<id>`.
String matchingSeenKey(String space) => 'chain:$space:duplicateMatching';

/// What the server can learn once a space's admins turn on server matching of duplicates, shown to every confirmed member
/// of a space whose verified chain has `duplicateMatching` on. It is shown **once** as a notice with "Got it" ([seen] is
/// false and [onSeen] is given), and **stays** under the space's details as plain text after that.
class MatchingNoticeSection extends StatelessWidget {
  const MatchingNoticeSection({super.key, required this.state, required this.account, required this.seen, this.onSeen});

  final SpaceState state;
  final String account;

  /// Whether the member was told already.
  final bool seen;

  /// Remembers that the member was told, or null where nothing can be remembered: the notice then stays as details alone.
  final VoidCallback? onSeen;

  @override
  Widget build(BuildContext context) {
    final me = state.member(account);
    if (me == null || !me.isConfirmed || state.policies['duplicateMatching'] != true) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      key: matchingNoticeKey,
      children: [
        _title(context, 'space.matching.title'),
        if (!seen && onSeen != null)
          AppAlert(
            severity: AlertSeverity.info,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.t('space.matching.new')),
                TextButton(key: matchingGotItKey, onPressed: onSeen, child: Text(context.t('space.matching.gotIt'))),
              ],
            ),
          ),
        SheetText(context.t('space.matching.body')),
      ],
    );
  }
}
