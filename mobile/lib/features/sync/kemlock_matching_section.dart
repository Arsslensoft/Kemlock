/// The switches for server matching in the Kemlock Server sheet (add-duplicate-cleaner, task 7.2):
///
/// - **The vault's switch.** Off until the person turns it on, and turning it on opens an explainer of what the
///   server would learn first; cancelling it sends nothing. Turning it off calls `DELETE /kem/v1/duplicates/tags`,
///   which deletes every tag the server holds, and on-device matching goes on working.
/// - **A space's switch,** for each server space the account is in. Only the space's owners and admins can change it;
///   a member sees its state.
/// - **The notice** every member of a space sees at their next sync when an admin turned matching on.
///
/// The cleaner works without any of it: this only lets the server suggest groups of logins, which the phone checks.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_dedup_api.dart';
import 'kemlock/km_models.dart';
import 'kemlock_matching.dart';
import 'sync_store.dart';

/// The matching section of the sheet of a vault that syncs with Kemlock Server.
class KemlockMatchingSection extends ConsumerStatefulWidget {
  const KemlockMatchingSection({super.key, required this.target});

  final KemlockTarget target;

  @override
  ConsumerState<KemlockMatchingSection> createState() => _KemlockMatchingSectionState();
}

class _KemlockMatchingSectionState extends ConsumerState<KemlockMatchingSection> {
  var _busy = false;
  var _failed = false;

  /// What the server says of each space's switch, by owner; a space the server hasn't answered for has no switch to show.
  final _spaces = <String, KmMatchingSettings>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadSpaces());
  }

  Future<void> _loadSpaces() async {
    final matching = ref.read(kemlockMatchingProvider);
    for (final space in ref.read(kemlockDedupSpacesProvider)) {
      try {
        final settings = await matching.settings(widget.target, space.owner);
        if (mounted) {
          setState(() => _spaces[space.owner] = settings);
        }
      } on KmError {
        // No switch for a space the server can't be asked about
      }
    }
  }

  Future<void> _save(KemlockTarget next) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) {
      return;
    }
    final store = ref.read(syncProvider.notifier);
    await store.saveSettings((store.snapshot.settings ?? noSync).copyWith(kemlock: next), session);
  }

  /// What the server would learn, before anything is sent. True when the person turns it on.
  Future<bool> _explain({String? space}) => showConfirmDialog(
    context,
    icon: const Icon(Icons.copy_all_rounded),
    title: context.t('kemlock.matching.explainer.title'),
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Text(context.t('kemlock.matching.explainer.sends')),
        Text(context.t('kemlock.matching.explainer.learns')),
        Text(context.t('kemlock.matching.explainer.never')),
        if (space != null) Text(context.t('kemlock.matching.explainer.space', {'space': space})),
      ],
    ),
    confirmLabel: context.t('kemlock.matching.explainer.confirm'),
    cancelLabel: context.t('kemlock.matching.explainer.cancel'),
    danger: false,
  );

  Future<void> _setVault(bool on) async {
    final target = widget.target;
    if (on && !await _explain()) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final matching = ref.read(kemlockMatchingProvider);
      if (on) {
        await matching.turnOn(target, kemlockVaultOwner(target));
      } else {
        // The tags the server holds are deleted before the phone says it is off
        await matching.turnOff(target, kemlockVaultOwner(target));
        ref.read(kemlockHintsProvider.notifier).set(null);
      }
      await _save(target.copyWith(matching: on));
    } on KmError {
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _setSpace(KmDedupSpace space, bool on) async {
    if (on && !await _explain(space: space.name)) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final matching = ref.read(kemlockMatchingProvider);
      final settings = on ? await matching.turnOn(widget.target, space.owner) : await matching.turnOff(widget.target, space.owner);
      if (mounted) {
        setState(() => _spaces[space.owner] = settings);
      }
    } on KmError {
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final offline = ref.watch(offlineProvider);
    final spaces = ref.watch(kemlockDedupSpacesProvider);
    final notices = ref.watch(kemlockMatchingNoticesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(context.t('kemlock.matching.title'), style: AppType.h6.copyWith(color: p.text)),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: widget.target.matching,
          onChanged: _busy || offline ? null : (on) => unawaited(_setVault(on)),
          title: Text(context.t('kemlock.matching.switch')),
          subtitle: Text(context.t('kemlock.matching.hint')),
        ),
        for (final space in spaces)
          SwitchListTile.adaptive(
            key: ValueKey('matching-${space.id}'),
            contentPadding: EdgeInsets.zero,
            value: _spaces[space.owner]?.enabled ?? false,
            // Only a space's owners and admins may change it, and a member sees where it stands
            onChanged: space.admin && !_busy && !offline && _spaces.containsKey(space.owner)
                ? (on) => unawaited(_setSpace(space, on))
                : null,
            title: Text(space.name),
            subtitle: Text(context.t('kemlock.matching.space.hint', {'admin': space.admin ? 'yes' : 'no'})),
          ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AppAlert(severity: AlertSeverity.error, child: Text(context.t('kemlock.matching.failed'))),
          ),
        for (final notice in notices)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AppAlert(
              severity: AlertSeverity.info,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.t('kemlock.matching.notice', {'space': notice.name})),
                  TextButton(
                    onPressed: () => unawaited(ref.read(kemlockMatchingNoticesProvider.notifier).dismiss(notice)),
                    child: Text(context.t('kemlock.matching.notice.dismiss')),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
