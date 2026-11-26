import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../cards/card_edit_sheet.dart';
import '../contacts/add_contact_sheet.dart';
import '../contacts/add_person_sheet.dart';
import '../files/new_file.dart';
import '../identities/identity_edit_sheet.dart';
import '../keys/generate_key_sheet.dart';
import '../keys/import_key_sheet.dart';
import '../logins/login_edit_sheet.dart';
import 'vault_items.dart';

/// "Add to vault", which the tab bar's Add button opens on the Vault tab:
/// one row per thing the vault can take.
Future<void> showAddToVaultSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('vault.add.title'), builder: (_) => const AddToVaultSheet());

/// The sheet [showAddToVaultSheet] opens. Each row closes it and opens what it adds.
class AddToVaultSheet extends StatelessWidget {
  const AddToVaultSheet({super.key});

  @override
  Widget build(BuildContext context) {
    // The page the sheet was opened from, which stays once the sheet closes
    final router = GoRouter.of(context);
    void then(void Function() open) {
      Navigator.of(context).pop();
      open();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.inventory_2_outlined), title: context.t('vault.add.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Group(
            children: [
              GroupRow(
                first: true,
                icon: Icon(VaultItemKind.login.icon),
                primary: context.t('vault.add.login'),
                secondary: context.t('vault.add.login.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showLoginEditSheet(root)));
                },
              ),
              GroupRow(
                icon: Icon(VaultItemKind.card.icon),
                primary: context.t('vault.add.card'),
                secondary: context.t('vault.add.card.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showCardEditSheet(root)));
                },
              ),
              GroupRow(
                icon: Icon(VaultItemKind.identity.icon),
                primary: context.t('vault.add.identity'),
                secondary: context.t('vault.add.identity.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showIdentityEditSheet(root)));
                },
              ),
              GroupRow(
                icon: const Icon(Icons.auto_awesome_rounded),
                primary: context.t('vault.add.generateKey'),
                secondary: context.t('vault.add.generateKey.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showGenerateKeySheet(root)));
                },
              ),
              GroupRow(
                icon: const Icon(Icons.file_open_outlined),
                primary: context.t('vault.add.importKey'),
                secondary: context.t('vault.add.importKey.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showImportKeySheet(root)));
                },
              ),
              GroupRow(
                icon: const Icon(Icons.person_add_alt_1_outlined),
                primary: context.t('vault.add.contact'),
                secondary: context.t('vault.add.contact.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showAddContactSheet(root)));
                },
              ),
              GroupRow(
                icon: const Icon(Icons.person_outline_rounded),
                primary: context.t('contacts.person.add'),
                secondary: context.t('contacts.person.add.menuBody'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showAddPersonSheet(root)));
                },
              ),
              GroupRow(
                icon: Icon(VaultItemKind.note.icon),
                primary: context.t('vault.add.note'),
                secondary: context.t('vault.add.note.body'),
                onTap: () => then(() => router.go('/vault/notes/new')),
              ),
              GroupRow(
                icon: Icon(VaultItemKind.file.icon),
                primary: context.t('files.add'),
                secondary: context.t('files.add.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(addFileItem(root)));
                },
              ),
              GroupRow(
                icon: Icon(VaultItemKind.passkey.icon),
                primary: context.t('vault.add.passkey'),
                secondary: context.t('vault.add.passkey.body'),
                onTap: () {
                  final root = Navigator.of(context, rootNavigator: true).context;
                  then(() => unawaited(showPasskeyHelpSheet(root)));
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// How passkeys get into the vault: a site or an app makes one, which the
/// phone saves to Kemlock once passkeys are on, or a Bitwarden export
/// brings them. Nothing here makes one.
Future<void> showPasskeyHelpSheet(BuildContext context) => showAppBottomSheet<void>(
  context,
  label: context.t('passkeys.how.title'),
  builder: (sheet) {
    final p = sheet.palette;
    Widget step(IconData icon, String id) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: p.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(sheet.t(id), style: AppType.body2.copyWith(color: p.text)),
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: Icon(VaultItemKind.passkey.icon), title: sheet.t('passkeys.how.title')),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              step(Icons.add_moderator_outlined, 'passkeys.how.create'),
              step(Icons.login_rounded, 'passkeys.how.signIn'),
              step(Icons.file_upload_outlined, 'passkeys.how.import'),
              const SizedBox(height: 4),
              FilledButton(style: largeButtonStyle, onPressed: () => Navigator.of(sheet).pop(), child: Text(sheet.t('passkeys.how.done'))),
            ],
          ),
        ),
      ],
    );
  },
);
