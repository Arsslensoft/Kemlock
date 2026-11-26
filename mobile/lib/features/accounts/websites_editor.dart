import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../i18n/messages.dart';
import '../../models/backup_service.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/vault_entry.dart';
import '../../models/website_rule.dart';
import '../../ui/ui.dart';
import '../../vault/item_links.dart';
import '../autofill/website_rule_fields.dart';
import '../sync/sync_merge.dart' show Lists;

/// The websites typed in a form, one row each, as a login's are (`WebsiteRuleFields`), but with none to start with. A row left empty
/// is dropped, and the rows make [rules] in order and each once.
class WebsitesDraft extends ChangeNotifier {
  WebsitesDraft([Iterable<WebsiteRule> rules = const []]) : rows = [for (final rule in rules) WebsiteRuleController(rule)] {
    rows.forEach(_watch);
  }

  final List<WebsiteRuleController> rows;

  /// The row added last, which takes the focus.
  WebsiteRuleController? fresh;

  void _watch(WebsiteRuleController row) => row.addListener(notifyListeners);

  /// The websites typed, with their rules, in order and each once.
  List<WebsiteRule> get rules => websiteRulesOf(rows);

  /// Whether every row is empty or makes a website.
  bool get isValid => rows.every((row) => row.isValid);

  void add() {
    final row = WebsiteRuleController();
    _watch(row);
    rows.add(row);
    fresh = row;
    notifyListeners();
  }

  void remove(WebsiteRuleController row) {
    rows.remove(row);
    notifyListeners();
    // Disposed once the row has left the tree, which still listens to it until then
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  @override
  void dispose() {
    for (final row in rows) {
      row.dispose();
    }
    super.dispose();
  }
}

/// The websites a code is used on, to type in a form: a row for each, Add a website, and nothing else.
class WebsitesEditor extends ConsumerWidget {
  const WebsitesEditor({super.key, required this.draft});

  final WebsitesDraft draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suffixes = ref.watch(publicSuffixListProvider).value;
    final b = context.bmc;
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 14,
        children: [
          for (final row in draft.rows)
            WebsiteRuleFields(
              key: ObjectKey(row),
              controller: row,
              kind: WebsiteKind.account,
              label: context.t('accounts.websites.field'),
              suffixes: suffixes,
              autofocus: identical(row, draft.fresh),
              onRemove: () => draft.remove(row),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: draft.add,
              child: Text(context.t(draft.rows.isEmpty ? 'accounts.websites.add' : 'accounts.websites.addMore')),
            ),
          ),
          Text(context.t('accounts.websites.hint'), style: AppType.caption.copyWith(color: b.faint)),
        ],
      ),
    );
  }
}

/// The websites of the first item that [entry] is linked to and that has some, which the code shows as its own and doesn't write:
/// empty when it is linked to none or to items with no websites. A link we can't resolve has none.
List<WebsiteRule> inheritedWebsites(Lists lists, VaultEntry<Object?> entry) {
  for (final linked in linkedItemsOf(lists, entry)) {
    final rules = switch (linked.entry) {
      Login(:final rules) => rules,
      OtpAccount(:final rules) => rules,
      BackupService(:final rules) => rules,
      _ => const <WebsiteRule>[],
    };
    if (rules.isNotEmpty) return rules;
  }
  return const [];
}

/// A code's websites when it is linked to an item that has websites: those of that item, read-only, with a line saying where they come
/// from.
class InheritedWebsites extends StatelessWidget {
  const InheritedWebsites({super.key, required this.rules});

  final List<WebsiteRule> rules;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Group(
          key: const ValueKey('inherited-websites'),
          label: context.t('accountWebsites.title'),
          children: [
            for (final (i, rule) in rules.indexed)
              GroupRow(key: ValueKey('linked:${rule.uri}'), first: i == 0, icon: const Icon(Icons.public_rounded), primary: rule.uri),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(context.t('accounts.websites.fromLink'), style: AppType.caption.copyWith(color: b.faint)),
        ),
      ],
    );
  }
}
