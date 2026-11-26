// How an item of any kind shows in the links: its name, its icon, the words for its kind, and what the picker searches.

import 'package:flutter/material.dart';
import 'package:kemlock_core/models/vault_file.dart';

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
import '../accounts/account_sheet.dart' show displayName;
import '../sync/kemlock/km_kinds.dart' show itemKindOf;
import '../vault/vault_items.dart' show VaultItemKind;

/// What an entry is called, which is empty for one with no name at all.
String entryName(VaultEntry<dynamic> entry) => switch (entry) {
  final Login login => login.name,
  final OtpAccount account => displayName(account),
  final BackupService service => service.serviceName,
  final SecureNote note => note.title,
  final PaymentCard card => card.name,
  final Identity identity => identity.name,
  final Contact contact => contact.name,
  final VaultKey key => key.name,
  final Passkey passkey => passkey.displayName,
  final KeyAccount account => account.displayName,
  final VaultFile file => file.name,
  _ => '',
};

/// The icon of an entry's kind: the one the Vault tab uses where it lists the kind.
IconData entryIcon(VaultEntry<dynamic> entry) => switch (entry) {
  Login() => VaultItemKind.login.icon,
  OtpAccount() => Icons.timer_outlined,
  BackupService() => Icons.format_list_numbered_rounded,
  SecureNote() => VaultItemKind.note.icon,
  PaymentCard() => VaultItemKind.card.icon,
  Identity() => VaultItemKind.identity.icon,
  Contact() => VaultItemKind.contact.icon,
  VaultKey() => VaultItemKind.key.icon,
  Passkey() => VaultItemKind.passkey.icon,
  KeyAccount() => Icons.usb_rounded,
  VaultFile() => Icons.insert_drive_file_outlined,
  _ => Icons.link_rounded,
};

/// The id of the words for an entry's kind ("Login", "MFA code", "PGP key"…), from the kind name the vault stores it as.
String entryKindLabelId(VaultEntry<dynamic> entry) => 'links.kind.${itemKindOf(entry)}';

/// What the picker's search reads of an entry besides its name: the lines the Vault tab finds an item by. Never a secret.
List<String> entrySearchText(VaultEntry<dynamic> entry) => [
  entryName(entry),
  ...switch (entry) {
    final Login login => [?login.username, ...?login.websites],
    final OtpAccount account => [account.issuer, account.label],
    final PaymentCard card => [?card.cardholder, ?card.brand],
    final Identity identity => [?identity.fullName, ?identity.email, ?identity.company],
    final Passkey passkey => [passkey.rpId, passkey.userName],
    final KeyAccount account => [account.issuer, account.label],
    _ => const <String>[],
  },
];
