import 'package:kemlock_ports/kemlock_ports.dart';

/// The free build's export to another app, which is none: Credential Manager's transfer runs on Google
/// Play services, and this build holds none of its classes (openspec: plan add-credential-exchange,
/// design decision 11). Registering does nothing, nothing ever arrives, and an answer has no request.
class NoCredentialExport implements CredentialExport {
  const NoCredentialExport();

  @override
  Future<void> registerExports(List<ExportVault> vaults, Set<String> types) async {}

  @override
  Future<void> clearExports() async {}

  @override
  Future<ExportRequest?> pendingExport() async => null;

  @override
  Stream<ExportRequest> get exportRequests => const Stream.empty();

  @override
  Future<void> answerExport(String id, String json) async => throw const NotInThisBuild();

  @override
  Future<void> refuseExport(String id) async {}
}
