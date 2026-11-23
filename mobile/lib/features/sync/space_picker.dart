import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'sync.dart';
import 'sync_store.dart';

/// The menu's value for the vault's own entries, which have no space id.
const _mine = '__mine__';

/// Where an account or backup-code service lives: the vault itself or a
/// shared space, ported from `SpacePicker.tsx`. [onChanged] gets the
/// space's id, or null for the vault's own entries.
///
/// It shows only when there's a space to pick, or when the entry is already
/// in one so it can be taken back out; otherwise it takes no room. An entry
/// in a space this vault has left shows "A space you left", which can't be
/// picked again; picking "Just me" brings the entry home.
///
/// ```dart
/// SpacePicker(value: account.spaceId, onChanged: (id) => setState(() => _spaceId = id))
/// ```
class SpacePicker extends ConsumerWidget {
  const SpacePicker({super.key, required this.value, required this.onChanged, this.small = false});

  /// The entry's space id, or null when it's the vault's own.
  final String? value;
  final ValueChanged<String?> onChanged;

  /// The compact field (MUI's `size="small"`), as on a backup-code card.
  final bool small;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spaces = ref.watch(syncProvider.select((sync) => sync.settings?.spaces ?? const <Space>[]));
    final current = value == null || value!.isEmpty ? null : value;
    if (spaces.isEmpty && current == null) return const SizedBox.shrink();
    final known = spaces.any((space) => space.id == current);
    final p = context.palette;
    final b = context.bmc;
    Widget label(String text) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    // Aligned, the menu opens as wide as the field and its items line up with the field's text.
    return ButtonTheme(
      alignedDropdown: true,
      child: DropdownButtonFormField<String>(
        // The field keeps its own selection; a new value from outside starts it again.
        key: ValueKey(current ?? _mine),
        initialValue: current ?? _mine,
        isExpanded: true,
        // As tall as the text, so the field is as tall as a text field
        isDense: true,
        borderRadius: BorderRadius.circular(appRadius),
        dropdownColor: b.raised,
        style: AppType.body1.copyWith(color: p.text),
        icon: const Icon(Icons.expand_more_rounded),
        decoration: InputDecoration(
          labelText: context.t('spaces.picker.label'),
          isDense: small,
          contentPadding: small ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8.5) : null,
        ),
        items: [
          DropdownMenuItem(value: _mine, child: label(context.t('spaces.picker.mine'))),
          for (final space in spaces) DropdownMenuItem(value: space.id, child: label(space.name)),
          if (current != null && !known) DropdownMenuItem(value: current, enabled: false, child: label(context.t('spaces.picker.left'))),
        ],
        onChanged: (picked) => onChanged(picked == null || picked == _mine ? null : picked),
      ),
    );
  }
}
