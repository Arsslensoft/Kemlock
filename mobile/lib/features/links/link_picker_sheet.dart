// "Link an item": a sheet that searches the vault's items, the person's own and those of the spaces they can write to, and gives
// back the one they pick (the web vault's picker). The caller links it: a link writes both items.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/vault_entry.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../spaces/hidden_passwords.dart';
import 'link_account.dart';
import 'link_candidates.dart';
import 'link_view.dart';

/// Most rows the picker lists at once; more are reached by typing.
const linkPickerLimit = 100;

/// Asks which item [entry] is to be linked to: the item, or null when the sheet is dismissed.
Future<VaultEntry<dynamic>?> showLinkPicker(BuildContext context, {required VaultEntry<dynamic> entry}) =>
    showAppBottomSheet<VaultEntry<dynamic>>(
      context,
      label: context.t('links.picker.title'),
      builder: (_) => LinkPicker(entry: entry),
    );

/// The content of the sheet [showLinkPicker] opens.
class LinkPicker extends ConsumerStatefulWidget {
  const LinkPicker({super.key, required this.entry});

  final VaultEntry<dynamic> entry;

  @override
  ConsumerState<LinkPicker> createState() => _LinkPickerState();
}

class _LinkPickerState extends ConsumerState<LinkPicker> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final lists = ref.watch(vaultControllerProvider).lists;
    final access = ref.watch(hiddenPasswordsProvider);
    final found = linkCandidates(
      lists,
      widget.entry,
      query: _query.text,
      canEdit: access.canEdit,
      account: ref.watch(linkAccountProvider),
    );
    final shown = found.take(linkPickerLimit).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.add_link_rounded), title: context.t('links.picker.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SearchField(
            controller: _query,
            label: context.t('links.picker.searchLabel'),
            hint: context.t('links.picker.search'),
            clearLabel: context.t('accounts.clearSearch'),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 6),
                    child: Text(
                      context.t(_query.text.trim().isEmpty ? 'links.picker.none' : 'links.picker.noMatch'),
                      key: const ValueKey('link-picker-empty'),
                      textAlign: TextAlign.center,
                      style: AppType.body2.copyWith(color: b.faint),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Group(
                        children: [
                          for (final (i, candidate) in shown.indexed)
                            GroupRow(
                              key: ValueKey('link-pick:${candidate.runtimeType}:${candidate.id}'),
                              first: i == 0,
                              icon: Icon(entryIcon(candidate)),
                              primary: entryName(candidate).isEmpty ? context.t('links.unnamed') : entryName(candidate),
                              secondary: context.t(entryKindLabelId(candidate)),
                              onTap: () => Navigator.of(context).pop(candidate),
                            ),
                        ],
                      ),
                      if (found.length > shown.length)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                          child: Text(context.t('links.picker.more'), style: AppType.caption.copyWith(color: b.faint)),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
