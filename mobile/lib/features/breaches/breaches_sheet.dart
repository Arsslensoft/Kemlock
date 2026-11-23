import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/links.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../backup/two_factor_directory.dart';
import 'breach_providers.dart';
import 'breach_scan.dart';
import 'breach_widgets.dart';

/// The services of the open vault that have a new breach (openspec: breach-alerts): for
/// each breach what is known of it, the accounts and backup-code lists it concerns, what
/// to do, and "Dealt with" for all of them at once. The Vault health card opens it.
Future<void> showBreachesSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('breaches.title'), builder: (_) => const _BreachesSheet());

class _BreachesSheet extends ConsumerWidget {
  const _BreachesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final alerts = ref.watch(breachFindingsProvider.select((findings) => findings.alerts));
    // The 2FA directory is only loaded when there is an alert to show it for
    final directory = alerts.isNotEmpty ? ref.watch(twoFactorDirectoryProvider).value : null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DialogHeading(icon: const Icon(Icons.gpp_maybe_outlined), title: context.t('breaches.title')),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text(context.t('breaches.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                if (alerts.isEmpty)
                  AppAlert(severity: AlertSeverity.success, child: Text(context.t('breaches.empty')))
                else
                  for (final alert in alerts)
                    _BreachCard(
                      key: ValueKey('breach-${alert.breach.name}'),
                      alert: alert,
                      twoFactorPage: directory?.findService(alert.breach.domain)?.docs,
                    ),
                const BreachCredit(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One new breach: its facts, the entries of the vault it concerns, and what to do.
class _BreachCard extends ConsumerWidget {
  const _BreachCard({super.key, required this.alert, this.twoFactorPage});

  final BreachAlert alert;

  /// The service's page for setting up 2FA, from the 2FA directory, if it has one.
  final String? twoFactorPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final breach = alert.breach;
    final entries = [
      for (final account in alert.accounts)
        account.label.isEmpty ? account.issuer : context.t('breaches.entry.account', {'issuer': account.issuer, 'label': account.label}),
      for (final service in alert.services) context.t('breaches.entry.codes', {'name': service.serviceName}),
    ];
    return GroupCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Semantics(
              header: true,
              child: Text(breach.title, style: AppType.h6.copyWith(color: p.text)),
            ),
            BreachFacts(breach),
            for (final entry in entries) Text(entry, style: AppType.body2.copyWith(color: p.text)),
            Text(context.t('breaches.advice'), style: AppType.body2.copyWith(color: p.textSecondary)),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => unawaited(
                    ref
                        .read(vaultControllerProvider.notifier)
                        .dismissBreach(
                          breach.name,
                          accountIds: [for (final account in alert.accounts) account.id],
                          serviceIds: [for (final service in alert.services) service.id],
                        ),
                  ),
                  child: Text(context.t('breaches.dealtWith')),
                ),
                if (twoFactorPage case final page?)
                  TextButton(
                    onPressed: () => unawaited(ref.read(linkOpenerProvider).open(context, Uri.parse(page))),
                    child: Text(context.t('breaches.twoFactorPage')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
