import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_store.dart';
import '../sync/sync_store.dart';

/// What an old phone backup still gives away for the vault once its key
/// pair is replaced, and what the person can do about each (openspec:
/// replace-vault-key-pair, decision 9): built from what the vault holds now,
/// a line only for what it has, and never a word that old backups or
/// exports stopped opening, since nothing on the phone can reach them.
class KeyReplacedSummary extends ConsumerWidget {
  const KeyReplacedSummary({super.key, required this.oldKit, required this.lastExportAt});

  /// The Recovery Kit the vault had before, whose pieces still open the
  /// exports made while it existed.
  final RecoveryKitInfo? oldKit;

  /// When the last encrypted export was made, in ms, as Prefs keeps it.
  final int? lastExportAt;

  /// The message ids of the lines that apply, with their icons.
  static List<(IconData, String)> linesFor(
    VaultState vault, {
    ({bool webDav, bool spaces, bool vaultwarden})? sync,
    RecoveryKitInfo? oldKit,
    int? lastExportAt,
  }) {
    final kitMadeAt = oldKit == null ? null : DateTime.tryParse(oldKit.createdAt)?.millisecondsSinceEpoch;
    return [
      if (vault.accounts.isNotEmpty) (Icons.pin_outlined, 'replaceKey.done.codes'),
      if (vault.backupServices.isNotEmpty) (Icons.password_rounded, 'replaceKey.done.backupCodes'),
      if (vault.keys.isNotEmpty) (Icons.vpn_key_outlined, 'replaceKey.done.keys'),
      if (vault.passkeys.isNotEmpty) (Icons.fingerprint_rounded, 'replaceKey.done.passkeys'),
      if (vault.notes.isNotEmpty) (Icons.sticky_note_2_outlined, 'replaceKey.done.notes'),
      if (sync?.webDav ?? false) (Icons.cloud_outlined, 'replaceKey.done.webdav'),
      if (sync?.spaces ?? false) (Icons.groups_outlined, 'replaceKey.done.spaces'),
      if (sync?.vaultwarden ?? false) (Icons.shield_outlined, 'replaceKey.done.vaultwarden'),
      // An export made while the old kit existed carries a wrap the old pieces open
      if (kitMadeAt != null && lastExportAt != null && lastExportAt >= kitMadeAt) (Icons.description_outlined, 'replaceKey.done.exports'),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final vault = ref.watch(vaultControllerProvider);
    final settings = ref.watch(syncProvider.select((sync) => sync.settings));
    final sync = settings == null
        ? null
        : (webDav: settings.personal != null, spaces: settings.spaces.isNotEmpty, vaultwarden: settings.vaultwarden != null);
    final lines = linesFor(vault, sync: sync, oldKit: oldKit, lastExportAt: lastExportAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        Text(
          context.t(lines.isEmpty ? 'replaceKey.done.nothing' : 'replaceKey.done.body'),
          style: AppType.body2.copyWith(color: p.textSecondary),
        ),
        for (final (icon, id) in lines)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 20, color: context.bmc.accentText),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(context.t(id), style: AppType.body2.copyWith(color: p.text)),
              ),
            ],
          ),
      ],
    );
  }
}
