import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/duplicates/duplicate_view.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/otp_account.dart';

// What the duplicates list calls a code and a backup-codes entry: what the Codes and Backup tabs call them
void main() {
  OtpAccount code({String? name}) =>
      OtpAccount(id: 'c1', name: name, issuer: 'GitHub', label: 'octocat', secret: 'JBSWY3DPEHPK3PXP', addedAt: 0);

  test('a code is called by its name, else its issuer', () {
    expect(duplicateName(code(name: 'Work GitHub')), 'Work GitHub');
    expect(duplicateName(code()), 'GitHub');
  });

  test('a backup-codes entry is called by its name, else its service', () {
    expect(duplicateName(const BackupService(id: 'b1', serviceName: 'GitHub', name: 'Work GitHub', codes: [], addedAt: 0)), 'Work GitHub');
    expect(duplicateName(const BackupService(id: 'b2', serviceName: 'GitHub', codes: [], addedAt: 0)), 'GitHub');
  });
}
