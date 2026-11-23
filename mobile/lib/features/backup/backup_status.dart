import '../../models/backup_service.dart';
import '../../models/otp_account.dart';

/// Unbacked entries it takes before the Codes tab suggests a backup.
const nudgeAt = 3;

/// How many accounts and backup-code services were added after [since] (epoch ms),
/// i.e. are missing from the last backup. Everything counts when [since] is null.
int entriesSince(Iterable<OtpAccount> accounts, Iterable<BackupService> services, int? since) {
  bool after(int addedAt) => since == null || addedAt > since;
  return accounts.where((a) => after(a.addedAt)).length + services.where((s) => after(s.addedAt)).length;
}
