import 'package:flutter/material.dart';

import '../../../i18n/messages.dart';
import '../../../ui/ui.dart';

/// "Keep it": in this vault, or on the security key the vault knows
/// (openspec: add-security-key-codes, decision 9). On the key, the secret
/// is written there and never stored in the vault.
class KeepItChoice extends StatelessWidget {
  const KeepItChoice({super.key, required this.onKey, required this.onChanged});

  /// Whether "On your key" is chosen.
  final bool onKey;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(context.t('keyCodes.keep'), padding: const EdgeInsets.fromLTRB(6, 0, 6, 8)),
        SegmentedControl<bool>(
          semanticLabel: context.t('keyCodes.keep'),
          value: onKey,
          onChanged: onChanged,
          options: [
            SegmentOption(value: false, label: context.t('keyCodes.keep.vault'), icon: const Icon(Icons.lock_outline_rounded)),
            SegmentOption(value: true, label: context.t('keyCodes.keep.key'), icon: const Icon(Icons.key_rounded)),
          ],
        ),
        if (onKey)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Text(context.t('keyCodes.keep.detail'), style: AppType.caption.copyWith(color: p.textSecondary)),
          ),
      ],
    );
  }
}
