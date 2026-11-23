import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'import_merge.dart';

/// Picks whether an import is merged into the vault or replaces it.
class ImportModeControl extends StatelessWidget {
  const ImportModeControl({super.key, required this.value, required this.onChanged});

  final ImportMode value;
  final ValueChanged<ImportMode> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedControl<ImportMode>(
    semanticLabel: context.t('import.step3'),
    value: value,
    onChanged: onChanged,
    options: [
      SegmentOption(value: ImportMode.merge, label: context.t('import.mode.merge'), icon: const Icon(Icons.merge_type_rounded)),
      SegmentOption(value: ImportMode.replace, label: context.t('import.mode.replace'), icon: const Icon(Icons.swap_horiz_rounded)),
    ],
  );
}
