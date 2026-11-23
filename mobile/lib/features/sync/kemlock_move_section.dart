/// What Settings › Sync adds for a vault that moved to Kemlock Server (move-off-vaultwarden-sync, tasks 6.2, 6.3
/// and 7.2): a move that hasn't finished, with Try again; the result of the last one, with "Go back to
/// Vaultwarden" for 30 days; and the Bitwarden copy of a plain home, on its own line so its problems never read as
/// the Kemlock sync's, with the device that keeps it needed, or the offer to remove it once none does.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'kemlock/km_move_devices.dart';
import 'kemlock_copy.dart';
import 'kemlock_move.dart';
import 'kemlock_move_sheet.dart';
import 'sync.dart';
import 'sync_messages.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';

class KemlockMoveSection extends ConsumerStatefulWidget {
  const KemlockMoveSection({super.key});

  @override
  ConsumerState<KemlockMoveSection> createState() => _KemlockMoveSectionState();
}

class _KemlockMoveSectionState extends ConsumerState<KemlockMoveSection> {
  @override
  void initState() {
    super.initState();
    // Whenever Settings opens Sync, the device list is read again
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(kemlockCopyProvider.notifier).check(force: true));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final move = ref.watch(kemlockMoveProvider);
    final copy = ref.watch(kemlockCopyProvider);
    final sync = ref.watch(syncProvider);
    final kept = sync.settings?.vaultwarden != null;
    final status = sync.status[vaultwardenScope];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (move.unfinished) ...[
          AppAlert(severity: AlertSeverity.warning, child: Text(context.t('kemlock.move.unfinished'))),
          if (move.error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(kmMoveProblemText(context, error))),
          if (move.running)
            LinearProgressIndicator(semanticsLabel: context.t('kemlock.move.progress.title'))
          else
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                onPressed: () => unawaited(ref.read(kemlockMoveProvider.notifier).resume()),
                child: Text(context.t('kemlock.move.retry')),
              ),
            ),
        ],
        const KemlockMoveResult(),
        if (kept) ...[
          Text(context.t('kemlock.copy.title'), style: AppType.h6),
          // The copy's own line: its problem is shown here, and never stops the Kemlock sync above it
          Semantics(
            liveRegion: true,
            child: AppAlert(
              severity: status?.problem != null ? AlertSeverity.error : AlertSeverity.success,
              child: Text(context.t('kemlock.copy.line', {'status': statusText(context, status)})),
            ),
          ),
          switch (copy.standing) {
            KmCopyStanding.needed => SheetText(
              context.t('kemlock.copy.needed', {'names': copy.using.map((device) => device.name).join(', ')}),
            ),
            KmCopyStanding.waiting => SheetText(context.t('kemlock.copy.waiting')),
            KmCopyStanding.offered => _offer(context, copy),
            null => const SizedBox.shrink(),
          },
        ],
        if (copy.notice case final notice?) SheetText(context.t('kemlock.copy.$notice')),
        if (copy.error != null && copy.standing == KmCopyStanding.offered)
          AppAlert(severity: AlertSeverity.error, child: Text(context.t('kemlock.copy.failed'))),
      ],
    );
  }

  /// No device used the Bitwarden API for 30 days: says what the removal trashes and that older builds then stop
  /// syncing the copy, and removes it only when the person taps the button.
  Widget _offer(BuildContext context, KmCopyState copy) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      AppAlert(
        severity: AlertSeverity.info,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('kemlock.copy.offer.title'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(context.t('kemlock.copy.offer.body')),
          ],
        ),
      ),
      if (copy.busy) const LinearProgressIndicator(),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.tonal(
          onPressed: copy.busy ? null : () => unawaited(ref.read(kemlockCopyProvider.notifier).remove()),
          child: Text(context.t('kemlock.copy.remove')),
        ),
      ),
    ],
  );
}
