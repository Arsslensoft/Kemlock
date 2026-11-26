/// Sending the vault's items to another app on the phone as Credential Exchange (openspec: plan
/// add-credential-exchange, tasks group 8, design decision 11): what the person can pick, what
/// would be left out and why, and where the JSON goes. The sheet that asks
/// (`credential_export_sheet.dart`) shows all of it before anything is read.
///
/// Export is built but switched off. [credentialExportEnabledProvider] is false until the
/// security review of task 8.6 passes, and while it is false no row, no registration and no
/// request is answered anywhere in the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/identity.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/passkey.dart';
import '../../models/payment_card.dart';
import '../../models/secure_note.dart';
import '../../models/vault_file.dart';
import '../../models/vault_key.dart';
import '../../platform/credential_exchange.dart';
import '../../vault/vault_controller.dart';
import '../import/formats/cxf_writer.dart';
import '../spaces/space_bridge.dart' show plainWebDavSpaceIds;
import '../spaces/space_policies_provider.dart';
import '../spaces/space_scope.dart' show serverSpaceUuidOrNull;
import '../sync/sync.dart' show Space;
import '../sync/sync_store.dart';

/// The build-time switch. It stays off until task 8.6's review passes; a release that turns export
/// on builds with `--dart-define=KEMLOCK_CREDENTIAL_EXPORT=true`. The Android component's `credential_export_enabled`
/// resource is made from that same define by the plugin's build.gradle.kts, so the two can't differ.
const bool credentialExportBuilt = bool.fromEnvironment('KEMLOCK_CREDENTIAL_EXPORT');

/// Whether export is on. Tests turn it on to see the sheet.
final credentialExportEnabledProvider = Provider<bool>((ref) => credentialExportBuilt);

/// The ids of the spaces whose rules forbid exporting their items (add-server-spaces, task 7.4): the
/// spaces whose verified chain has the no-export policy on (`SpacePolicies.noExport`). WebDAV spaces
/// have no rules. Whatever it names is left out of every export, and the sheet says which space, by
/// name. The other shared server spaces' items [serverSpaceItemProvider] leaves out whole.
final blockedExportSpacesProvider = Provider<Set<String>>((ref) => ref.watch(spacePoliciesProvider).noExport);

/// Whether an item with the space id it is given belongs to a shared server space, and so stays out of every
/// Credential Exchange export, whatever its policy says. The owner's decision, kept when add-server-spaces 7.4 gave
/// export a policy: a space that forbids export is named by [blockedExportSpacesProvider], and the rest of a server
/// space's items still don't leave for another app. Personal items (no space id) and the items
/// of a WebDAV space, which the vault's sync settings list and which have no rules, go as before. Any other id
/// is a server space's, including one the settings can't be read for (a locked vault, settings still loading),
/// so a gap in what is known leaves an item out and never sends it.
///
/// A WebDAV space that moved keeps its WebDAV id on the phone (`plainWebDavSpaceIds` leaves it out), so its items are a server
/// space's here. When the export policy reads the space's chain, it looks it up under `serverSpaceUuid(spaceId)`, which is how
/// a moved space's chain is reported, so a moved space's items stay out while the chain forbids export.
final serverSpaceItemProvider = Provider<bool Function(String spaceId)>((ref) {
  final settings = ref.watch(syncProvider.select((sync) => sync.settings));
  final webDav = plainWebDavSpaceIds(settings?.spaces ?? const <Space>[]);
  return (spaceId) => spaceId.isNotEmpty && !webDav.contains(spaceId);
});

/// The kinds of item the person picks among. Backup codes, contacts, File items and security-key accounts have
/// no Credential Exchange type and are never offered (they are listed as left out).
enum ExportKind {
  logins('basic-auth'),
  codes('totp'),
  passkeys('passkey'),
  notes('note'),
  cards('credit-card'),
  identities('person-name'),
  keys('ssh-key');

  const ExportKind(this.main);

  /// The Credential Exchange credential type this kind is made of: what an importer must have asked for to be
  /// offered the kind. An identity's is its `person-name`; its address and documents ride along only if they were
  /// asked for as well ([writeCxf]'s `asked`).
  final String main;

  /// Whether a request for [asked] types wants this kind: it asked for the kind's [main] type. A null request wants
  /// anything. Asking for a type the kind only also contains, such as `totp`, which a login carries, is not asking for
  /// the kind.
  bool askedFor(Set<String>? asked) => asked == null || asked.contains(main);
}

