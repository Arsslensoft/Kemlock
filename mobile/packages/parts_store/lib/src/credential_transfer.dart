import 'package:credential_transfer/credential_transfer.dart';
import 'package:flutter/services.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

/// The store build's credential transfer: Android's list of exporters, over Play services, through
/// the `credential_transfer` plugin (openspec: plan add-credential-exchange, design decision 8).
/// The plugin answers null when the person closes the list, and an error code for every other end;
/// this turns the codes into the port's problems.
class PlayCredentialTransfer implements CredentialTransfer {
  PlayCredentialTransfer({CredentialTransferPlugin? plugin}) : _plugin = plugin ?? CredentialTransferPlugin();

  final CredentialTransferPlugin _plugin;

  @override
  Future<bool> isAvailable() => _plugin.isAvailable();

  @override
  Future<String?> importCredentials(Set<String> types) async {
    try {
      return await _plugin.importCredentials(types);
    } on PlatformException catch (error) {
      throw CredentialTransferException(problemOf(error.code));
    }
  }

  /// What a plugin error [code] means. A code this version doesn't know is [CredentialTransferProblem.unknown].
  static CredentialTransferProblem problemOf(String code) => switch (code) {
    TransferErrorCodes.noExportOption => CredentialTransferProblem.noExportOption,
    TransferErrorCodes.unavailable => CredentialTransferProblem.unavailable,
    TransferErrorCodes.invalidJson => CredentialTransferProblem.invalidJson,
    TransferErrorCodes.system => CredentialTransferProblem.system,
    TransferErrorCodes.unknownCaller => CredentialTransferProblem.unknownCaller,
    _ => CredentialTransferProblem.unknown,
  };
}
