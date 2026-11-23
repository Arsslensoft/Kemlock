import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/website_rule.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../spaces/hidden_passwords.dart';
import '../sync/sync_store.dart';
import 'dedup_tagger.dart';
import 'duplicate_matcher.dart';
import 'duplicate_merge.dart';
import 'duplicate_view.dart';
import 'duplicates_provider.dart';

/// The merge of one group of duplicates, after `DuplicateMerge.dc.html`: which item stays, the
/// fields that differ with the newest value chosen, the websites kept, the code a login is linked
/// to, and a note on the previous passwords, then Merge, Not duplicates and Cancel. The Duplicates
/// screen opens it with Review.
///
/// [readOnlySlots] are the places whose items the person can't change; a group whose kept item is
/// in one only has the other copy removed.
Future<void> showDuplicateMergeSheet(BuildContext context, DuplicateGroup group, {Set<String> readOnlySlots = const {}}) =>
    showAppBottomSheet<void>(
      context,
      label: context.t('duplicates.merge.title'),
      builder: (_) => DuplicateMergeSheet(group: group, readOnlySlots: readOnlySlots),
    );

class DuplicateMergeSheet extends ConsumerStatefulWidget {
  const DuplicateMergeSheet({super.key, required this.group, this.readOnlySlots = const {}});

  final DuplicateGroup group;
  final Set<String> readOnlySlots;

  @override
  ConsumerState<DuplicateMergeSheet> createState() => _DuplicateMergeSheetState();
}

class _DuplicateMergeSheetState extends ConsumerState<DuplicateMergeSheet> {
  // A login whose password a space hides is no choice for the password, and its password goes into no other login
  late MergeChoices _choices = MergeChoices(
    widget.group.items,
    readOnlySlots: widget.readOnlySlots,
    hiddenPasswords: ref.read(hiddenPasswordsProvider).hiddenIds(widget.group.items.map((item) => item.item).whereType<Login>()),
  );
  var _busy = false;

  Future<void> _merge() async {
    setState(() => _busy = true);
    final done = await ref.read(vaultControllerProvider.notifier).mergeDuplicates(_choices);
    if (!mounted) {
      return;
    }
    if (done) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  Future<void> _notDuplicates() async {
    await ref.read(duplicatesProvider.notifier).dismiss(widget.group);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final choices = _choices;
    final settings = ref.watch(syncProvider.select((sync) => sync.settings));
    final logins = ref.watch(vaultControllerProvider.select((state) => state.logins));
    final locale = Localizations.localeOf(context).toLanguageTag();

    String place(DedupItem item) => spaceName(settings, item.spaceId) ?? context.t('duplicates.place.vault');
    String date(int ms) => DateFormat.MMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(ms));
    String meta(DedupItem item) => context.t('duplicates.item.meta', {'place': place(item), 'date': date(item.changedAt)});
    Widget kept() => StatusTag(label: context.t('duplicates.merge.kept'), tone: StatusTone.accent);

    final keptItem = choices.kept.item;
    final differing = choices.differing;
    final linked = keptItem is OtpAccount ? logins.where((login) => choices.removed.any((item) => item.id == login.accountId)).length : 0;
    final websites = keptItem is Login ? mergeRules([for (final item in choices.items) (item.item as Login).rules]) : const <WebsiteRule>[];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DialogHeading(icon: const Icon(Icons.merge_rounded), title: context.t('duplicates.merge.title')),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text(
                  '${context.t('duplicates.reason.${widget.group.reason.name}')}. ${context.t('duplicates.merge.body')}',
                  style: AppType.body2.copyWith(color: p.textSecondary),
                ),
                Group(
                  label: context.t('duplicates.merge.keep'),
                  children: [
                    for (final (i, item) in choices.items.indexed)
                      GroupRow(
                        key: ValueKey('keep-${item.id}'),
                        first: i == 0,
                        primary: duplicateName(item.item),
                        secondary: meta(item),
                        tag: item.id == choices.keptId ? kept() : null,
                        onTap: () => setState(() => _choices = choices.withKept(item.id)),
                      ),
                  ],
                ),
                if (choices.keptIsReadOnly)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('duplicates.merge.readOnly')))
                else if (choices.acrossPlaces)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('duplicates.merge.spaceCopy'))),
                for (final field in differing)
                  Group(
                    label: context.t('duplicates.field.${field.id}'),
                    children: [
                      for (final (i, item) in choices.items.indexed)
                        GroupRow(
                          key: ValueKey('pick-${field.id}-${item.id}'),
                          first: i == 0,
                          primary: duplicateFieldText(field.id, field.read(item.item)).ifEmpty(context.t('duplicates.merge.empty')),
                          secondary: meta(item),
                          tag: choices.pickFor(field).id == item.id ? kept() : null,
                          onTap: () => setState(() => _choices = choices.withPick(field, item.id)),
                        ),
                    ],
                  ),
                if (websites.isNotEmpty && !choices.keptIsReadOnly)
                  Group(
                    label: context.t('duplicates.merge.websites'),
                    children: [
                      for (final (i, rule) in websites.indexed)
                        GroupRow(
                          key: ValueKey('site-$i'),
                          first: i == 0,
                          primary: rule.uri,
                          secondary: rule.match == null ? null : context.t(_ruleLabel(rule.match)),
                        ),
                    ],
                  ),
                if (linked > 0)
                  Text(context.t('duplicates.merge.linked', {'count': linked}), style: AppType.body2.copyWith(color: p.textSecondary)),
                if (differing.any((field) => field.id == 'password'))
                  Text(context.t('duplicates.merge.history'), style: AppType.body2.copyWith(color: p.textSecondary)),
                Text(
                  // The name the kept item will have, so another pick changes what the summary says
                  context.t('duplicates.merge.summary', {
                    'name': duplicateName(choices.merged(ref.read(clockProvider)().millisecondsSinceEpoch)),
                    'count': choices.removed.length,
                  }),
                  style: AppType.body2.copyWith(color: p.text, fontWeight: FontWeight.w600),
                ),
                FilledButton(onPressed: _busy ? null : () => unawaited(_merge()), child: Text(context.t('duplicates.merge.confirm'))),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => unawaited(_notDuplicates()),
                      child: Text(context.t('duplicates.notDuplicates')),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: Text(context.t('duplicates.merge.cancel')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The message id naming a website's rule.
String _ruleLabel(int? match) => switch (match) {
  WebsiteMatch.baseDomain => 'websiteRules.rule.baseDomain',
  WebsiteMatch.host => 'websiteRules.rule.host',
  WebsiteMatch.startsWith => 'websiteRules.rule.startsWith',
  WebsiteMatch.exact => 'websiteRules.rule.exact',
  WebsiteMatch.regularExpression => 'websiteRules.rule.regularExpression',
  WebsiteMatch.never => 'websiteRules.rule.never',
  _ => 'websiteRules.rule.default',
};

extension on String {
  /// This text, or [other] when it is empty.
  String ifEmpty(String other) => isEmpty ? other : this;
}
