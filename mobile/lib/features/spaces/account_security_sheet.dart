// Settings, Account security (docs/plans/add-server-spaces.md, task 1.1): the
// account's own fingerprint, to read out or scan when someone in a space
// confirms the account. It is computed here from the public keys this phone
// holds, never taken from the server, and it is the same digits on every
// device of the account and in the web vault.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/account/bundle.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';
import '../sync/sync_store.dart';
import 'fingerprint_view.dart';

/// Shows the account's fingerprint.
Future<void> showAccountSecurity(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('accountSecurity.title'), builder: (context) => const AccountSecuritySheet());

/// The sheet. [load] gives the account's public keys; by default the open vault's Kemlock Server account.
class AccountSecuritySheet extends ConsumerStatefulWidget {
  const AccountSecuritySheet({super.key, this.load});

  final Future<KeyBundle?> Function()? load;

  @override
  ConsumerState<AccountSecuritySheet> createState() => _AccountSecuritySheetState();
}

class _AccountSecuritySheetState extends ConsumerState<AccountSecuritySheet> {
  KeyBundle? _bundle;
  var _loaded = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final load = widget.load;
      final bundle = load != null ? await load() : await ref.read(kemlockHostProvider)?.ownBundle();
      if (mounted) {
        setState(() {
          _bundle = bundle;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loaded = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    return SyncSheetFrame(
      icon: const Icon(Icons.fingerprint_rounded),
      title: context.t('accountSecurity.title'),
      actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.close')))],
      children: [
        SheetText(context.t('accountSecurity.body')),
        if (!_loaded) const LinearProgressIndicator(),
        if (_failed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('accountSecurity.failed'))),
        if (_loaded && !_failed && bundle == null)
          AppAlert(severity: AlertSeverity.info, child: Text(context.t('accountSecurity.missing'))),
        if (bundle != null) ...[
          FingerprintView(fingerprint: bundle.fingerprint),
          SheetText(context.t('accountSecurity.version', {'version': bundle.keyVersion})),
        ],
      ],
    );
  }
}
