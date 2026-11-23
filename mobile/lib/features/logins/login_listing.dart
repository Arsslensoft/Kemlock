import 'package:intl/intl.dart' show DateFormat;

import '../../i18n/messages.dart';
import '../../models/login.dart';
import '../../ui/ui.dart' show StatusTone;
import '../vault/vault_items.dart';
import 'login_health.dart';

/// How long a login AutoFill saved is tagged New.
const newLoginDays = 3;

/// How the Vault tab lists [login] at [now]: one of its [warnings] first,
/// a breached password in the danger colour, else a reused or weak one in
/// the warning colour; else a login AutoFill saved is tagged New for
/// [newLoginDays] days, its line saying when it was saved; otherwise a login
/// whose code is linked (to one of [accountIds]) is tagged Code. Both in the
/// accent colour.
LoginListing loginListing(
  Messages messages,
  Login login, {
  required DateTime now,
  required Set<String> accountIds,
  required String locale,
  Set<LoginWarning> warnings = const {},
}) {
  final added = DateTime.fromMillisecondsSinceEpoch(login.addedAt);
  final autofilled = login.source == Login.fromAutofill && now.difference(added).inDays < newLoginDays;
  final line = autofilled ? messages.t('vault.login.savedByAutofill', {'date': DateFormat.MMMMd(locale).format(added)}) : null;
  for (final (warning, id, tone) in const [
    (LoginWarning.breached, 'vault.login.tag.breached', StatusTone.danger),
    (LoginWarning.reused, 'vault.login.tag.reused', StatusTone.warning),
    (LoginWarning.weak, 'vault.login.tag.weak', StatusTone.warning),
  ]) {
    if (warnings.contains(warning)) return LoginListing(tag: messages.t(id), tone: tone, line: line);
  }
  if (autofilled) return LoginListing(tag: messages.t('vault.login.tag.new'), tone: StatusTone.accent, line: line);
  if (login.accountId != null && accountIds.contains(login.accountId)) {
    return LoginListing(tag: messages.t('vault.login.tag.code'), tone: StatusTone.accent);
  }
  return const LoginListing();
}
