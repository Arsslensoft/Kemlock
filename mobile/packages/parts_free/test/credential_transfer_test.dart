import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/kemlock_parts.dart' as parts;
import 'package:kemlock_ports/kemlock_ports.dart';

void main() {
  test('the free build offers no system transfer and throws NotInThisBuild when asked for one', () async {
    final transfer = parts.makeCredentialTransfer();

    expect(await transfer.isAvailable(), isFalse);
    await expectLater(transfer.importCredentials(const {'basic-auth'}), throwsA(isA<NotInThisBuild>()));
  });

  test('the free build lists no export source, receives no request and has none to answer', () async {
    final export = parts.makeCredentialExport();

    await export.registerExports(const [ExportVault(vaultId: 'main')], const {'basic-auth'});
    expect(await export.pendingExport(), isNull);
    expect(await export.exportRequests.isEmpty, isTrue);
    await export.refuseExport('any');
    await expectLater(export.answerExport('any', '{}'), throwsA(isA<NotInThisBuild>()));
  });
}
