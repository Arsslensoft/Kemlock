/// The approving phone's side of a sign-in request (add-kemlock-server-sync,
/// task 9.2): the requests other devices of the account have made, read while
/// the vault is open, and the sheet that shows one with the five words this
/// phone computed from the request's one-time key. The words on the other
/// device are computed the same way there, so the person compares them; the
/// server's own words are a cross-check only and are never shown.
///
/// Approve asks the owner first, always, and sends only the root key sealed to
/// the request's key. Deny sends no key.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../generator/word_list.dart';
import '../vault/owner_check.dart';
import 'kemlock/km_approvals.dart';
import 'kemlock/km_auth_api.dart';
import 'kemlock_setup.dart' show kemlockProblemText;
import 'sync_sheet_frame.dart';
import 'sync_store.dart';

/// The pending requests of the open vault's account, newest first, as the last read found them.
final kemlockApprovalsProvider = NotifierProvider<KemlockApprovals, List<KmPendingApproval>>(KemlockApprovals.new);

class KemlockApprovals extends Notifier<List<KmPendingApproval>> {
  @override
  List<KmPendingApproval> build() {
    // Another vault has other requests
    ref.watch(vaultControllerProvider.select((state) => state.session));
    return const [];
  }

  /// Reads the requests: on open, on a nudge and after each sync. Nothing changes when the server can't be
  /// reached or offline mode is on.
  Future<void> refresh() async {
    final host = ref.read(kemlockHostProvider);
    final target = ref.read(syncProvider).settings?.kemlock;
    if (host == null || target == null) return;
    try {
      final words = await ref.read(wordListProvider.future);
      final pending = await host.withAccount(
        target,
        (connection, account) => KmApprovals(
          auth: KmAuthApi(connection.api),
          connection: connection,
          words: words,
          account: account,
          ownerCheck: (reason) async => false,
        ).pending(),
      );
      state = pending;
    } catch (_) {
      // The next sync reads them again
    }
  }

  /// Forgets a request that was answered.
  void answered(String id) => state = [
    for (final pending in state)
      if (pending.request.id != id) pending,
  ];
}

/// Shows [pending] over the current screen.
Future<void> showKemlockApproval(BuildContext context, KmPendingApproval pending) => showAppBottomSheet<void>(
  context,
  label: context.t('kemlock.approval.sheet'),
  builder: (context) => KemlockApprovalSheet(pending: pending),
);

/// One request, with Deny and Approve.
class KemlockApprovalSheet extends ConsumerStatefulWidget {
  const KemlockApprovalSheet({super.key, required this.pending});

  final KmPendingApproval pending;

  @override
  ConsumerState<KemlockApprovalSheet> createState() => _KemlockApprovalSheetState();
}

class _KemlockApprovalSheetState extends ConsumerState<KemlockApprovalSheet> {
  var _busy = false;
  Object? _error;

  KmPendingApproval get _pending => widget.pending;

  Future<void> _answer(Future<void> Function(KmApprovals approvals) action) async {
    final host = ref.read(kemlockHostProvider);
    final target = ref.read(syncProvider).settings?.kemlock;
    if (host == null || target == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final words = await ref.read(wordListProvider.future);
      await host.withAccount(
        target,
        (connection, account) => action(
          KmApprovals(
            auth: KmAuthApi(connection.api),
            connection: connection,
            words: words,
            account: account,
            ownerCheck: (reason) async => mounted && await ref.read(ownerCheckProvider)(context, ref, reason),
          ),
        ),
      );
      ref.read(kemlockApprovalsProvider.notifier).answered(_pending.request.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _pending.request;
    final phrase = _pending.phrase;
    final reason = context.t('kemlock.approval.reason');
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: const Icon(Icons.devices_rounded),
        title: context.t('kemlock.approval.sheet'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.palette.error),
            onPressed: _busy ? null : () => _answer((approvals) => approvals.deny(_pending)),
            child: Text(context.t('kemlock.approval.deny')),
          ),
          FilledButton(
            onPressed: _busy || !_pending.canApprove ? null : () => _answer((approvals) => approvals.approve(_pending, reason: reason)),
            child: Text(context.t('kemlock.approval.approve')),
          ),
        ],
        children: [
          Text(context.t('kemlock.approval.title', {'device': request.deviceName}), style: AppType.h6),
          SheetText(context.t('kemlock.approval.address', {'ip': request.ip})),
          SheetText(context.t('kemlock.approval.age', {'minutes': _pending.age.inMinutes})),
          if (phrase != null)
            Semantics(
              container: true,
              child: Text(
                context.t('kemlock.approval.words', {'words': phrase}),
                style: AppType.body1.copyWith(color: context.bmc.accentText),
              ),
            ),
          if (phrase == null)
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('kemlock.approval.problem.noKey')))
          else if (!_pending.serverPhraseAgrees)
            AppAlert(severity: AlertSeverity.error, child: Text(context.t('kemlock.approval.problem.phraseMismatch')))
          else
            AppAlert(severity: AlertSeverity.info, child: Text(context.t('kemlock.approval.differ'))),
          if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(kemlockProblemText(context, error))),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
