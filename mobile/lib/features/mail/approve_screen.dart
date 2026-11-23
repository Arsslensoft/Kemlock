/// "Let Thunderbird use your PGP keys?" (openspec: add-pgp-mail-provider,
/// decision 11): the app's name and package, the vault's PGP keys with a
/// tick each, the warning of an app known under another signature, the
/// warning of a hidden vault, Allow and Don't allow. Allowing writes the
/// approval, pinned to the app's certificate, with the ticked keys and
/// today's date; refusing writes nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../keys/key_standing.dart' show pgpKeyInfoProvider;
import '../pgp/pgp_people.dart' show groupedFingerprint, shortKeyId;
import '../pgp/pgp_widgets.dart' show pgpVaultKeys, vaultKeyTitle;
import 'mail_apps.dart';
import 'mail_caller.dart';
import 'request_screens.dart';

class MailApproveScreen extends ConsumerStatefulWidget {
  const MailApproveScreen({
    super.key,
    required this.caller,
    required this.otherCertificate,
    required this.onAllowed,
    required this.onDenied,
  });

  final MailCaller caller;

  /// An app of this package was allowed before, signed differently.
  final bool otherCertificate;

  /// The approval is written.
  final VoidCallback onAllowed;
  final VoidCallback onDenied;

  @override
  ConsumerState<MailApproveScreen> createState() => _MailApproveScreenState();
}

class _MailApproveScreenState extends ConsumerState<MailApproveScreen> {
  final _ticked = <String>{};
  var _saving = false;

  Future<void> _allow() async {
    if (_saving) return;
    setState(() => _saving = true);
    final keys = [
      for (final key in pgpVaultKeys(ref.read(vaultControllerProvider)))
        if (_ticked.contains(key.id)) key.id,
    ];
    final caller = widget.caller;
    await ref
        .read(mailAppsProvider.notifier)
        .put(
          MailApp(
            package: caller.package,
            cert: caller.cert,
            name: caller.name,
            allowedAt: ref.read(clockProvider)().millisecondsSinceEpoch,
            keys: keys,
          ),
        );
    if (mounted) widget.onAllowed();
  }

  @override
  Widget build(BuildContext context) {
    final caller = widget.caller;
    final state = ref.watch(vaultControllerProvider);
    final keys = pgpVaultKeys(state);
    final p = context.palette;
    return MailRequestPage(
      title: context.t('mail.approve.title', {'app': caller.name}),
      actions: [
        TextButton(onPressed: _saving ? null : widget.onDenied, child: Text(context.t('mail.approve.deny'))),
        FilledButton(onPressed: _saving ? null : _allow, child: Text(context.t('mail.approve.allow'))),
      ],
      children: [
        MailRequestText(context.t('mail.approve.body')),
        GroupCard(
          child: GroupRow(first: true, icon: Text(mailAppLetters(caller.name)), primary: caller.name, secondary: caller.package),
        ),
        if (widget.otherCertificate) ...[
          const SizedBox(height: 12),
          AppAlert(
            key: const ValueKey('mail-other-signature'),
            severity: AlertSeverity.error,
            child: Text(context.t('mail.approve.otherSignature')),
          ),
        ],
        if (state.vault.hidden) ...[
          const SizedBox(height: 12),
          AppAlert(
            key: const ValueKey('mail-hidden-vault'),
            severity: AlertSeverity.warning,
            child: Text(context.t('mail.approve.hidden', {'app': caller.name})),
          ),
        ],
        SectionLabel(context.t('mail.approve.keys')),
        if (keys.isEmpty)
          Text(context.t('mail.approve.noKeys'), style: AppType.body2.copyWith(color: p.textSecondary))
        else
          GroupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, key) in keys.indexed)
                  GroupRow(
                    key: ValueKey('approve-${key.id}'),
                    first: index == 0,
                    icon: const Text('PGP'),
                    primary: vaultKeyTitle(ref, key),
                    secondary: switch (ref.watch(pgpKeyInfoProvider(key.id))) {
                      final info? => info.userIds.firstOrNull ?? groupedFingerprint(shortKeyId(info.primary.fingerprintHex)),
                      null => null,
                    },
                    control: Semantics(
                      label: vaultKeyTitle(ref, key),
                      child: Checkbox(
                        value: _ticked.contains(key.id),
                        onChanged: (on) => setState(() => on == true ? _ticked.add(key.id) : _ticked.remove(key.id)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
