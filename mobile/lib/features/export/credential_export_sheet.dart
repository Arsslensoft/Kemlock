import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/credential_exchange.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../import/formats/cxf_writer.dart';
import '../spaces/hidden_passwords.dart';
import '../spaces/space_policies_provider.dart';
import '../sync/sync.dart' show SyncSettings;
import '../sync/sync_store.dart';
import '../vault/owner_check.dart';
import 'credential_export.dart';
import 'transfer_widgets.dart';

/// Opens the sheet that sends items to another app, for [target].
Future<void> showCredentialExportSheet(BuildContext context, {required CredentialExportTarget target}) => showAppBottomSheet<void>(
  context,
  label: context.t('export.cxf.title'),
  builder: (_) => CredentialExportSheet(target: target),
);

/// Send items to another app on the phone as Credential Exchange (plan add-credential-exchange,
/// task 8.2). It shows what would go, by kind, what is left out and why, and the app that receives
/// it when the system has named one; the person picks the kinds. Nothing is read before they pass
/// the owner check ([ownerCheckProvider]), whatever "Ask before showing a secret" says: every export
/// asks, as the security audit ruled. Failing it sends nothing and tells the other app so. The JSON
/// is a string in this method's scope and nowhere else: it is never stored, shown or logged, and is
/// dropped as soon as the hand-off returns.
class CredentialExportSheet extends ConsumerStatefulWidget {
  const CredentialExportSheet({super.key, required this.target});

  final CredentialExportTarget target;

  @override
  ConsumerState<CredentialExportSheet> createState() => _CredentialExportSheetState();
}