/// What the vault holds that has no Credential Exchange type, by how it is told to the person.
enum ExportNotCarried { backupServices, contacts, onKey, files }

/// What an export of the open vault could hold, and what it could not.
class CredentialExportPlan {
  const CredentialExportPlan._({
    required this.all,
    required this.counts,
    required this.blocked,
    required this.serverSpaceItems,
    required this.notCarried,
  });

  /// Every item that may leave: the vault's, less what a space forbids.
  final CxfExportItems all;

  /// How many items of each kind may leave.
  final Map<ExportKind, int> counts;

  /// The name of each space whose rules forbid export, with how many of its items were left out.
  final Map<String, int> blocked;

  /// How many items of shared server spaces were left out, whatever their kind.
  final int serverSpaceItems;

  /// What no Credential Exchange type carries, by kind, with its count.
  final Map<ExportNotCarried, int> notCarried;

  /// [all] cut to the [kinds] picked.
  CxfExportItems pick(Set<ExportKind> kinds) => CxfExportItems(
    logins: kinds.contains(ExportKind.logins) ? all.logins : const [],
    codes: kinds.contains(ExportKind.codes) ? all.codes : const [],
    passkeys: kinds.contains(ExportKind.passkeys) ? all.passkeys : const [],
    notes: kinds.contains(ExportKind.notes) ? all.notes : const [],
    cards: kinds.contains(ExportKind.cards) ? all.cards : const [],
    identities: kinds.contains(ExportKind.identities) ? all.identities : const [],
    keys: kinds.contains(ExportKind.keys) ? all.keys : const [],
  );

  /// How many items of [kind] the writer would write: all of them, less the codes, passkeys and keys it leaves out.
  int sendable(ExportKind kind) {
    final count = counts[kind] ?? 0;
    return switch (kind) {
      ExportKind.codes => count - cxfLeftOut(CxfExportItems(codes: all.codes)).length,
      ExportKind.passkeys => count - cxfLeftOut(CxfExportItems(passkeys: all.passkeys)).length,
      ExportKind.keys => count - cxfLeftOut(CxfExportItems(keys: all.keys)).length,
      _ => count,
    };
  }

  /// How many items go for [kinds].
  int sending(Set<ExportKind> kinds) => kinds.fold(0, (sum, kind) => sum + sendable(kind));

  /// What the writer would leave out of [kinds], by reason, with each count.
  Map<CxfLeftOutReason, int> leftOut(Set<ExportKind> kinds) {
    final counts = <CxfLeftOutReason, int>{};
    for (final item in cxfLeftOut(pick(kinds))) {
      counts[item.reason] = (counts[item.reason] ?? 0) + 1;
    }
    return counts;
  }
}

/// Plans an export of [vault]. An item for which [inServerSpace] says it is in a shared server space stays out, and
/// the plan counts it ([CredentialExportPlan.serverSpaceItems]); the function has no default, so a caller can't forget
/// it. An item of a space in [blockedSpaces] stays out, and the plan counts it under the space's name ([spaceName]). A
/// login for which [hidesPassword] says a space hides its password from the member stays out too, uncounted. This
/// reads each item's kind and space, never a secret.
CredentialExportPlan planCredentialExport(
  VaultState vault, {
  required bool Function(String spaceId) inServerSpace,
  Set<String> blockedSpaces = const {},
  String? Function(String spaceId)? spaceName,
  bool Function(Login login)? hidesPassword,
}) {
  final blocked = <String, int>{};
  var serverSpaceItems = 0;
  List<T> allowed<T>(List<T> items, String? Function(T item) spaceOf) {
    final kept = <T>[];
    for (final item in items) {
      final space = spaceOf(item);
      // A space that forbids export comes first, so the sheet names it; the rest of a server space's items are counted
      // A moved WebDAV space keeps its WebDAV id here, and its chain is reported under its server UUID, so both are looked up
      if (space != null && (blockedSpaces.contains(space) || blockedSpaces.contains(serverSpaceUuidOrNull(space)))) {
        final name = spaceName?.call(space) ?? space;
        blocked[name] = (blocked[name] ?? 0) + 1;
      } else if (space != null && inServerSpace(space)) {
        serverSpaceItems++;
      } else {
        kept.add(item);
      }
    }
    return kept;
  }

  final all = CxfExportItems(
    // A login whose password a space hides from the member never leaves, or the other app would hold the password. The
    // space checks come first, so a server space's login, hidden until its chain reports, is still counted as left out
    logins: [
      for (final login in allowed<Login>(vault.logins, (item) => item.spaceId))
        if (!(hidesPassword?.call(login) ?? false)) login,
    ],
    codes: allowed<OtpAccount>(vault.accounts, (item) => item.spaceId),
    passkeys: allowed<Passkey>(vault.passkeys, (item) => item.spaceId),
    notes: allowed<SecureNote>(vault.notes, (item) => item.spaceId),
    cards: allowed<PaymentCard>(vault.cards, (item) => item.spaceId),
    identities: allowed<Identity>(vault.identities, (item) => item.spaceId),
    keys: allowed<VaultKey>(vault.keys, (item) => item.spaceId),
  );
  return CredentialExportPlan._(
    all: all,
    counts: {
      ExportKind.logins: all.logins.length,
      ExportKind.codes: all.codes.length,
      ExportKind.passkeys: all.passkeys.length,
      ExportKind.notes: all.notes.length,
      ExportKind.cards: all.cards.length,
      ExportKind.identities: all.identities.length,
      ExportKind.keys: all.keys.length,
    },
    blocked: blocked,
    serverSpaceItems: serverSpaceItems,
    notCarried: {
      ExportNotCarried.backupServices: vault.backupServices.length,
      ExportNotCarried.contacts: vault.contacts.length,
      ExportNotCarried.onKey: vault.keyAccounts.length,
      ExportNotCarried.files: allowed<VaultFile>(vault.files, (item) => item.spaceId).length,
    },
  );
}

