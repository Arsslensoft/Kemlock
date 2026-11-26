// What the Duplicates screen and the merge sheet show of a group, apart from
// how they draw it: the name of an item, the filters and which group each
// one keeps. Pure Dart, so the rules are tested without a widget.
library;

import '../../models/backup_service.dart';
import '../../models/contact.dart';
import '../../models/identity.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/passkey.dart';
import '../../models/payment_card.dart';
import '../../models/secure_note.dart';
import '../../models/vault_file.dart';
import '../../models/vault_key.dart';
import '../accounts/account_sheet.dart' show displayName;
import '../backup/backup_details_sheet.dart' show backupTitle;
import 'duplicate_matcher.dart';

/// What the Duplicates screen can be narrowed to.
enum DuplicateFilter {
  all,
  logins,
  codes,
  notes,

  /// Groups held in more than one place: the vault and a space, or two spaces.
  places,
}

/// Whether [group] shows under [filter].
bool filterMatches(DuplicateFilter filter, DuplicateGroup group) {
  final item = group.items.first.item;
  return switch (filter) {
    DuplicateFilter.all => true,
    DuplicateFilter.logins => item is Login,
    DuplicateFilter.codes => item is OtpAccount,
    DuplicateFilter.notes => item is SecureNote,
    DuplicateFilter.places => group.acrossPlaces,
  };
}

/// The groups of [groups] that show under [filter].
List<DuplicateGroup> filtered(DuplicateFilter filter, List<DuplicateGroup> groups) => [
  for (final group in groups)
    if (filterMatches(filter, group)) group,
];

/// What a person calls [item] in the list: its name, as the Codes tab and the Backup tab call a code and a backup-codes entry.
String duplicateName(Object item) => switch (item) {
  Login(:final name) => name,
  OtpAccount() => displayName(item),
  SecureNote(:final title) => title,
  BackupService() => backupTitle(item),
  Passkey() => item.displayName,
  VaultKey(:final name) => name,
  Contact(:final name) => name,
  PaymentCard(:final name) => name,
  Identity(:final name) => name,
  VaultFile(:final name) => name,
  _ => '',
};

/// The text a field of [item] is shown as in the merge sheet: a password is hidden, the rest as it is.
String duplicateFieldText(String fieldId, String? value) {
  if (value == null || value.isEmpty) {
    return '';
  }
  return fieldId == 'password' ? '•' * 8 : value;
}
