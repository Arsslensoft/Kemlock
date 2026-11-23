import 'package:kemlock_ports/kemlock_ports.dart';

/// The free build's credential transfer, which is none (openspec: plan add-credential-exchange,
/// design decision 8): the system's list of exporters runs on Google Play services, and this
/// build holds none of its classes. A Credential Exchange file still opens like any other export.
class NoCredentialTransfer implements CredentialTransfer {
  const NoCredentialTransfer();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String?> importCredentials(Set<String> types) async => throw const NotInThisBuild();
}
