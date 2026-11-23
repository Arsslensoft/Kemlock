/// "Move to your key" and "Copy to your key" in a vault account's sheet,
/// and the flow behind them and behind adding an account straight to the
/// key (openspec: add-security-key-codes, decision 9).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/otp_account.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../security_keys/key_account_transfer.dart';
import '../security_keys/key_codes.dart';
import '../security_keys/key_codes_flow.dart';

/// Puts [account] on the key the person presents, as [mode] says: refused
/// with its reason when no key can hold it, then (for a move or a copy) the
/// confirmation with its warnings and the touch choice, then the key, its
/// password if it has one, and a question before a name already on the key
/// is replaced. True once it is on the key.
Future<bool> transferToKey(BuildContext context, WidgetRef ref, OtpAccount account, KeyTransfer mode, {KeyRunner? runner}) async {
  final refused = keyTransferRefusal(account);
  if (refused != null) {
    showKeyCodesProblem(context, refused);
    return false;
  }
  var touch = false;
  if (mode != KeyTransfer.add) {
    final chosen = await showAppDialog<bool>(context, builder: (_) => KeyTransferDialog(mode: mode));
    if (chosen == null || !context.mounted) return false;
    touch = chosen;
  }
  final codes = ref.read(keyCodesProvider.notifier);
  final vault = ref.read(vaultControllerProvider.notifier);
  final clock = ref.read(clockProvider);
  final name = account.issuer.isNotEmpty ? account.issuer : account.label;
  var replace = false;
  while (true) {
    final result = await runKeyCodes(
      context,
      ref,
      (accessKey, remember) => putOnKey(
        codes,
        vault,
        account,
        mode: mode,
        nowSec: () => clock().millisecondsSinceEpoch ~/ 1000,
        touch: touch,
        replace: replace,
        runner: runner,
        accessKey: accessKey,
        remember: remember,
      ),
    );
    if (!context.mounted) return result.ok;
    if (result.outcome == KeyCodesOutcome.exists && !replace) {
      final confirmed = await showConfirmDialog(
        context,
        icon: const Icon(Icons.swap_horiz_rounded),
        title: context.t('keyCodes.replace.title'),
        body: Text(context.t('keyCodes.replace.body', {'name': keyNameOf(account)})),
        cancelLabel: context.t('export.cancel'),
        confirmLabel: context.t('keyCodes.replace.confirm'),
      );
      if (!confirmed || !context.mounted) return false;
      replace = true;
      continue;
    }
    if (result.ok) {
      final done = switch (mode) {
        KeyTransfer.move => 'keyCodes.moved',
        KeyTransfer.copy => 'keyCodes.copied',
        KeyTransfer.add => 'keyCodes.added',
      };
      showToast(context, context.t(done, {'name': name}));
    }
    return result.ok;
  }
}

/// Asks before a move or a copy: what happens, and before a move the two
/// things the person cannot guess (a lost key takes the codes with it;
/// backups and other phones made before today still hold the secret).
/// Pops with whether the key should ask for a touch for each code.
class KeyTransferDialog extends StatefulWidget {
  const KeyTransferDialog({super.key, required this.mode});

  final KeyTransfer mode;

  @override
  State<KeyTransferDialog> createState() => _KeyTransferDialogState();
}

class _KeyTransferDialogState extends State<KeyTransferDialog> {
  var _touch = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final move = widget.mode == KeyTransfer.move;
    final title = context.t(move ? 'keyCodes.move.title' : 'keyCodes.copy.title');
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.key_rounded), title: title, tone: DialogTone.accent),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.t(move ? 'keyCodes.move.body' : 'keyCodes.copy.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          if (move) ...[
            const SizedBox(height: 12),
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('keyCodes.move.warning.lost'))),
            const SizedBox(height: 8),
            AppAlert(severity: AlertSeverity.info, child: Text(context.t('keyCodes.move.warning.backups'))),
          ],
          const SizedBox(height: 6),
          MergeSemantics(
            child: InkWell(
              onTap: () => setState(() => _touch = !_touch),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Checkbox(
                      value: _touch,
                      onChanged: (value) => setState(() => _touch = value ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(context.t('keyCodes.move.touch'), style: AppType.body1.copyWith(color: p.text)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('export.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_touch),
          child: Text(context.t(move ? 'keyCodes.move.confirm' : 'keyCodes.copy.confirm')),
        ),
      ],
    );
  }
}

/// "Move to your key" and "Copy to your key", for a vault that knows a
/// key. A shared space's account gets neither: it belongs to the space.
class KeyTransferActions extends ConsumerWidget {
  const KeyTransferActions({super.key, required this.account});

  final OtpAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final knowsKey = ref.watch(vaultControllerProvider.select((state) => state.keyAccounts.isNotEmpty));
    if (!knowsKey || account.spaceId != null) return const SizedBox.shrink();

    Widget action(KeyTransfer mode, IconData icon, String label) => OutlinedButton.icon(
      onPressed: () async {
        final navigator = Navigator.of(context);
        // A moved account is no longer in the vault: its sheet closes.
        if (await transferToKey(context, ref, account, mode) && mode == KeyTransfer.move && navigator.mounted) navigator.pop();
      },
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      icon: Icon(icon, size: 20),
      label: Text(label),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          action(KeyTransfer.move, Icons.key_rounded, context.t('keyCodes.move')),
          const SizedBox(height: 8),
          action(KeyTransfer.copy, Icons.copy_all_rounded, context.t('keyCodes.copy')),
        ],
      ),
    );
  }
}
