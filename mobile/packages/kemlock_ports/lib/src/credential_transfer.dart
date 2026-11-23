/// What a build can do about the system's Credential Exchange hand-off from another app on this
/// phone (openspec: plan add-credential-exchange, design decision 8). Only the store build, on
/// Android, can start one: it goes through Play services, which the free build leaves out. On iOS
/// the other app starts the transfer, so nothing in this port is asked there.
library;

/// Why a transfer gave nothing, in the kinds the Import sheet has a message for. Closing the list
/// is not one of them: that is a null answer.
enum CredentialTransferProblem {
  /// No app on the phone can export what Kemlock reads, or the one picked refused.
  noExportOption,

  /// The phone can't do it: Android before 8, or no Google Play services, or too old a version.
  unavailable,

  /// The other app's answer wasn't valid.
  invalidJson,

  /// Android's own failure while the data moved.
  system,

  /// The system couldn't tell which app exported.
  unknownCaller,

  /// Anything else.
  unknown,
}

/// A transfer that failed. It names the kind and nothing the other app sent.
class CredentialTransferException implements Exception {
  const CredentialTransferException(this.problem);

  final CredentialTransferProblem problem;

  @override
  String toString() => 'CredentialTransferException: ${problem.name}';
}

/// The system's list of apps that can export to Kemlock.
abstract interface class CredentialTransfer {
  /// Whether this build, on this phone, can start a transfer: the store build on Android 8 and
  /// later. False elsewhere, so that no row is offered for it.
  Future<bool> isAvailable();

  /// Opens the system's list of apps that hold any of the Credential Exchange credential [types]
  /// (`basic-auth`, `passkey` and so on) and returns the CXF JSON of the one the person picked;
  /// null when they closed the list. Throws a [CredentialTransferException], or `NotInThisBuild`
  /// where the build has no transfer.
  Future<String?> importCredentials(Set<String> types);
}

/// Why an export call failed. None carries anything of what was being sent.
enum CredentialExportProblem {
  /// The system refused to list Kemlock as an exporter, or Google Play services isn't there.
  registerFailed,

  /// The request being answered is closed, replaced, or gone with the process.
  gone,

  /// The phone or build can't do it.
  unavailable,

  /// Anything else.
  unknown,
}

/// An export call that failed.
class CredentialExportException implements Exception {
  const CredentialExportException(this.problem);

  final CredentialExportProblem problem;

  @override
  String toString() => 'CredentialExportException: ${problem.name}';
}

/// A vault Kemlock offers as an export source in other apps' imports.
class ExportVault {
  const ExportVault({required this.vaultId, this.name});

  final String vaultId;

  /// The name to show it by; null for none.
  final String? name;
}

/// Another app's request for an export, which passed the checks that the system started it and that
/// the person picked Kemlock, and waits for the vault to open.
class ExportRequest {
  const ExportRequest({required this.id, required this.vaultId, required this.app, required this.package, required this.types});

  /// Made for this request; the answer carries it.
  final String id;

  /// The vault the person picked Kemlock's entry for.
  final String vaultId;

  /// The importer's name as the phone shows it.
  final String app;

  /// The importer's package name, which is the system's word for who it is: the name above is its own label,
  /// which another app can pick to look like any other.
  final String package;

  /// The credential types it asked for.
  final Set<String> types;

  @override
  String toString() => 'ExportRequest($app)';
}

/// The export half of the system's transfer: Kemlock as a source other apps import from. Only the
/// store build, on Android, has it, and only while export is switched on (plan add-credential-exchange,
/// tasks 8.4 and 8.6); the free build has none and these do nothing there.
abstract interface class CredentialExport {
  /// Lists each of [vaults] as an export source in other apps' imports, naming the credential [types]
  /// Kemlock writes and nothing of what a vault holds; replaces every entry listed before, and an empty
  /// list takes Kemlock out of the lists. Throws a [CredentialExportException].
  Future<void> registerExports(List<ExportVault> vaults, Set<String> types);

  /// Takes Kemlock out of other apps' lists if any entry of it is registered, and does nothing if none is: what a
  /// build with export switched off asks once, so that a release that had export on and is switched back off is
  /// no longer offered. Throws a [CredentialExportException].
  Future<void> clearExports();

  /// The request that arrived before Dart was up, or null.
  Future<ExportRequest?> pendingExport();

  /// Requests that arrive while the app runs.
  Stream<ExportRequest> get exportRequests;

  /// Gives the CXF [json] to the importer of request [id]. Throws a [CredentialExportException].
  Future<void> answerExport(String id, String json);

  /// Tells the importer of request [id] that nothing is coming.
  Future<void> refuseExport(String id);
}
