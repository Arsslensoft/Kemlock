import 'package:credential_transfer/credential_transfer.dart';
import 'package:flutter/services.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

/// The store build's export to another app: Kemlock listed in Android's selector, and the requests
/// the exported activity passes on, through the `credential_transfer` plugin (openspec: plan
/// add-credential-exchange, task 8.4). The plugin's errors are codes only; this turns them into the
/// port's problems, and nothing here keeps or shows what is being sent.
class PlayCredentialExport implements CredentialExport {
  PlayCredentialExport({CredentialTransferPlugin? plugin}) : _plugin = plugin ?? CredentialTransferPlugin();

  final CredentialTransferPlugin _plugin;

  @override
  Future<void> registerExports(List<ExportVault> vaults, Set<String> types) async {
    try {
      await _plugin.registerExports([for (final vault in vaults) (vaultId: vault.vaultId, name: vault.name)], types);
    } on PlatformException catch (error) {
      throw CredentialExportException(problemOf(error.code));
    } on MissingPluginException {
      throw const CredentialExportException(CredentialExportProblem.unavailable);
    }
  }

  @override
  Future<void> clearExports() async {
    try {
      await _plugin.clearRegisteredExports();
    } on PlatformException catch (error) {
      throw CredentialExportException(problemOf(error.code));
    } on MissingPluginException {
      throw const CredentialExportException(CredentialExportProblem.unavailable);
    }
  }

  @override
  Future<ExportRequest?> pendingExport() async => _request(await _plugin.pendingExport());

  @override
  Stream<ExportRequest> get exportRequests => _plugin.exportRequests.map((info) => _request(info)!);

  @override
  Future<void> answerExport(String id, String json) async {
    try {
      await _plugin.answerExport(id, json);
    } on PlatformException catch (error) {
      throw CredentialExportException(problemOf(error.code));
    } on MissingPluginException {
      throw const CredentialExportException(CredentialExportProblem.unavailable);
    }
  }

  @override
  Future<void> refuseExport(String id) async {
    try {
      await _plugin.refuseExport(id);
    } on PlatformException {
      // Already gone, which is what a refusal wants
    } on MissingPluginException {
      // No plugin, no request
    }
  }

  static ExportRequest? _request(ExportRequestInfo? info) =>
      info == null ? null : ExportRequest(id: info.id, vaultId: info.vaultId, app: info.app, package: info.package, types: info.types);

  /// What a plugin error [code] means. A code this version doesn't know is [CredentialExportProblem.unknown].
  static CredentialExportProblem problemOf(String code) => switch (code) {
    TransferErrorCodes.registerFailed => CredentialExportProblem.registerFailed,
    TransferErrorCodes.gone => CredentialExportProblem.gone,
    TransferErrorCodes.unavailable => CredentialExportProblem.unavailable,
    _ => CredentialExportProblem.unknown,
  };
}
