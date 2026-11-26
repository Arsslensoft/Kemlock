// The "Linked items" section of an item's sheet (docs/crypto.md, "Item bodies", `links`; the web vault's LinkedItems card): the
// items linked to this one, each as a row with its icon, its name and its kind that opens it, a menu to unlink it (and to mend a
// link that only one end names), and "Link an item", which opens a picker. A link names both items, so linking, unlinking and
// mending write both. A link to an item the vault doesn't hold is kept and shown as "Item not available".
//
// Every sheet of an item puts this after its custom fields and before its destructive actions, as one widget call.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kemlock_core/models/item_link.dart';
import 'package:kemlock_core/vault/item_links.dart';

import '../../crypto/account/encoding.dart' show Owner;
import '../../i18n/messages.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
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
    // Linking writes this item and the one picked; one with no item id yet (an id that is not a UUID, with no Kemlock Server account
    // to make one) can't be named by a link, so it offers none
    final mayChange = access.canEdit(held) && isLinkId(linkIdOf(held, account: account));
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
                // Only the ends the action writes need to be the person's to change
                canFix: mayFixLink(item, held, access.canEdit, account),
                canUnlink: mayUnlinkLink(item, held, access.canEdit, account),
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

/// Whether [from] names [to]: in its `links`, or by the pointer a code and its login keep (`linkedLoginId`, `accountId`).
bool _names(VaultEntry<Object?> from, VaultEntry<Object?> to, Owner? account) {
  final names = {linkIdOf(to, account: account).toLowerCase(), to.id.toLowerCase()};
  if (from.links.ids.any(names.contains)) {
    return true;
  }
  return switch (from) {
    OtpAccount(:final linkedLoginId?) => names.contains(linkedLoginId.toLowerCase()),
    Login(:final accountId?) => to is OtpAccount && accountId == to.id,
    _ => false,
  };
}

/// Whether Fix is offered for [item] of [held]: the link has one end only, and the end that doesn't name the other, which Fix
/// writes, is the person's to change.
bool mayFixLink(LinkedItem item, VaultEntry<Object?> held, bool Function(VaultEntry<Object?>) canEdit, Owner? account) {
  final other = item.entry;
  if (other == null || !item.oneWay) {
    return false;
  }
  return canEdit(_names(held, other, account) ? other : held);
}

/// Whether Unlink is offered for [item] of [held]: every end that names the other, which Unlink writes, is the person's to change.
bool mayUnlinkLink(LinkedItem item, VaultEntry<Object?> held, bool Function(VaultEntry<Object?>) canEdit, Owner? account) {
  final other = item.entry;
  if (other == null) {
    return false;
  }
  return [if (_names(held, other, account)) held, if (_names(other, held, account)) other].every(canEdit);
}

enum _RowAction { fix, unlink }

/// One linked item: its row, and the menu of what can be done to the link.
class _LinkRow extends ConsumerWidget {
  const _LinkRow({super.key, required this.first, required this.item, required this.entry, required this.canFix, required this.canUnlink});

  final bool first;
  final LinkedItem item;

  /// The item whose sheet this is.
  final VaultEntry<Object?> entry;

  /// The link can be mended: the end it lacks is the person's to change.
  final bool canFix;

  /// The link can be removed: the ends that name it are the person's to change.
  final bool canUnlink;

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
    if (!canFix && !canUnlink) {
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
              if (canFix) PopupMenuItem(value: _RowAction.fix, child: Text(context.t('links.fix'))),
              if (canUnlink) PopupMenuItem(value: _RowAction.unlink, child: Text(context.t('links.unlink'))),
            ],
          ),
        ),
      ),
    );
  }
}
