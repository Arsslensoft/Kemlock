import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../features/sync/kemlock/km_host.dart';
import '../features/sync/kemlock/km_live.dart';
import '../features/sync/kemlock/km_models.dart';
import '../features/sync/kemlock_approval.dart';
import '../features/sync/sync_store.dart';
import '../platform/network.dart';

/// Keeps Kemlock Server's live socket, `/kem/v1/live`, open while the app is in front with the vault unlocked and
/// Kemlock Server sync on (add-kemlock-server-sync, design 13). The server's `sync` frame runs the scheduler as a
/// push nudge does, and its `approval` frame reads the requests. Hiding the app, locking the vault, turning sync
/// off or turning offline mode on closes the socket; showing, unlocking or turning offline mode off opens it
/// again, with the back-off of [KmLive] after a failure. The five-minute schedule is the floor under it.
class KemlockLiveHost extends ConsumerStatefulWidget {
  const KemlockLiveHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<KemlockLiveHost> createState() => _KemlockLiveHostState();
}

class _KemlockLiveHostState extends ConsumerState<KemlockLiveHost> {
  late final AppLifecycleListener _lifecycle;
  var _front = true;
  KmLive? _live;
  KmHost? _liveHost;
  String? _liveHome;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _front = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onShow: () {
        _front = true;
        _update();
      },
      onHide: () {
        _front = false;
        _update();
      },
    );
    ref.listenManual(kemlockHostProvider, (_, _) => _update());
    ref.listenManual(syncProvider.select((sync) => sync.settings?.kemlock?.home.url), (_, _) => _update());
    ref.listenManual(offlineProvider, (_, _) => _update());
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  /// Opens the socket when everything is in place and none is open, and closes it when something is not.
  void _update() {
    if (!mounted) {
      return;
    }
    final host = ref.read(kemlockHostProvider);
    final target = ref.read(syncProvider).settings?.kemlock;
    final live = _live;
    if (live != null && (!_front || host == null || target == null || !identical(host, _liveHost) || target.home.url != _liveHome)) {
      _live = null;
      unawaited(live.stop());
    }
    if (_front && host != null && target != null && _live == null && !ref.read(offlineProvider)) {
      _liveHost = host;
      _liveHome = target.home.url;
      _live = KmLive(
        upgrade: () => host.liveUpgrade(_currentTarget(target)),
        connect: ref.read(liveSocketConnectorProvider),
        onFrame: _frame,
        clock: ref.read(clockProvider),
      )..start();
    }
  }

  /// The target as it is now, for an attempt made after the settings changed.
  KemlockTarget _currentTarget(KemlockTarget fallback) => ref.read(syncProvider).settings?.kemlock ?? fallback;

  void _frame(KmLiveFrame frame) {
    if (!mounted) {
      return;
    }
    switch (frame) {
      case KmLiveFrame.sync:
        ref.read(syncProvider.notifier).requestSync();
      case KmLiveFrame.approval:
        unawaited(ref.read(kemlockApprovalsProvider.notifier).refresh());
    }
  }

  @override
  void dispose() {
    final live = _live;
    _live = null;
    if (live != null) {
      unawaited(live.stop());
    }
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
