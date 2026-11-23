import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';

/// What a screen shows where it would have used the network while offline
/// mode is on (openspec: add-offline-mode, decision 4): [message], which
/// says what is paused, and "Network settings", which closes the sheets and
/// dialogs above the page and opens Settings, where the switch is.
///
/// ```dart
/// if (ref.watch(offlineProvider)) OfflineAlert(context.t('sync.offline')),
/// ```
class OfflineAlert extends StatelessWidget {
  const OfflineAlert(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppAlert(
      severity: AlertSeverity.warning,
      icon: const Icon(Icons.wifi_off_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: p.warning,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              alignment: AlignmentDirectional.centerStart,
            ),
            onPressed: () => openNetworkSettings(context),
            child: Text(context.t('offline.settings')),
          ),
        ],
      ),
    );
  }
}

/// Closes every sheet and dialog over the page and goes to Settings, whose
/// first group holds the offline mode switch.
void openNetworkSettings(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  router?.go('/settings');
}
