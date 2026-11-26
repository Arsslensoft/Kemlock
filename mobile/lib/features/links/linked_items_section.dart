// The "Linked items" section of an item's sheet (docs/crypto.md, "Item bodies", `links`; the web vault's LinkedItems card): the
// items linked to this one, each as a row with its icon, its name and its kind that opens it, a menu to unlink it (and to mend a
// link that only one end names), and "Link an item", which opens a picker. A link names both items, so linking, unlinking and
// mending write both. A link to an item the vault doesn't hold is kept and shown as "Item not available".
//
// Every sheet of an item puts this after its custom fields and before its destructive actions, as one widget call.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_core/vault/item_links.dart';

import '../../i18n/messages.dart';
import '../../models/vault_entry.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../spaces/hidden_passwords.dart';
import 'link_account.dart';
import 'link_picker_sheet.dart';
import 'link_view.dart';
import 'open_entry.dart';

/// The items [entry] is linked to, with the actions on them. Shows nothing when there are none and the person may not change
/// [entry]; with none and the right to, only "Link an item".
class LinkedItemsSection extends ConsumerWidget {
  const LinkedItemsSection({super.key, required this.entry});

  /// The item whose sheet this is, as the vault holds it now.
  final VaultEntry<Object?> entry;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final picked = await showLinkPicker(context, entry: entry);
    if (picked == null || !context.mounted) {
      return;
    }
    await ref.read(vaultControllerProvider.notifier).linkItems(entry, picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(hiddenPasswordsProvider);
    final account = ref.watch(linkAccountProvider);
    final lists = ref.watch(vaultControllerProvider).lists;
    // The vault's copy, so what a link or an unlink just wrote shows at once, whichever copy the sheet holds
    final held = entriesOf(lists).where((other) => other.runtimeType == entry.runtimeType && other.id == entry.id).firstOrNull ?? entry;
    final linked = linkedItemsOf(lists, held, account: account).toList()
      ..sort((a, b) {
        // The items of the vault by name; the ones it doesn't hold last
        if ((a.entry == null) != (b.entry == null)) {
          return a.entry == null ? 1 : -1;
        }
        final byName = a.entry == null ? 0 : entryName(a.entry!).toLowerCase().compareTo(entryName(b.entry!).toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    final mayChange = access.canEdit(held);
    if (linked.isEmpty && !mayChange) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const ValueKey('linked-items'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Group(
          label: context.t('links.title'),
          children: [
            for (final (i, item) in linked.indexed)
              _LinkRow(
                key: ValueKey('linked:${item.id}'),
                first: i == 0,
                item: item,
                entry: held,
                canChange: mayChange && item.entry != null && access.canEdit(item.entry!),
              ),
            if (mayChange)
              GroupRow(
                key: const ValueKey('link-add'),
                first: linked.isEmpty,
                icon: const Icon(Icons.add_link_rounded),
                accent: true,
                primary: context.t('links.add'),
                onTap: () => unawaited(_add(context, ref)),
              ),
          ],
        ),
      ],
    );
  }
}

enum _RowAction { fix, unlink }

/// One linked item: its row, and the menu of what can be done to the link.
class _LinkRow extends ConsumerWidget {
  const _LinkRow({super.key, required this.first, required this.item, required this.entry, required this.canChange});

  final bool first;
  final LinkedItem item;

  /// The item whose sheet this is.
  final VaultEntry<Object?> entry;

  /// The person may change both ends, so the link can be unlinked or mended.
  final bool canChange;

  Future<void> _act(WidgetRef ref, _RowAction action) {
    final other = item.entry!;
    final vault = ref.read(vaultControllerProvider.notifier);
    return switch (action) {
      _RowAction.fix => vault.linkItems(entry, other),
      _RowAction.unlink => vault.unlinkItems(entry, other),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final other = item.entry;
    if (other == null) {
      // The link stays: nothing here holds the item, so there is nothing to open or to unlink
      return GroupRow(
        first: first,
        icon: const Icon(Icons.link_off_rounded),
        primary: context.t('links.unavailable'),
        secondary: context.t('links.unavailable.hint'),
        muted: true,
      );
    }
    final name = entryName(other).isEmpty ? context.t('links.unnamed') : entryName(other);
    final kind = context.t(entryKindLabelId(other));
    final secondary = item.oneWay ? '$kind · ${context.t('links.oneWay')}' : kind;
    void open() => unawaited(openLinkedEntry(context, ref, other));
    if (!canChange) {
      return GroupRow(first: first, icon: Icon(entryIcon(other)), primary: name, secondary: secondary, onTap: open);
    }
    return Semantics(
      container: true,
      child: InkWell(
        onTap: open,
        child: GroupRow(
          first: first,
          icon: Icon(entryIcon(other)),
          primary: name,
          secondary: secondary,
          control: PopupMenuButton<_RowAction>(
            key: ValueKey('linked-menu:${item.id}'),
            tooltip: context.t('links.menu', {'name': name}),
            icon: Icon(Icons.more_horiz_rounded, color: context.bmc.faint),
            onSelected: (action) => unawaited(_act(ref, action)),
            itemBuilder: (_) => [
              if (item.oneWay) PopupMenuItem(value: _RowAction.fix, child: Text(context.t('links.fix'))),
              PopupMenuItem(value: _RowAction.unlink, child: Text(context.t('links.unlink'))),
            ],
          ),
        ),
      ),
    );
  }
}
