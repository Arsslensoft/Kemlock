import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/now.dart';
import '../../core/public_suffixes.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/account_sheet.dart' show displayName;
import '../accounts/add_account_sheet.dart' show showAddAccountSheet;
import '../accounts/otp.dart';
import '../autofill/website_rule_fields.dart' show websiteRuleId;
import '../backup/coverage.dart';
import '../fields/custom_fields_view.dart';
import '../links/linked_items_section.dart';
import '../lock/gate_widgets.dart';
import '../lock/password_strength.dart';
import '../sends/new_send_sheet.dart';
import '../settings/prefs.dart';
import '../spaces/hidden_passwords.dart';
import '../vault/owner_check.dart';
import 'code_picker.dart';
import 'login_edit_sheet.dart';
import 'login_health.dart';
import 'login_sites.dart';

/// What a hidden password shows.
const _dots = '••••••••••';

/// Opens a login from the Vault tab.
Future<void> showLoginSheet(BuildContext context, Login login) => showAppBottomSheet<void>(
  context,
  label: login.name,
  builder: (_) => LoginSheet(loginId: login.id),
);

/// A login (openspec: logins; the approved mockup `Login`): its websites,
/// its username and password with Copy, the password hidden until shown, how
/// strong it is and when it changed; the code linked to it, counting down,
/// and its backup codes; the passwords it had before, each hidden, with
/// Show, Copy and Delete; where AutoFill offers it; Edit and Delete.
class LoginSheet extends ConsumerStatefulWidget {
  const LoginSheet({super.key, required this.loginId});

  final String loginId;

  @override
  ConsumerState<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends ConsumerState<LoginSheet> {
  var _shown = false;
  final _shownPrevious = <int>{};

  Future<void> _copy(String text, String messageId) async {
    if (await ref.read(secretClipboardProvider).copy(text) && mounted) {
      ref.read(toastsProvider.notifier).show(context.t(messageId));
    }
  }

  /// Whether a password may show: at once, unless Settings asks first who
  /// it is, as for an account's secret; then once the person has shown it
  /// is them. Copying it asks nothing.
  Future<bool> _mayReveal() async {
    if (!ref.read(prefsProvider).askBeforeSecret) return true;
    final reason = context.t('logins.reveal.confirm');
    return ref.read(ownerCheckProvider)(context, ref, reason);
  }

  /// Starts a text Send of [password], named after the login, once the owner has shown it is them: the password
  /// leaves the vault, so this asks whatever Settings says of a reveal. The Send is a copy, not linked to the login.
  Future<void> _sendPassword(Login login, String password) async {
    // A password the space hides is never sent, whichever way this was reached
    if (ref.read(hiddenPasswordsProvider).hides(login)) {
      return;
    }
    final reason = context.t('sends.fromItem.reason');
    if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) return;
    unawaited(showNewSendSheet(context, text: password, name: login.name));
  }

  Future<void> _toggleShown() async {
    if (!_shown && !await _mayReveal()) return;
    if (mounted) setState(() => _shown = !_shown);
  }

  Future<void> _togglePrevious(int i) async {
    if (!_shownPrevious.contains(i) && !await _mayReveal()) return;
    if (mounted) setState(() => _shownPrevious.contains(i) ? _shownPrevious.remove(i) : _shownPrevious.add(i));
  }

