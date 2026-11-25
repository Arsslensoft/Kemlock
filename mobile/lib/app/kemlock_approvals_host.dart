import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/sync/kemlock_approval.dart';
import '../features/sync/kemlock_push.dart';
import '../features/sync/sync.dart';
import '../features/sync/sync_store.dart';
import '../platform/push.dart';
import '../platform/reminders.dart';
import '../vault/vault_controller.dart';

/// Reads the sign-in requests other devices of the account have made, while the vault is open: when the
/// Kemlock Server host starts and after each sync (which a nudge also runs), and shows each new one in the
/// approval sheet over the current screen (add-kemlock-server-sync, design 11). A request is shown once; one
/// the person dismissed is not shown again, but stays listed for the next read. It also listens to the phone's push: a
/// message is a nudge, and a new endpoint is registered with the server at once (plan add-unifiedpush).
class KemlockApprovalsHost extends ConsumerStatefulWidget {
  const KemlockApprovalsHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<KemlockApprovalsHost> createState() => _KemlockApprovalsHostState();
}

class _KemlockApprovalsHostState extends ConsumerState<KemlockApprovalsHost> {
  final _shown = <String>{};
  var _open = false;
  StreamSubscription<PushNudge>? _nudges;
  StreamSubscription<void>? _tokenChanges;
  StreamSubscription<void>? _taps;
  var _noticeShown = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(kemlockHostProvider, (_, host) {
      if (host != null) {
        unawaited(_clearNotice());
        unawaited(ref.read(kemlockApprovalsProvider.notifier).refresh());
      }
    }, fireImmediately: true);
    ref.listenManual(syncProvider.select((sync) => sync.status[kemlockScope]?.lastSyncAt), (previous, at) {
      if (at != null && at != previous) unawaited(ref.read(kemlockApprovalsProvider.notifier).refresh());
    });
    ref.listenManual(kemlockApprovalsProvider, (_, pending) => _showNext());
    _nudges = ref.read(pushTokensProvider).onMessage.listen(_nudged);
    _tokenChanges = ref.read(pushTokensProvider).onTokenChanged.listen((_) => unawaited(_tokenChanged()));
    _taps = ref.read(approvalNoticeProvider).taps.listen((_) => _noticeTapped());
  }

  /// The fixed-text notice was tapped while the app runs: the unlock comes first if the vault is locked, and the
  /// host reading the requests when it starts shows the request after it. With the vault open, read them now.
  void _noticeTapped() {
    if (!mounted || ref.read(vaultControllerProvider).session == null) {
      return;
    }
    unawaited(_clearNotice());
    unawaited(ref.read(kemlockApprovalsProvider.notifier).refresh());
  }

  /// Raises the notification that a device asks to sign in, with its fixed text. A phone that can't show it
  /// (no permission, no notifications) shows nothing: the request is read at the next open.
  Future<void> _raiseNotice() async {
    try {
      _noticeShown = true;
      await ref.read(approvalNoticeProvider).show();
    } on Object {
      // Nothing to show with; the request waits for the next open
    }
  }

  /// Takes back the notice this host raised, once the vault is open and the request is read.
  Future<void> _clearNotice() async {
    if (!_noticeShown) {
      return;
    }
    _noticeShown = false;
    try {
      await ref.read(approvalNoticeProvider).clear();
    } on Object {
      // A notice that can't be cleared is cleared by the person
    }
  }

  /// What another device's nudge asks for, which carries only its type. Nothing is fetched while the vault is
  /// locked or Kemlock Server sync is off, or the person turned the push switch off: the nudge is dropped, and
  /// the next open syncs anyway. A locked vault's `approval` nudge raises the fixed-text notification, which names
  /// no one: tapping it opens the unlock, and the request shows once the vault is open.
  void _nudged(PushNudge nudge) {
    if (!mounted) {
      return;
    }
    if (ref.read(vaultControllerProvider).session == null) {
      if (nudge == PushNudge.approval) {
        unawaited(_raiseNotice());
      }
      return;
    }
    final target = ref.read(syncProvider).settings?.kemlock;
    if (target == null || !target.push) {
      return;
    }
    switch (nudge) {
      case PushNudge.sync:
        ref.read(syncProvider.notifier).requestSync();
      case PushNudge.approval:
        unawaited(ref.read(kemlockApprovalsProvider.notifier).refresh());
    }
  }

  /// The phone's push token changed (a new UnifiedPush endpoint) or went (the distributor ended the registration, or was
  /// uninstalled). A new one is sent to the server at once, by a sync run, which registers a token it doesn't hold; a lost one is
  /// taken back from the server, which would otherwise keep pushing to an address that no longer reaches this phone. Nothing
  /// is done while the vault is locked, Kemlock Server sync is off or the person turned the push switch off: the next open
  /// syncs anyway, and registers the token it finds.
  Future<void> _tokenChanged() async {
    if (!mounted || ref.read(vaultControllerProvider).session == null) {
      return;
    }
    final target = ref.read(syncProvider).settings?.kemlock;
    if (target == null || !target.push) {
      return;
    }
    final token = await ref.read(pushTokensProvider).pushToken();
    if (!mounted) {
      return;
    }
    if (token != null) {
      ref.read(syncProvider.notifier).requestSync();
      return;
    }
    try {
      await ref.read(kemlockPushOffProvider)(target);
    } on Object {
      // The server can't be reached: it drops an address that no longer answers on its own
    }
  }

  @override
  void dispose() {
    unawaited(_nudges?.cancel());
    unawaited(_tokenChanges?.cancel());
    unawaited(_taps?.cancel());
    super.dispose();
  }

  void _showNext() {
    if (_open) return;
    final next = ref.read(kemlockApprovalsProvider).where((pending) => !_shown.contains(pending.request.id)).firstOrNull;
    if (next == null) return;
    _shown.add(next.request.id);
    _open = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await showKemlockApproval(context, next);
      _open = false;
      if (mounted) _showNext();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
