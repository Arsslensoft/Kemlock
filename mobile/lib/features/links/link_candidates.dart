// What the "Link an item" picker offers for an item (the web vault's `linkCandidates`): the items of the vault, in the person's
// own vault and in the spaces they can write to, that are not the item itself and are not linked to it already, narrowed by what
// they typed. A link writes both items, so an item the person may not change is not offered. Pure Dart, no widgets.

import 'package:kemlock_core/vault/item_links.dart';

import '../../crypto/account/encoding.dart' show Owner;
import '../../models/vault_entry.dart';
import '../sync/sync_merge.dart' show Lists;
import 'link_view.dart';

/// The entries of [lists] that [entry] can be linked to, [query] being words that each must be in the entry's name or one of the
/// lines its kind is found by, ignoring case. Sorted by name, then kind. [canEdit] says whether the person may change an entry:
/// the picker offers none they may not. [account] is the vault's Kemlock Server account owner, for the item ids of the entries.
List<VaultEntry<dynamic>> linkCandidates(
  Lists lists,
  VaultEntry<dynamic> entry, {
  String query = '',
  bool Function(VaultEntry<dynamic> candidate)? canEdit,
  Owner? account,
}) {
  final linked = linkedItemsOf(lists, entry, account: account);
  final taken = {
    for (final item in linked)
      if (item.entry case final other?) (other.runtimeType, other.id),
  };
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  bool matches(VaultEntry<dynamic> candidate) {
    if (words.isEmpty) {
      return true;
    }
    final text = entrySearchText(candidate).map((line) => line.toLowerCase()).toList();
    return words.every((word) => text.any((line) => line.contains(word)));
  }

  final found = [
    for (final candidate in entriesOf(lists))
      if (!(candidate.runtimeType == entry.runtimeType && candidate.id == entry.id) &&
          !taken.contains((candidate.runtimeType, candidate.id)) &&
          (canEdit?.call(candidate) ?? true) &&
          matches(candidate))
        candidate,
  ];
  found.sort((a, b) {
    final byName = entryName(a).toLowerCase().compareTo(entryName(b).toLowerCase());
    return byName != 0 ? byName : entryKindLabelId(a).compareTo(entryKindLabelId(b));
  });
  return found;
}