  Future<void> _deletePrevious(Login login, PreviousPassword previous) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('logins.previous.delete.title'),
      body: Text(context.t('logins.previous.delete.body')),
      confirmLabel: context.t('logins.previous.delete.confirm'),
      cancelLabel: context.t('logins.cancel'),
    );
    if (!confirmed || !mounted) return;
    setState(_shownPrevious.clear);
    await ref.read(vaultControllerProvider.notifier).deletePreviousPassword(login, previous);
  }

  Future<void> _delete(Login login) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('logins.delete.title'),
      body: Text(context.t('logins.delete.body', {'name': login.name})),
      confirmLabel: context.t('logins.delete.confirm'),
      cancelLabel: context.t('logins.cancel'),
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deleteLogin(login);
  }

  Future<void> _stopCodeWarning(Login login) => ref.read(vaultControllerProvider.notifier).updateLogin(login.copyWith(codeWarning: false));

  Future<void> _link(Login login) async {
    final picked = await showCodePicker(context);
    if (picked == null || picked.isEmpty) return;
    await ref.read(vaultControllerProvider.notifier).updateLogin(login.copyWith(accountId: picked));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final login = ref.watch(vaultControllerProvider.select((state) => state.logins.firstWhereOrNull((l) => l.id == widget.loginId)));
    if (login == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('logins.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final account = ref.watch(vaultControllerProvider.select((state) => state.accounts.firstWhereOrNull((a) => a.id == login.accountId)));
    final locale = Localizations.localeOf(context).toLanguageTag();
    String date(int ms) => DateFormat.MMMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(ms));
    final password = login.password;
    // A grant of "passwords hidden" in a server space: no Show and no Copy, and AutoFill still fills it
    final hidden = ref.watch(hiddenPasswordsProvider.select((spaces) => spaces.hides(login)));
    final domains = loginDomains(login, suffixes: ref.watch(publicSuffixListProvider).value);
    final mono = AppType.mono();
    final health = ref.watch(loginHealthProvider);
    final warnings = health.of(login.id);
    final names = {for (final other in ref.watch(vaultControllerProvider.select((state) => state.logins))) other.id: other.name};
    final sharing = [for (final id in health.reusedWith(login.id)) ?names[id]];

    Widget copyButton(String text, String messageId, String label) =>
        IconButton(tooltip: label, icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () => unawaited(_copy(text, messageId)));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.password_rounded), title: login.name),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Group(
                  children: [
                    for (final (i, website) in login.rules.indexed)
                      GroupRow(
                        first: i == 0,
                        icon: const Icon(Icons.public_rounded),
                        primary: context.t('logins.website'),
                        // A rule other than Default is named, so a website that fills nowhere says so
                        secondary: website.match == null ? null : context.t(websiteRuleId(website.match)),
                        value: Text(website.uri),
                      ),
                    if (login.username case final username?)
                      GroupRow(
                        first: login.rules.isEmpty,
                        icon: const Icon(Icons.person_outline_rounded),
                        primary: context.t('logins.username'),
                        secondary: username,
                        control: copyButton(username, 'logins.copied.username', context.t('logins.copy.username')),
                      ),
                    if (password != null)
                      GroupRow(
                        first: login.rules.isEmpty && login.username == null,
                        icon: const Icon(Icons.key_rounded),
                        primary: context.t('logins.password'),
                        secondary: _shown && !hidden ? password : _dots,
                        secondaryStyle: mono,
                        secondarySemanticsLabel: _shown && !hidden ? null : context.t('logins.hidden'),
                        control: hidden
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  RevealPasswordButton(shown: _shown, onPressed: () => unawaited(_toggleShown())),
                                  copyButton(password, 'logins.copied.password', context.t('logins.copy.password')),
                                  // A password the space hides offers no Send either, as it offers no copy
                                  IconButton(
                                    tooltip: context.t('sends.fromItem.login'),
                                    icon: const Icon(Icons.send_rounded, size: 20),
                                    onPressed: () => unawaited(_sendPassword(login, password)),
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
                if (password != null && hidden)
                  Padding(
                    key: const ValueKey('login-password-space-hidden'),
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                    child: Text(context.t('logins.password.spaceHidden'), style: AppType.caption.copyWith(color: b.faint)),
                  ),
                // How strong it is would tell what a hidden password is, so it stays out too
                if (password != null && !hidden)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                    child: Text(
                      login.passwordChangedAt == null
                          ? context.t(strengthIds[strengthLevel(password)])
                          : context.t('logins.strength.changed', {
                              'strength': context.t(strengthIds[strengthLevel(password)]),
                              'date': date(login.passwordChangedAt!),
                            }),
                      style: AppType.caption.copyWith(color: strengthColor(context, password)),
                    ),
                  ),
                // What password health says of it (openspec: add-passwords, the password-health spec)
                if (warnings.contains(LoginWarning.breached))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: AppAlert(severity: AlertSeverity.error, child: Text(context.t('health.login.breached'))),
                  ),
                if (warnings.contains(LoginWarning.reused))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: AppAlert(
                      severity: AlertSeverity.warning,
                      child: Text(context.t('health.login.reused', {'names': sharing.join(', ')})),
                    ),
                  ),
                if (password != null && warnings.contains(LoginWarning.weak))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: AppAlert(
                      severity: AlertSeverity.warning,
                      child: Text(context.t('health.login.weak', {'strength': context.t(strengthIds[strengthLevel(password)])})),
                    ),
                  ),
                const SizedBox(height: 8),
                SectionLabel(context.t('logins.twoStep')),
                if (account == null && warnings.contains(LoginWarning.noCode))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppAlert(
                      severity: AlertSeverity.info,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.t('health.login.noCode')),
                          Wrap(
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: () => unawaited(showAddAccountSheet(context)),
                                child: Text(context.t('health.login.addCode')),
                              ),
                              TextButton(
                                onPressed: () => unawaited(_stopCodeWarning(login)),
                                child: Text(context.t('health.login.noWarn')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (account != null)
                  _LinkedCode(account: account, onCopy: (code) => unawaited(_copy(code, 'logins.copied.code')))
                else
                  Group(
                    children: [
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.pin_outlined),
                        primary: context.t('logins.linkCode'),
                        secondary: context.t('logins.linkCode.body'),
                        onTap: () => unawaited(_link(login)),
                      ),
                    ],
                  ),
                if (login.previousPasswords case final previous? when previous.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionLabel(context.t('logins.previous')),
                  Group(
                    children: [
                      for (final (i, old) in previous.indexed)
                        GroupRow(
                          key: ValueKey('previous:$i'),
                          first: i == 0,
                          primary: context.t('logins.previous.until', {'date': date(old.until)}),
                          secondary: _shownPrevious.contains(i) && !hidden ? old.password : _dots,
                          secondaryStyle: mono,
                          secondarySemanticsLabel: _shownPrevious.contains(i) && !hidden ? null : context.t('logins.hidden'),
                          control: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!hidden) ...[
                                RevealPasswordButton(shown: _shownPrevious.contains(i), onPressed: () => unawaited(_togglePrevious(i))),
                                copyButton(old.password, 'logins.copied.password', context.t('logins.copy.password')),
                              ],
                              IconButton(
                                tooltip: context.t('logins.previous.delete'),
                                icon: Icon(Icons.delete_outline_rounded, size: 20, color: p.error),
                                onPressed: () => unawaited(_deletePrevious(login, old)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                  child: Text(
                    domains.isEmpty
                        ? context.t(login.rules.isEmpty ? 'logins.autofill.none' : 'websiteRules.phones.none')
                        : context.t('logins.autofill.on', {'domain': domains.first.replaceFirst('=', '')}),
                    style: AppType.caption.copyWith(color: b.faint),
                  ),
                ),
                CustomFieldsView(fields: login.fields, hideSecrets: hidden),
                LinkedItemsSection(entry: login),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: largeButtonStyle,
                  onPressed: () => unawaited(showLoginEditSheet(context, login: login)),
                  child: Text(context.t('logins.edit')),
                ),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t('logins.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(login)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The linked account's code, counting down, with Copy, and how many of its
/// service's backup codes are left, as the account sheet shows them.
class _LinkedCode extends ConsumerWidget {
  const _LinkedCode({required this.account, required this.onCopy});

  final OtpAccount account;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowSecondsProvider);
    final code = codeAt(account, now);
    final service = backupFor(account, ref.watch(vaultControllerProvider.select((state) => state.backupServices)));
    final left = service?.codes.where((code) => !code.used).length;
    return Group(
      children: [
        GroupRow(
          first: true,
          icon: isTimeBased(account)
              ? CountdownRing(remaining: remainingIn(now, account.period), period: account.period, size: 24, stroke: 2.5)
              : const Icon(Icons.pin_outlined),
          primary: formatCode(code),
          secondary: displayName(account),
          control: TextButton(onPressed: () => onCopy(code), child: Text(context.t('logins.copy'))),
        ),
        if (account.noBackupCodes != true)
          GroupRow(
            icon: const Icon(Icons.confirmation_number_outlined),
            primary: context.t('logins.backupCodes'),
            value: Text(
              left == null ? context.t('accountSheet.backupCodes.none') : context.t('accountSheet.backupCodes.left', {'count': left}),
            ),
          ),
      ],
    );
  }
}