/// The person closed the system's list of apps without choosing one, or the other app gave up.
class CredentialExportCancelled implements Exception {
  const CredentialExportCancelled();

  @override
  String toString() => 'CredentialExportCancelled';
}

/// The hand-off failed. It carries nothing of what was sent.
class CredentialExportFailed implements Exception {
  const CredentialExportFailed();

  @override
  String toString() => 'CredentialExportFailed';
}

/// Where an export's JSON goes, and who asked for it.
abstract interface class CredentialExportTarget {
  /// The receiving app, when it is known before anything is sent (an Android request names it); null on
  /// iOS, where the person picks it in the system's sheet after Kemlock has handed over.
  String? get appName;

  /// The receiving app's package name, shown under its name because a label proves nothing; null when the app is
  /// not known before anything is sent (iOS).
  String? get appPackage;

  /// The credential types the receiving app asked for; null when it asked for any.
  Set<String>? get askedTypes;

  /// The vault the receiving app was sent to, when it named one; null for any.
  String? get vaultId;

  /// Hands CXF JSON to the receiving app, made by [json] when the target is ready for it: at once on Android, and on
  /// iOS only after the system's sheet has been gone on, so that the plaintext doesn't wait in memory while the person
  /// chooses. [json] is called at most once and not at all if the person closes the sheet; what it throws ends the send.
  /// Throws [CredentialExportCancelled] or [CredentialExportFailed]. The string is dropped at once after.
  Future<void> send(Future<String> Function() json);

  /// Tells the receiving app nothing is coming. Safe to call more than once, and after [send].
  Future<void> cancel();
}

/// iOS 26: the system asks which app, and takes the JSON (`ASCredentialExportManager`).
class IosExportTarget implements CredentialExportTarget {
  const IosExportTarget(this._exchange);

  final IosCredentialExchange _exchange;

  @override
  String? get appName => null;

  @override
  String? get appPackage => null;

  @override
  Set<String>? get askedTypes => null;

  @override
  String? get vaultId => null;

  @override
  Future<void> send(Future<String> Function() json) async {
    try {
      await _exchange.export(json);
    } on IosExportCancelled {
      throw const CredentialExportCancelled();
    } on IosExchangeFailed {
      throw const CredentialExportFailed();
    }
  }

  @override
  Future<void> cancel() async {}
}

/// Which row the export sheet shows for sending to another app.
enum ExportRow {
  /// Nothing: export is off, or this phone can't take part.
  none,

  /// iOS 26 and later: a button that opens the system's sheet of apps.
  iosStart,

  /// Android, store build: the transfer starts in the other app.
  androidSteps,
}

/// Which row applies: none while the switch is off.
final exportRowProvider = FutureProvider<ExportRow>((ref) async {
  if (!ref.watch(credentialExportEnabledProvider)) {
    return ExportRow.none;
  }
  if (await ref.read(iosCredentialExchangeProvider).supported()) {
    return ExportRow.iosStart;
  }
  return await ref.read(credentialTransferProvider).isAvailable() ? ExportRow.androidSteps : ExportRow.none;
});
