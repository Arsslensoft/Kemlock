import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/otp_account.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/account_sheet.dart' show displayName;
import 'login_edit_sheet.dart';
import 'login_sheet.dart';

/// The login an account's code belongs to, on the account's sheet
/// (openspec: logins): the linked login, which opens, or a row that adds a
/// login with this code already linked and the account's name.
class AccountLogin extends ConsumerWidget {
  const AccountLogin({super.key, required this.account});

  final OtpAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final login = ref.watch(vaultControllerProvider.select((state) => state.logins.firstWhereOrNull((l) => l.accountId == account.id)));
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Group(
        children: [
          GroupRow(
            first: true,
            icon: const Icon(Icons.password_rounded),
            primary: context.t('accountLogin.title'),
            secondary: login == null ? context.t('accountLogin.link') : [login.name, ?login.username].join(' · '),
            onTap: () => unawaited(
              login == null
                  ? showLoginEditSheet(context, accountId: account.id, name: displayName(account))
                  : showLoginSheet(context, login),
            ),
          ),
        ],
      ),
    );
  }
}
