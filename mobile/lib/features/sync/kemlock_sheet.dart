import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../i18n/messages.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../settings/offline_alert.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_failover.dart';
import 'kemlock/km_models.dart';
import 'kemlock/km_session.dart';
import 'kemlock_devices.dart';
import 'kemlock_matching_section.dart';
import 'kemlock_move_section.dart';
import 'kemlock_push.dart';
import 'removal_guard.dart';
import 'sync.dart';
import 'sync_messages.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';

/// The sheet of a vault that syncs its own entries with Kemlock Server:
/// the account and the server in use, how the last sync went, "Sync now",
/// what a run that would remove many entries asks, the push switch and
/// "Turn off". Settings › Sync shows it in place of the setup once the
/// settings hold a Kemlock Server target.
///
/// "Turn off" signs this phone out on the server, deletes the session, the
/// account's keys and the cache, and removes the target; the vault's
/// entries stay. The trusted-device copy on the server and the hardware key
/// stay until the person removes trust, so turning sync back on with SSO
/// opens the account without an approval.
class KemlockOn extends ConsumerStatefulWidget {
  const KemlockOn({super.key, required this.target, required this.onClose});

  final KemlockTarget target;
  final VoidCallback onClose;

  @override
  ConsumerState<KemlockOn> createState() => _KemlockOnState();
}

class _KemlockOnState extends ConsumerState<KemlockOn> {
  var _busy = false;

  KemlockTarget get _target => widget.target;

  Future<void> _save(KemlockTarget next) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    final store = ref.read(syncProvider.notifier);
    await store.saveSettings((store.snapshot.settings ?? noSync).copyWith(kemlock: next), session);
  }

  /// The push switch: saved first, so the next run no longer registers the token, then, when turned off, the
  /// server is asked to forget it. The server not answering changes nothing: the phone drops the nudges anyway.
  Future<void> _setPush(bool on) async {
    final next = _target.copyWith(push: on);
    await _save(next);
    if (!on) {
      try {
        await ref.read(kemlockPushOffProvider)(next);
      } on Object {
        // Best effort
      }
    }
  }

  Future<void> _turnOff() async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    setState(() => _busy = true);
    try {
      // The server can't be reached: the phone signs out anyway, and the device stays listed there until it is removed
      await ref.read(kemlockSignOutProvider)(_target).catchError((Object _) {});
      final vault = ref.read(vaultStoreProvider);
      for (final key in const [keyKemlockSession, keyKemlockAccount, keyKemlockCache]) {
        vault.removeEncryptedValue(key);
      }
      final store = ref.read(syncProvider.notifier);
      await store.saveSettings((store.snapshot.settings ?? noSync).copyWith(kemlock: null), session);
      await store.forgetScope(kemlockScope, session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sync = ref.watch(syncProvider);
    final status = sync.status[kemlockScope];
    final offline = ref.watch(offlineProvider);
    final problem = status?.problem;
    final away = ref.watch(kemlockAwayProvider);
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: const Icon(Icons.cloud_sync_outlined),
        title: context.t('sync.title'),
        leading: TextButton(
          style: TextButton.styleFrom(foregroundColor: p.error),
          onPressed: _busy ? null : _turnOff,
          child: Text(context.t('sync.off')),
        ),
        actions: [
          TextButton.icon(
            onPressed: sync.running || _busy || offline ? null : ref.read(syncProvider.notifier).requestSync,
            icon: const Icon(Icons.sync_rounded, size: 20),
            label: Text(context.t('sync.now')),
          ),
          FilledButton(onPressed: _busy ? null : widget.onClose, child: Text(context.t('export.close'))),
        ],
        children: [
          SheetText(context.t('kemlock.on.body', {'host': kmHost(_target.home.url), 'email': _target.email})),
          // Paused, not failed: the last sync's time and result stay shown under it
          if (offline) OfflineAlert(context.t('sync.offline')),
          if (away != null) _away(context, away),
          Semantics(
            liveRegion: true,
            child: AppAlert(
              severity: problem != null ? AlertSeverity.error : AlertSeverity.success,
              child: Text(statusText(context, status)),
            ),
          ),
          if (sync.running) LinearProgressIndicator(semanticsLabel: context.t('sync.running')),
          if (problem == null && (status?.count ?? 0) > 0)
            Text(context.t('kemlock.on.left', {'count': status!.count}), style: AppType.caption.copyWith(color: p.textSecondary)),
          if (problem == SyncProblem.removals) ..._removals(context, status?.count ?? 0),
          const KemlockMoveSection(),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy || offline ? null : () => unawaited(showKemlockDevices(context)),
              icon: const Icon(Icons.devices_rounded, size: 20),
              label: Text(context.t('kemlock.devices.open')),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _target.push,
            onChanged: _busy ? null : (on) => unawaited(_setPush(on)),
            title: Text(context.t('kemlock.push')),
            subtitle: Text(context.t('kemlock.push.hint')),
          ),
          KemlockMatchingSection(target: _target),
          Text(context.t('kemlock.on.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
        ],
      ),
    );
  }

  /// What a run the removal guard stopped asks, and the two answers.
  List<Widget> _removals(BuildContext context, int count) {
    final store = ref.read(syncProvider.notifier);
    return [
      SheetText(context.t('vaultwarden.removals.body', {'count': count})),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonal(
            onPressed: () => store.decideRemovals(RemovalChoice.keep),
            child: Text(context.t('vaultwarden.removals.keep')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.palette.error),
            onPressed: () => store.decideRemovals(RemovalChoice.remove),
            child: Text(context.t('vaultwarden.removals.remove')),
          ),
        ],
      ),
    ];
  }
}

/// The name a replica is shown by: the one its server list gives it, else its host.
String kemlockServerName(KemlockServer server) => server.extra['name'] is String ? server.extra['name']! as String : kmHost(server.url);

/// "Home server offline since 09:12", "Using VPS (Germany)": the vault's home is away and the phone syncs with a
/// replica. Items keep syncing; changes only the home may accept wait for it.
Widget _away(BuildContext context, KmAway away) {
  final time = DateFormat.jm(Localizations.localeOf(context).toLanguageTag()).format(away.since);
  return AppAlert(
    severity: AlertSeverity.warning,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(context.t('kemlock.failover.homeAway', {'time': time})),
        Text(context.t('kemlock.failover.using', {'server': kemlockServerName(away.using)})),
        Text(context.t('kemlock.away.hint')),
      ],
    ),
  );
}
