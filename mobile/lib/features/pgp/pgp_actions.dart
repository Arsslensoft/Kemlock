/// The four PGP actions of the Vault tab (openspec: add-pgp-messages,
/// `Main.dc.html`): Encrypt, Decrypt, Sign and Verify, a row of four equal
/// outlined buttons under the Keys filter and under an empty vault.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'decrypt_sheet.dart';
import 'encrypt_sheet.dart';
import 'sign_sheet.dart';
import 'verify_sheet.dart';

class PgpActionsRow extends StatelessWidget {
  const PgpActionsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final actions = <(String, Future<void> Function(BuildContext))>[
      ('pgp.action.encrypt', showEncryptSheet),
      ('pgp.action.decrypt', showDecryptSheet),
      ('pgp.action.sign', showSignSheet),
      ('pgp.action.verify', showVerifySheet),
    ];
    return Rise(
      delay: const Duration(milliseconds: 80),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Semantics(
          container: true,
          label: context.t('pgp.actions.label'),
          child: Row(
            children: [
              for (final (i, (id, open)) in actions.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: ValueKey(id),
                    style: smallButtonStyle.merge(
                      OutlinedButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: context.palette.text),
                    ),
                    onPressed: () => unawaited(open(context)),
                    // One line, shrunk to fit a narrow phone or a long word
                    child: FittedBox(fit: BoxFit.scaleDown, child: Text(context.t(id))),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
