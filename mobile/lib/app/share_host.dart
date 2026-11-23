import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/shared_items.dart';
import '../vault/vault_controller.dart';

/// Catches what other apps share from the start, even while the vault is
/// locked, as the app catches set-up links (openspec: add-share-extension,
/// decisions 4 and 11). An item shared while the phone has no vault is
/// dropped: setup comes first, and there is nothing to use it with yet. On
/// each return to the front, an item shared ten minutes ago or more is
/// forgotten, since the timer may not have run while the phone slept, and
/// the `share/` directory is swept.
class ShareHost extends ConsumerStatefulWidget {
  const ShareHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShareHost> createState() => _ShareHostState();
}

class _ShareHostState extends ConsumerState<ShareHost> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    ref.listenManual(pendingShareProvider, (_, item) {
      if (item == null || ref.read(vaultControllerProvider).phase != VaultPhase.setup) return;
      // Not while the item is still being handed out
      scheduleMicrotask(() {
        if (mounted && identical(ref.read(pendingShareProvider), item)) ref.read(pendingShareProvider.notifier).drop();
      });
    });
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(pendingShareProvider.notifier).resumed()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
