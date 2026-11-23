import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/account_sheet.dart' show displayName;
import '../accounts/service_tile.dart';

/// Asks which of the vault's accounts holds a login's code, [selected] ticked:
/// its id, '' for no code, or null when the sheet is dismissed.
Future<String?> showCodePicker(BuildContext context, {String? selected}) => showAppBottomSheet<String>(
  context,
  label: context.t('logins.code.pick.title'),
  builder: (_) => _CodePicker(selected: selected),
);

class _CodePicker extends ConsumerWidget {
  const _CodePicker({this.selected});

  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = context.bmc;
    final accounts = ref
        .watch(vaultControllerProvider.select((state) => state.accounts))
        .sortedBy((account) => displayName(account).toLowerCase());
    final tick = Icon(Icons.check_rounded, color: b.accentText);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.pin_outlined), title: context.t('logins.code.pick.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Group(
              children: [
                GroupRow(
                  first: true,
                  icon: const Icon(Icons.block_rounded),
                  primary: context.t('logins.code.pick.none'),
                  tag: selected == null ? tick : null,
                  onTap: () => Navigator.of(context).pop(''),
                ),
                for (final account in accounts)
                  GroupRow(
                    key: ValueKey('code:${account.id}'),
                    icon: ServiceTile(name: displayName(account), size: 28),
                    primary: displayName(account),
                    secondary: account.issuer.isNotEmpty && account.label.isNotEmpty ? account.label : null,
                    tag: selected == account.id ? tick : null,
                    onTap: () => Navigator.of(context).pop(account.id),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
