/// The push switch of the Kemlock Server sheet (add-kemlock-server-sync, design 13; plan add-unifiedpush).
///
/// Where the phone's push is APNs it is a plain switch. On Android the push is UnifiedPush, which needs an app that
/// delivers it (a distributor: ntfy, NextPush, ...), so the switch is also where the person gets one:
///
/// - **None installed:** the switch can't be turned on. It says so and links to the page that lists distributors.
/// - **One or several, none chosen:** turning it on registers with the only one, or with the system's default, which the
///   system asks the person to pick on its own screen.
/// - **One in use:** it is named, and with several installed the person can change it.
///
/// Turning it off saves the switch first, so the next run no longer registers the token, then asks the server to forget it and
/// gives the registration back to the distributor.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/links.dart';
import '../../platform/push.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'kemlock/km_models.dart';
import 'kemlock_push.dart';
import 'sync_store.dart';

/// The page that lists the apps that deliver UnifiedPush, which the switch links to when there is none on the phone.
final unifiedPushDistributorsPage = Uri.parse('https://unifiedpush.org/users/distributors/');

/// The distributors the phone has and the one in use. It reads again each time the sheet opens, and after the person
/// starts, changes or stops the push.
final pushDistributorsProvider = FutureProvider.autoDispose<PushDistributors>((ref) => ref.watch(pushTokensProvider).distributors());

/// The push switch of [target]; [disabled] holds it while the sheet is busy.
class KemlockPushSwitch extends ConsumerStatefulWidget {
  const KemlockPushSwitch({super.key, required this.target, this.disabled = false});

  final KemlockTarget target;
  final bool disabled;

  @override
  ConsumerState<KemlockPushSwitch> createState() => _KemlockPushSwitchState();
}

class _KemlockPushSwitchState extends ConsumerState<KemlockPushSwitch> {
  var _working = false;

  /// The push switch: turning it on makes the push ready first (a distributor, for UnifiedPush) and leaves it off when the
  /// person goes back; turning it off is saved first, so the next run no longer registers the token, then the server is
  /// asked to forget it. The server not answering changes nothing: the phone drops the nudges anyway.
  Future<void> _set(bool on) async {
    // Read before anything is awaited: the person may leave the sheet while the system's screen is open
    final push = ref.read(pushTokensProvider);
    final session = ref.read(vaultControllerProvider).session;
    final store = ref.read(syncProvider.notifier);
    final off = ref.read(kemlockPushOffProvider);
    if (session == null) return;
    setState(() => _working = true);
    try {
      Future<void> save(KemlockTarget next) => store.saveSettings((store.snapshot.settings ?? noSync).copyWith(kemlock: next), session);
      if (on) {
        if (push.choosesDistributor && !await push.start()) return;
        await save(widget.target.copyWith(push: true));
      } else {
        final next = widget.target.copyWith(push: false);
        await save(next);
        try {
          await off(next);
        } on Object {
          // Best effort
        }
        try {
          await push.stop();
        } on Object {
          // Best effort
        }
      }
    } finally {
      if (mounted) {
        ref.invalidate(pushDistributorsProvider);
        setState(() => _working = false);
      }
    }
  }

  Future<void> _change() async {
    setState(() => _working = true);
    try {
      await ref.read(pushTokensProvider).change();
    } finally {
      if (mounted) {
        ref.invalidate(pushDistributorsProvider);
        setState(() => _working = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final push = ref.watch(pushTokensProvider);
    if (!push.choosesDistributor) {
      return SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: widget.target.push,
        onChanged: widget.disabled || _working ? null : (on) => unawaited(_set(on)),
        title: Text(context.t('kemlock.push')),
        subtitle: Text(context.t('kemlock.push.hint')),
      );
    }
    final caption = AppType.caption.copyWith(color: context.palette.textSecondary);
    // Null while the phone is asked
    final distributors = ref.watch(pushDistributorsProvider).value;
    final none = distributors != null && distributors.installed.isEmpty;
    final inUse = distributors?.inUse;
    // On means the person wants push and a distributor is in use: with none chosen yet, the switch asks for one
    final on = widget.target.push && inUse != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: on,
          onChanged: widget.disabled || _working || distributors == null || none ? null : (value) => unawaited(_set(value)),
          title: Text(context.t('kemlock.push.changes')),
          subtitle: Text(context.t(none ? 'kemlock.push.unifiedpush.none' : 'kemlock.push.unifiedpush.hint')),
        ),
        if (none)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => unawaited(ref.read(linkOpenerProvider).open(context, unifiedPushDistributorsPage)),
              icon: const Icon(Icons.open_in_new_rounded, size: 20),
              label: Text(context.t('kemlock.push.unifiedpush.get')),
            ),
          ),
        if (inUse != null)
          Row(
            children: [
              Expanded(child: Text(context.t('kemlock.push.unifiedpush.using', {'name': inUse.name}), style: caption)),
              if (distributors!.installed.length > 1)
                TextButton(
                  onPressed: widget.disabled || _working ? null : () => unawaited(_change()),
                  child: Text(context.t('kemlock.push.unifiedpush.change')),
                ),
            ],
          ),
      ],
    );
  }
}