class _CredentialExportSheetState extends ConsumerState<CredentialExportSheet> {
  /// The kinds the person turned off; what is on is every kind with something to send that the
  /// receiving app asked for.
  final _off = <ExportKind>{};
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    // Closed with nothing sent: the other app learns nothing is coming
    if (!_done) {
      unawaited(widget.target.cancel());
    }
    super.dispose();
  }

  /// The plan for [vault] under [settings]' spaces: the same rules whether the sheet draws it (watching) or
  /// sends it (reading, once the owner check has passed).
  CredentialExportPlan _planOf(
    VaultState vault,
    SyncSettings? settings,
    HiddenPasswords hidden,
    Set<String> blockedSpaces,
    bool Function(String spaceId) inServerSpace,
  ) => planCredentialExport(
    vault,
    inServerSpace: inServerSpace,
    blockedSpaces: blockedSpaces,
    spaceName: (id) => spaceName(settings, id) ?? ref.read(spacePoliciesProvider).nameOf(id),
    hidesPassword: hidden.hides,
  );

  /// The kinds on for [plan]: each with something to send that the other app asked for and the person left on.
  Set<ExportKind> _pickedOf(CredentialExportPlan plan) => {
    for (final kind in ExportKind.values)
      if ((plan.counts[kind] ?? 0) > 0 && kind.askedFor(widget.target.askedTypes) && !_off.contains(kind)) kind,
  };

  /// Sends what the person saw on the sheet as [shown]: the kinds, never more.
  Future<void> _send(Set<ExportKind> shown) async {
    if (_busy) {
      return;
    }
    // Busy from the first tap, not once the check has passed: a second tap while the check is up must start
    // neither a second check nor a second export
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Before any secret is read
      final confirmed = await ref.read(ownerCheckProvider)(context, ref, context.t('export.cxf.confirm'));
      if (!confirmed) {
        await widget.target.cancel();
        if (mounted) {
          await Navigator.of(context).maybePop();
        }
        return;
      }
      if (!mounted) {
        return;
      }
      // The payload is made when the target asks for it: at once on Android, and on iOS only after the person has
      // chosen the receiving app in the system's sheet, so no plaintext waits in memory while they decide
      await widget.target.send(() async => _payload(shown));
      _done = true;
    } on _SendRefused catch (refused) {
      await widget.target.cancel();
      _fail(refused.message);
    } on CredentialExportCancelled {
      _fail('export.cxf.error.cancelled');
    } on CredentialExportFailed {
      _fail('export.cxf.error.failed');
    } on Object {
      // Whatever it was, never its text: it could hold what was being sent
      _fail('export.cxf.error.failed');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// The CXF JSON of what goes, made from the vault as it is now. What the sheet drew was the vault as it was when it
  /// opened, the owner check takes as long as the person likes, and on iOS so does the system's sheet. So everything
  /// is read again here, once the check has passed and the target asks, and only that is sent: the vault, the hidden
  /// passwords and the spaces' rules may have changed meanwhile, or the vault itself been swapped or locked.
  String _payload(Set<ExportKind> shown) {
    if (!mounted) {
      throw const CredentialExportCancelled();
    }
    final target = widget.target;
    final vault = ref.read(vaultControllerProvider);
    if (vault.phase != VaultPhase.unlocked || (target.vaultId != null && target.vaultId != vault.vault.id)) {
      throw const _SendRefused('export.cxf.wrongVault');
    }
    final plan = _planOf(
      vault,
      ref.read(syncProvider).settings,
      ref.read(hiddenPasswordsProvider),
      ref.read(blockedExportSpacesProvider),
      ref.read(serverSpaceItemProvider),
    );
    // Only kinds the person saw on the sheet, and still with something in them
    final picked = _pickedOf(plan).intersection(shown);
    if (plan.sending(picked) == 0) {
      throw const _SendRefused('export.cxf.error.failed');
    }
    final now = ref.read(clockProvider)();
    return writeCxf(plan.pick(picked), now: now.millisecondsSinceEpoch, accountId: vault.vault.id, asked: target.askedTypes).json;
  }

  void _fail(String message) {
    if (mounted) {
      setState(() => _error = context.t(message));
    }
  }

  String _join(List<String> parts) => parts.length < 2
      ? parts.join()
      : context.t('export.cxf.join', {'head': parts.sublist(0, parts.length - 1).join(', '), 'last': parts.last});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final target = widget.target;
    final app = target.appName;
    final vault = ref.watch(vaultControllerProvider);
    final plan = _planOf(
      vault,
      ref.watch(syncProvider.select((sync) => sync.settings)),
      ref.watch(hiddenPasswordsProvider),
      ref.watch(blockedExportSpacesProvider),
      ref.watch(serverSpaceItemProvider),
    );
    // Another vault than the one the other app picked: nothing here is read for it
    final wrongVault = target.vaultId != null && target.vaultId != vault.vault.id;
    final offered = [
      for (final kind in ExportKind.values)
        if ((plan.counts[kind] ?? 0) > 0) kind,
    ];
    final picked = _pickedOf(plan);
    final leftOut = plan.leftOut(picked);
    final sending = plan.sending(picked);
    final summaryItems = [
      for (final kind in ExportKind.values)
        if (picked.contains(kind) && plan.sendable(kind) > 0) context.t('export.cxf.kind.${kind.name}', {'count': plan.sendable(kind)}),
    ];
    final notCarried = [
      for (final MapEntry(:key, :value) in plan.notCarried.entries)
        if (value > 0) context.t('export.cxf.leftOut.${key.name}', {'count': value}),
    ];

    return TransferSheet(
      icon: Icons.ios_share_rounded,
      title: context.t('export.cxf.title'),
      actions: [
        SheetCloseButton(label: context.t(_done ? 'export.close' : 'export.cancel')),
        if (!_done && !wrongVault)
          FilledButton.icon(
            onPressed: _busy || sending == 0 ? null : () => unawaited(_send(picked)),
            icon: const Icon(Icons.ios_share_rounded, size: 20),
            label: Text(context.t('export.cxf.button')),
          ),
      ],
      children: spaced([
        if (wrongVault)
          AppAlert(severity: AlertSeverity.error, child: Text(context.t('export.cxf.wrongVault')))
        else ...[
          Text(
            app == null ? context.t('export.cxf.body.ios') : context.t('export.cxf.body.named', {'app': app}),
            style: AppType.body1.copyWith(color: p.textSecondary),
          ),
          // The label is the other app's own to choose; the package name is the system's
          if (target.appPackage case final package?)
            Text(context.t('export.cxf.package', {'package': package}), style: AppType.caption.copyWith(color: p.textSecondary)),
          for (final kind in offered)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: picked.contains(kind),
              onChanged: _busy || _done || !kind.askedFor(target.askedTypes)
                  ? null
                  : (on) => setState(() {
                      if (on ?? false) {
                        _off.remove(kind);
                      } else {
                        _off.add(kind);
                      }
                    }),
              title: Text(context.t('export.cxf.kind.${kind.name}', {'count': plan.counts[kind]})),
              subtitle: kind.askedFor(target.askedTypes) ? null : Text(context.t('export.cxf.kind.notAsked', {'app': app ?? ''})),
            ),
          if (sending > 0)
            Text(
              app == null
                  ? context.t('export.cxf.summary.ios', {'items': _join(summaryItems)})
                  : context.t('export.cxf.summary.named', {'items': _join(summaryItems), 'app': app}),
              style: AppType.body1.copyWith(fontWeight: FontWeight.w600),
            )
          else
            Text(context.t('export.cxf.summary.none'), style: AppType.body2.copyWith(color: p.textSecondary)),
          if (!_done)
            AppAlert(
              severity: AlertSeverity.warning,
              icon: const Icon(Icons.lock_open_rounded, size: 20),
              child: Text(context.t('export.cxf.warning')),
            ),
          if (notCarried.isNotEmpty || leftOut.isNotEmpty) ...[
            Divider(height: 1, color: p.divider),
            Text(
              context.t('export.cxf.leftOut.title'),
              style: AppType.body2.copyWith(color: p.text, fontWeight: FontWeight.w600),
            ),
            for (final line in notCarried) Text(line, style: AppType.caption.copyWith(color: p.textSecondary)),
            for (final MapEntry(:key, :value) in leftOut.entries)
              Text(context.t('export.cxf.leftOut.${key.name}', {'count': value}), style: AppType.caption.copyWith(color: p.textSecondary)),
          ],
          if (plan.serverSpaceItems > 0)
            AppAlert(severity: AlertSeverity.info, child: Text(context.t('export.cxf.serverSpaces', {'count': plan.serverSpaceItems}))),
          for (final MapEntry(:key, :value) in plan.blocked.entries)
            AppAlert(severity: AlertSeverity.info, child: Text(context.t('export.cxf.space', {'count': value, 'name': key}))),
        ],
        if (_error != null) AppAlert(severity: AlertSeverity.error, child: Text(_error!)),
        if (_done) AppAlert(severity: AlertSeverity.success, child: Text(context.t('export.cxf.sent'))),
        if (_busy) const WorkingBar(),
      ]),
    );
  }
}

/// The send was stopped when its payload was to be made, for the reason of the message [message]: the vault is not the
/// one asked for, is locked, or holds nothing to send any more. Never carries anything of the data.
class _SendRefused implements Exception {
  const _SendRefused(this.message);

  final String message;
}

/// The export sheet's row for sending to another app: a button on iOS 26, the steps to start it in
/// the other app on Android, nothing while export is off.
class CredentialExportRow extends ConsumerWidget {
  const CredentialExportRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final row = ref.watch(exportRowProvider).value ?? ExportRow.none;
    if (row == ExportRow.none) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 24, color: p.divider),
        Text(context.t('export.cxf.row.title'), style: AppType.body2.copyWith(color: p.text)),
        const SizedBox(height: 4),
        Text(
          context.t(row == ExportRow.iosStart ? 'export.cxf.row.ios' : 'export.cxf.row.android'),
          style: AppType.caption.copyWith(color: p.textSecondary),
        ),
        if (row == ExportRow.iosStart) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: smallButtonStyle,
            onPressed: () =>
                unawaited(showCredentialExportSheet(context, target: IosExportTarget(ref.read(iosCredentialExchangeProvider)))),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: Text(context.t('export.cxf.row.button')),
          ),
        ],
      ],
    );
  }
}
