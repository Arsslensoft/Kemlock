import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../sync/sync_store.dart';
import 'dedup_tagger.dart';
import 'duplicate_matcher.dart';
import 'duplicate_merge_sheet.dart';
import 'duplicate_view.dart';
import 'duplicates_provider.dart';

/// The Duplicates screen, after `Duplicates.dc.html`: the groups of items the vault holds more than
/// once, each with why it matched and its items' place and date, with Review, Not duplicates, Check
/// again and Undo merge. The vault health card opens it. Everything on it is found on this phone.
Future<void> showDuplicatesSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('duplicates.title'), builder: (_) => const _DuplicatesSheet());

class _DuplicatesSheet extends ConsumerStatefulWidget {
  const _DuplicatesSheet();

  @override
  ConsumerState<_DuplicatesSheet> createState() => _DuplicatesSheetState();
}

class _DuplicatesSheetState extends ConsumerState<_DuplicatesSheet> {
  var _filter = DuplicateFilter.all;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final found = ref.watch(duplicatesProvider);
    final groups = filtered(_filter, found.groups);
    final settings = ref.watch(syncProvider.select((sync) => sync.settings));
    final locale = Localizations.localeOf(context).toLanguageTag();
    String date(int ms) => DateFormat.yMMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(ms));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DialogHeading(icon: const Icon(Icons.copy_all_rounded), title: context.t('duplicates.title')),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text(context.t('duplicates.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                Row(
                  spacing: 8,
                  children: [
                    ExcludeSemantics(child: Icon(Icons.smartphone_rounded, size: 16, color: p.textSecondary)),
                    Expanded(
                      child: Text(
                        // With server matching on, the server suggests groups of logins, which this phone checks
                        (settings?.kemlock?.matching ?? false) ? context.t('duplicates.onDeviceServer') : context.t('duplicates.onDevice'),
                        style: AppType.caption.copyWith(color: p.textSecondary),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final filter in DuplicateFilter.values)
                      ChoiceChip(
                        key: ValueKey('filter-${filter.name}'),
                        label: Text(context.t('duplicates.filter.${filter.name}')),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                  ],
                ),
                if (!found.checked)
                  Text(context.t('duplicates.checking'), style: AppType.body2.copyWith(color: p.textSecondary))
                else if (groups.isEmpty)
                  AppAlert(severity: AlertSeverity.success, child: Text(context.t('duplicates.empty')))
                else
                  for (final group in groups)
                    _GroupCard(
                      key: ValueKey('group-${group.key}'),
                      group: group,
                      place: (item) => spaceName(settings, item.spaceId) ?? context.t('duplicates.place.vault'),
                      date: date,
                    ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: found.checking ? null : () => unawaited(ref.read(duplicatesProvider.notifier).check()),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.t('duplicates.checkAgain')),
                  ),
                ),
                if (found.records.isNotEmpty)
                  Group(
                    label: context.t('duplicates.undo.title'),
                    children: [
                      for (final (i, record) in found.records.reversed.indexed)
                        GroupRow(
                          key: ValueKey('merge-${record.id}'),
                          first: i == 0,
                          primary: record.label.isEmpty ? context.t('duplicates.undo.unnamed') : record.label,
                          secondary: context.t('duplicates.undo.detail', {'date': date(record.at), 'count': record.removed.length}),
                          control: TextButton(
                            onPressed: () => unawaited(ref.read(vaultControllerProvider.notifier).undoMerge(record.id)),
                            child: Text(context.t('duplicates.undo.button')),
                          ),
                        ),
                    ],
                  ),
                if (found.records.isNotEmpty)
                  Text(context.t('duplicates.undo.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One group: why it matched, its items with their place and date, and what to do with it.
class _GroupCard extends ConsumerWidget {
  const _GroupCard({super.key, required this.group, required this.place, required this.date});

  final DuplicateGroup group;

  /// The name of the place an item is in.
  final String Function(DedupItem item) place;
  final String Function(int ms) date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    return GroupCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Semantics(
              header: true,
              child: Text(context.t('duplicates.reason.${group.reason.name}'), style: AppType.h6.copyWith(color: p.text)),
            ),
            for (final item in group.items)
              Text(
                '${duplicateName(item.item)} · ${context.t('duplicates.item.meta', {'place': place(item), 'date': date(item.changedAt)})}',
                style: AppType.body2.copyWith(color: p.text),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => unawaited(showDuplicateMergeSheet(context, group)),
                  child: Text(context.t('duplicates.review')),
                ),
                TextButton(
                  onPressed: () => unawaited(ref.read(duplicatesProvider.notifier).dismiss(group)),
                  child: Text(context.t('duplicates.notDuplicates')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
