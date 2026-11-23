import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/backup_status.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';

OtpAccount account(int addedAt) => OtpAccount(id: '$addedAt', issuer: 'A', label: '', secret: 'S', addedAt: addedAt);

BackupService service(int addedAt) => BackupService(id: '$addedAt', serviceName: 'S', codes: const [], addedAt: addedAt);

void main() {
  group('entriesSince', () {
    test('counts every account and service when there has never been a backup', () {
      expect(entriesSince([account(1), account(2)], [service(3)], null), 3);
    });

    test('counts only what was added after the backup', () {
      expect(entriesSince([account(100), account(300)], [service(200), service(400)], 250), 2);
    });

    test('treats something added at the very moment of the backup as backed up', () {
      expect(entriesSince([account(250)], [], 250), 0);
    });
  });
}
