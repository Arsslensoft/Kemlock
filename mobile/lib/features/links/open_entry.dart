// Opens a linked item, whatever its kind, from the link that names it: the sheet of the kind, or for the kinds that have a page
// (a note, a backup-codes entry) that page. One place, so a new kind of item is opened from every sheet by adding it here.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/backup_service.dart';
import '../../models/contact.dart';
import '../../models/identity.dart';
import '../../models/key_account.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/passkey.dart';
import '../../models/payment_card.dart';
import '../../models/secure_note.dart';
import '../../models/vault_entry.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/account_sheet.dart';
import '../accounts/key_account_sheet.dart';
import '../cards/card_sheet.dart';
import '../contacts/contact_sheet.dart';
import '../identities/identity_sheet.dart';
import '../keys/key_sheet.dart';
import '../logins/login_sheet.dart';
import '../passkeys/passkey_sheet.dart';
import 'link_view.dart';

/// Opens [entry]: its sheet over the one this is called from, or its page after the sheets are closed.
Future<void> openLinkedEntry(BuildContext context, WidgetRef ref, VaultEntry<dynamic> entry) async {
  switch (entry) {
    case final Login login:
      await showLoginSheet(context, login);
    case final PaymentCard card:
      await showCardSheet(context, card);
    case final Identity identity:
      await showIdentitySheet(context, identity);
    case final Passkey passkey:
      await showPasskeySheet(context, passkey);
    case final VaultKey key:
      await showKeySheet(context, key);
    case final Contact contact:
      await showContactSheet(context, contact);
    case final KeyAccount account:
      await showKeyAccountSheet(context, account: account);
    case final OtpAccount account:
      final vault = ref.read(vaultControllerProvider.notifier);
      await showAccountSheet(
        context,
        account: account,
        onUpdate: (updated) => unawaited(vault.updateAccount(updated)),
        onDelete: (id) => unawaited(_confirmDeleteAccount(context, ref, id)),
      );
    case final SecureNote note:
      _goTo(context, '/vault/notes/${note.id}');
    case final BackupService service:
      _goTo(context, Uri(path: '/backup', queryParameters: {'open': service.id}).toString());
    default:
      // TODO(file-items): a File item opens its own sheet here (`case final VaultFile file: await showFileSheet(context, file)`).
      ref.read(toastsProvider.notifier).show(context.t('links.snack.cannotOpen'), severity: ToastSeverity.info);
  }
}

/// Goes to [location] with the sheets above the current page closed, as a tap in the Vault tab would.
void _goTo(BuildContext context, String location) {
  final router = GoRouter.of(context);
  Navigator.of(context, rootNavigator: true).popUntil((route) => route is! PopupRoute);
  router.go(location);
}

/// Asks, then removes the account [id]: the sheet that opened it already closed, as the Codes tab's own sheet does.
Future<void> _confirmDeleteAccount(BuildContext context, WidgetRef ref, String id) async {
  if (!context.mounted) {
    return;
  }
  final account = ref.read(vaultControllerProvider).accounts.where((a) => a.id == id).firstOrNull;
  if (account == null) {
    return;
  }
  final confirmed = await showConfirmDialog(
    context,
    icon: const Icon(Icons.delete_outline_rounded),
    title: context.t('app.deleteAccount.title'),
    body: Text(context.t('app.deleteAccount.body', {'name': entryName(account)})),
    cancelLabel: context.t('app.deleteAccount.cancel'),
    confirmLabel: context.t('app.deleteAccount.confirm'),
  );
  if (confirmed && context.mounted) {
    await ref.read(vaultControllerProvider.notifier).deleteAccount(account);
  }
}
