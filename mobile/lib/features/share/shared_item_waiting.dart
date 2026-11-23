import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/shared_items.dart';
import '../../ui/ui.dart';

/// Whether an item another app shared waits for the vault to be opened,
/// for the lock screen to show [SharedItemWaiting].
bool sharedItemWaits(WidgetRef ref) => ref.watch(pendingShareProvider) != null;

/// The lock screen's line while a shared item waits (openspec:
/// add-share-extension, decision 2). It says that something was shared and
/// never what: no text, no file name, no size, since the lock screen can be
/// seen by whoever the phone was handed to. "Not now" drops the item, and
/// unlocking then opens the vault with nothing offered.
class SharedItemWaiting extends ConsumerWidget {
  const SharedItemWaiting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppAlert(
    severity: AlertSeverity.info,
    child: Row(
      children: [
        Expanded(child: Text(context.t('share.lock.waiting'))),
        const SizedBox(width: 8),
        TextButton(
          style: smallButtonStyle,
          onPressed: () => ref.read(pendingShareProvider.notifier).drop(),
          child: Text(context.t('share.lock.notNow')),
        ),
      ],
    ),
  );
}
