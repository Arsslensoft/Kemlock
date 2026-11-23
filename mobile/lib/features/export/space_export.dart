/// What a file export of the vault leaves out of its spaces (docs/plans/add-server-spaces.md, task 7.4: "A space's items are
/// left out of every export when the space forbids exporting them"). The encrypted and plain exports, and the QR codes of
/// the vault's codes, put the open vault's items in a file the space can't take back, so the policy applies to them as it
/// does to the Credential Exchange export (`credential_export.dart`).
///
/// An item of a space leaves out when
///
/// - the space's **verified chain** forbids export (`SpacePolicies.noExport`), and the export says which space, or
/// - it is a **server space whose policy isn't known**: no chain was read since the vault opened, and none was ever read and
///   compared on this account, so the item stays out and never goes (the same fail-closed rule the Credential Exchange export
///   has), and the export says how many.
///
/// A space's policy is known from the chain read since the vault opened, or, when none was (offline, the server down, just
/// after unlock), from what its last compared chain said, which the vault remembers (`rememberedExportPoliciesProvider`). A
/// chain read since the vault opened always decides over what is remembered, in either direction.
///
/// The items of WebDAV spaces, which have no rules, and the vault's own go as before. A server space's items come back from
/// the server with the next sync, so a file without them loses nothing the member can't have again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backup_service.dart';
import '../../models/identity.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/passkey.dart';
import '../../models/payment_card.dart';
import '../../models/secure_note.dart';
import '../../models/vault_key.dart';
import '../../vault/vault_controller.dart';
import '../spaces/remembered_export_policies.dart';
import '../spaces/space_policies_provider.dart';
import '../spaces/space_scope.dart' show serverSpaceUuidOrNull;
import '../sync/sync_store.dart';
import 'credential_export.dart' show serverSpaceItemProvider;

/// Which spaces' items a file export leaves out.
class SpaceExportRule {
  const SpaceExportRule({required this.blocked, required this.known, required this.isServerSpace, this.nameOf});

  /// The spaces whose verified chain forbids exporting their items.
  final Set<String> blocked;

  /// The spaces whose chain this phone read and verified, so whose policy is known.
  final Set<String> known;

  /// Whether a space id is a server space: not one the vault's own settings list as a WebDAV space.
  final bool Function(String spaceId) isServerSpace;

  /// The name to show for a space, when it has one.
  final String? Function(String spaceId)? nameOf;

  static bool _in(String? spaceId) => spaceId != null && spaceId.isNotEmpty;

  /// Whether [ids] holds the space: under its own id, or under the UUID its server space has, which is how a WebDAV space that
  /// moved to Kemlock Server keeps its chain (the phone still knows it by its WebDAV id).
  static bool _has(Set<String> ids, String spaceId) => ids.contains(spaceId) || ids.contains(serverSpaceUuidOrNull(spaceId));

  /// Whether the space's policy forbids exporting its items.
  bool forbids(String? spaceId) => _in(spaceId) && _has(blocked, spaceId!);

  /// Whether the space is a server space whose policy isn't known, so its items stay out.
  bool unknown(String? spaceId) => _in(spaceId) && !_has(blocked, spaceId!) && isServerSpace(spaceId) && !_has(known, spaceId);
}

/// What the file exports may hold of the open vault, and what was left out of its spaces. The vault's contacts and its
/// accounts kept on a security key are its own, never in a space, so they aren't listed here.
class ExportableVault {
  ExportableVault._({
    required this.accounts,
    required this.backupServices,
    required this.notes,
    required this.passkeys,
    required this.keys,
    required this.logins,
    required this.cards,
    required this.identities,
    required this.blocked,
    required this.unknown,
  });

  /// [vault] less what [rule] leaves out. With [codesOnly], as for the QR codes, which carry the codes and backup
  /// services alone, the other kinds are left out whole and uncounted, so what the sheet says is left out is only codes.
  factory ExportableVault.of(VaultState vault, SpaceExportRule rule, {bool codesOnly = false}) {
    final blocked = <String, int>{};
    var unknown = 0;
    List<T> keep<T>(List<T> items, String? Function(T item) spaceOf) {
      final kept = <T>[];
      for (final item in items) {
        final space = spaceOf(item);
        if (rule.forbids(space)) {
          final name = rule.nameOf?.call(space!) ?? space!;
          blocked[name] = (blocked[name] ?? 0) + 1;
        } else if (rule.unknown(space)) {
          unknown++;
        } else {
          kept.add(item);
        }
      }
      return kept;
    }

    return ExportableVault._(
      accounts: keep<OtpAccount>(vault.accounts, (item) => item.spaceId),
      backupServices: keep<BackupService>(vault.backupServices, (item) => item.spaceId),
      notes: codesOnly ? const [] : keep<SecureNote>(vault.notes, (item) => item.spaceId),
      passkeys: codesOnly ? const [] : keep<Passkey>(vault.passkeys, (item) => item.spaceId),
      keys: codesOnly ? const [] : keep<VaultKey>(vault.keys, (item) => item.spaceId),
      logins: codesOnly ? const [] : keep<Login>(vault.logins, (item) => item.spaceId),
      cards: codesOnly ? const [] : keep<PaymentCard>(vault.cards, (item) => item.spaceId),
      identities: codesOnly ? const [] : keep<Identity>(vault.identities, (item) => item.spaceId),
      blocked: blocked,
      unknown: unknown,
    );
  }

  final List<OtpAccount> accounts;
  final List<BackupService> backupServices;
  final List<SecureNote> notes;
  final List<Passkey> passkeys;
  final List<VaultKey> keys;
  final List<Login> logins;
  final List<PaymentCard> cards;
  final List<Identity> identities;

  /// How many items of each space whose policy forbids export were left out, by the space's name.
  final Map<String, int> blocked;

  /// How many items of server spaces whose policy isn't known were left out.
  final int unknown;
}

/// The rule the file exports follow: the verified chains' no-export policy, the last compared chain's remembered one for a
/// space no chain was read for since the vault opened, and a server space whose policy isn't known failing closed.
final spaceExportRuleProvider = Provider<SpaceExportRule>((ref) {
  final policies = ref.watch(spacePoliciesProvider);
  final remembered = ref.watch(rememberedExportPoliciesProvider);
  final settings = ref.watch(syncProvider.select((sync) => sync.settings));
  // A chain read since the vault opened decides for its space, and a remembered policy speaks only for the others
  final fresh = policies.known;
  return SpaceExportRule(
    blocked: {
      ...policies.noExport,
      for (final MapEntry(:key, :value) in remembered.entries)
        if (value.disableExport && !fresh.contains(key)) key,
    },
    known: {...fresh, ...remembered.keys},
    isServerSpace: ref.watch(serverSpaceItemProvider),
    nameOf: (id) => spaceName(settings, id) ?? policies.nameOf(id),
  );
});
