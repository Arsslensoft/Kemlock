/// The account's devices, adapted from the design canvas's Devices sheet
/// (add-kemlock-server-sync, task 9.4): each device's name and its last use of
/// the Kemlock API and of the Bitwarden API, either one "never"; this phone
/// marked; any other device signed out from the list, or all of them at once;
/// and this phone's trust removed. The server shows one row for a phone that
/// uses both APIs, as the phone registers with its Vaultwarden device
/// identifier.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_auth_api.dart';
import 'kemlock/km_models.dart';
import 'kemlock/km_trust.dart';
import 'kemlock_flow.dart';
import 'kemlock_setup.dart' show kemlockProblemText;
import 'sync_messages.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';

/// Shows the devices of [target]'s account.
Future<void> showKemlockDevices(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('kemlock.devices.title'), builder: (context) => const KemlockDevicesSheet());

/// The list, with the actions on it.
class KemlockDevicesSheet extends ConsumerStatefulWidget {
  const KemlockDevicesSheet({super.key});

  @override
  ConsumerState<KemlockDevicesSheet> createState() => _KemlockDevicesSheetState();
}

class _KemlockDevicesSheetState extends ConsumerState<KemlockDevicesSheet> {
  List<KmDevice>? _devices;
  Object? _error;
  String? _notice;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  KemlockTarget? get _target => ref.read(syncProvider).settings?.kemlock;

  /// Runs [action] with a connection to the server in use, then reads the list again.
  Future<void> _run(Future<void> Function(KmConnection connection, KmAuthApi auth) action, {String? done}) async {
    final host = ref.read(kemlockHostProvider);
    final target = _target;
    if (host == null || target == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await host.withAccount(target, (connection, account) => action(connection, KmAuthApi(connection.api)));
      if (done != null && mounted) _notice = done;
      await host.withAccount(target, (connection, account) async {
        final devices = await connection.call((token) => KmAuthApi(connection.api).devices(connection.server, token));
        if (mounted) setState(() => _devices = devices);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run((connection, auth) async {});

  Future<void> _signOut(KmDevice device) =>
      _run((connection, auth) => connection.call((token) => auth.signOutDevice(connection.server, token, device.id)));

  Future<void> _signOutOthers() => _run((connection, auth) async {
    for (final device in _devices ?? const <KmDevice>[]) {
      if (!device.current) await connection.call((token) => auth.signOutDevice(connection.server, token, device.id));
    }
  });

  Future<void> _removeTrust() {
    final target = _target;
    final vaultId = ref.read(vaultControllerProvider).vault.id;
    final trust = ref.read(kemlockTrustProvider);
    final done = context.t('kemlock.devices.trustRemoved');
    return _run((connection, auth) async {
      if (target == null) return;
      // The hardware key goes first, so no copy can open again, then the copy on the server
      await connection.call(
        (token) =>
            trust.removeTrust(api: connection.api, server: connection.server, token: token, tag: kmTrustTag(vaultId, target.accountId)),
      );
    }, done: done);
  }

  String _when(KmDevice device, DateTime? at) =>
      at == null ? context.t('kemlock.devices.never') : syncTime(context, at.millisecondsSinceEpoch);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final devices = _devices;
    final mine = devices?.where((device) => device.current).firstOrNull;
    final others = devices?.where((device) => !device.current).length ?? 0;
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: const Icon(Icons.devices_rounded),
        title: context.t('kemlock.devices.title'),
        actions: [FilledButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(context.t('export.close')))],
        children: [
          SheetText(context.t('kemlock.devices.body')),
          if (_error != null)
            AppAlert(
              severity: AlertSeverity.error,
              child: Text(devices == null ? context.t('kemlock.devices.failed') : kemlockProblemText(context, _error!)),
            ),
          if (_notice case final notice?) AppAlert(severity: AlertSeverity.info, child: Text(notice)),
          if (_busy && devices == null) const LinearProgressIndicator(),
          for (final device in devices ?? const <KmDevice>[])
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 2,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        device.name,
                        style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (device.current)
                      Text(context.t('kemlock.devices.thisPhone'), style: AppType.caption.copyWith(color: context.bmc.accentText)),
                    if (device.trusted)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 8),
                        child: Text(context.t('kemlock.devices.trusted'), style: AppType.caption.copyWith(color: p.textSecondary)),
                      ),
                  ],
                ),
                SheetText(context.t('kemlock.devices.kemlockUse', {'when': _when(device, device.lastKemlock)})),
                SheetText(context.t('kemlock.devices.bitwardenUse', {'when': _when(device, device.lastBitwarden)})),
                if (!device.current)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      style: TextButton.styleFrom(foregroundColor: p.error),
                      onPressed: _busy ? null : () => _signOut(device),
                      child: Text(context.t('kemlock.devices.signOut')),
                    ),
                  ),
              ],
            ),
          if (others > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: p.error),
                onPressed: _busy ? null : _signOutOthers,
                child: Text(context.t('kemlock.devices.signOutOthers')),
              ),
            ),
          if (mine != null && mine.trusted)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: _busy ? null : _removeTrust, child: Text(context.t('kemlock.devices.removeTrust'))),
            ),
          if (_busy && devices != null) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
