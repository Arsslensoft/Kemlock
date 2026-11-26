import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell_page.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/backup_service.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'add_backup_service_sheet.dart';
import 'backup_codes.dart';
import 'backup_service_card.dart';
import 'coverage_card.dart';

/// The Backup tab, `routes/backup.tsx`: the coverage check, how many codes
/// are left, and a card per service, one open at a time; the first starts
/// open. "Use next code" copies the first unused code and crosses it off,
/// with Undo in the toast.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key, this.openId});

  /// The service whose card starts open, when the page was opened for it (a link to it); null for the first one.
  final String? openId;

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  /// Until a card is opened or closed, the first service starts open (also right after the first add).
  late bool _chosen = widget.openId != null;
  late String? _openId = widget.openId;

  @override
  void didUpdateWidget(BackupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openId != null && widget.openId != oldWidget.openId) {
      _chosen = true;
      _openId = widget.openId;
    }
  }

  VaultController get _vault => ref.read(vaultControllerProvider.notifier);

  /// Copies the next unused code and crosses it off, with an Undo in the toast.
  Future<void> _takeNextCode(BackupService service) async {
    final index = service.codes.indexWhere((code) => !code.used);
    if (index == -1) return;
    final code = service.codes[index].code;
    if (!await ref.read(secretClipboardProvider).copy(code) || !mounted) return;
    final vault = _vault;
    unawaited(vault.setBackupCodeUsed(service.id, index, true));
    ref
        .read(toastsProvider.notifier)
        .show(
          context.t('backup.usedToast', {'code': code}),
          actionLabel: context.t('backup.undo'),
          onAction: () => unawaited(vault.setBackupCodeUsed(service.id, index, false)),
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    final services = state.backupServices;
    final openId = _chosen ? _openId : services.firstOrNull?.id;
    final left = services.fold(0, (sum, service) => sum + service.codes.where((code) => !code.used).length);
    final lowCount = services.where(isLow).length;

    return ShellPage(
      children: [
        const SizedBox(height: 40),
        PageTitle(title: context.t('app.tab.backupCodes'), subtitle: context.t('backup.subtitle')),
        CoverageCard(
          accounts: state.accounts,
          backupServices: services,
          onAddCodes: (name) => unawaited(showAddBackupServiceSheet(context, initialName: name)),
          onNoCodes: (account) => unawaited(_vault.updateAccount(account.copyWith(noBackupCodes: true))),
        ),
        if (services.isEmpty)
          EmptyState(
            icon: const Icon(Icons.confirmation_number_outlined),
            title: context.t('app.empty.backup.title'),
            body: context.t('app.empty.backup.body'),
            action: FilledButton.icon(
              style: largeButtonStyle,
              onPressed: () => unawaited(showAddBackupServiceSheet(context)),
              icon: const Icon(Icons.add_rounded),
              label: Text(context.t('app.empty.backup.action')),
            ),
          )
        else ...[
          const SizedBox(height: 20),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _Stat(value: left, label: context.t('backup.stat.left', {'count': left})),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(value: services.length, label: context.t('app.counter.services', {'count': services.length})),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(value: lowCount, label: context.t('backup.stat.low'), warn: lowCount > 0),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final (i, service) in services.indexed)
            BackupServiceCard(
              key: ValueKey(service.id),
              index: i,
              service: service,
              open: openId == service.id,
              onToggle: () => setState(() {
                _chosen = true;
                _openId = openId == service.id ? null : service.id;
              }),
              onUpdate: (updated) => unawaited(_vault.updateBackupService(updated)),
              onDelete: (id) => unawaited(_vault.deleteBackupService(id)),
              onUseNext: (service) => unawaited(_takeNextCode(service)),
            ),
        ],
      ],
    );
  }
}

/// A number over what it counts, amber when [warn].
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.warn = false});

  final int value;
  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final duration = Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 400);
    return MergeSemantics(
      child: AnimatedContainer(
        duration: duration,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: warn ? b.warnSoft : p.paper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: warn ? Colors.transparent : p.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedDefaultTextStyle(
              duration: duration,
              style: AppType.mono(fontSize: 26, fontWeight: FontWeight.w500, color: warn ? p.warning : p.text).copyWith(height: 1),
              child: Text('$value'),
            ),
            const SizedBox(height: 6),
            AnimatedDefaultTextStyle(
              duration: duration,
              style: AppType.caption.copyWith(color: warn ? p.warning : p.textSecondary),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
