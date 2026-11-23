// Password health on the Vault tab's Logins filter (openspec: add-passwords,
// the password-health spec): a row counting each kind of warning while any
// login has one, and the sheet it opens, the logins grouped by warning.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/login.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../settings/prefs.dart';
import 'login_health.dart';
import 'login_sheet.dart';

const _countIds = {
  LoginWarning.reused: 'health.count.reused',
  LoginWarning.weak: 'health.count.weak',
  LoginWarning.noCode: 'health.count.noCode',
  LoginWarning.breached: 'health.count.breached',
};

const _sectionIds = {
  LoginWarning.breached: 'health.section.breached',
  LoginWarning.reused: 'health.section.reused',
  LoginWarning.weak: 'health.section.weak',
  LoginWarning.noCode: 'health.section.noCode',
};

/// "2 reused · 1 weak · 1 without its code": each kind of warning some login has, counted.
String healthSummary(BuildContext context, LoginHealth health) => [
  for (final MapEntry(key: warning, value: id) in _countIds.entries)
    if (health.count(warning) case final count when count > 0) context.t(id, {'count': count}),
].join(' · ');

/// The Password health row above the logins, while any login has a warning.
class PasswordHealthRow extends ConsumerWidget {
  const PasswordHealthRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(loginHealthProvider);
    if (health.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Group(
        key: const ValueKey('password-health'),
        children: [
          GroupRow(
            first: true,
            icon: const Icon(Icons.health_and_safety_outlined),
            primary: context.t('health.title'),
            secondary: healthSummary(context, health),
            onTap: () => unawaited(showPasswordHealthSheet(context)),
          ),
        ],
      ),
    );
  }
}

/// Opens the logins grouped by warning.
Future<void> showPasswordHealthSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('health.title'), builder: (_) => const PasswordHealthSheet());

/// The logins with a warning, a section for each kind, each opening its
/// login; and whether breached passwords are checked.
class PasswordHealthSheet extends ConsumerWidget {
  const PasswordHealthSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = context.bmc;
    final health = ref.watch(loginHealthProvider);
    final logins = {for (final login in ref.watch(vaultControllerProvider.select((state) => state.logins))) login.id: login};
    final checking = ref.watch(prefsProvider.select((prefs) => prefs.leakCheck));
    final offline = ref.watch(offlineProvider);

    Widget section(LoginWarning warning) {
      final shown = [for (final id in health.idsWith(warning)) ?logins[id]];
      if (shown.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(context.t(_sectionIds[warning]!)),
          Group(
            children: [
              for (final (i, login) in shown.indexed)
                GroupRow(
                  key: ValueKey('health:${warning.name}:${login.id}'),
                  first: i == 0,
                  primary: login.name,
                  secondary: login.username,
                  onTap: () => unawaited(_open(context, login)),
                ),
            ],
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.health_and_safety_outlined), title: context.t('health.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                if (health.isEmpty) Text(context.t('health.none'), style: AppType.body1.copyWith(color: context.palette.textSecondary)),
                for (final warning in _sectionIds.keys) section(warning),
                if (!checking)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('health.breach.off')))
                else if (offline)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('health.breach.offline'))),
                Text(context.t('health.note'), style: AppType.caption.copyWith(color: b.faint)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static Future<void> _open(BuildContext context, Login login) => showLoginSheet(context, login);
}
