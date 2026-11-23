import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../i18n/messages.dart';
import '../../models/otp_account.dart';
import '../../platform/links.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'breach_list.dart';
import 'breach_providers.dart';
import 'hibp.dart';

/// "Breach data from Have I Been Pwned", opening haveibeenpwned.com in the browser. The
/// data's licence (CC BY 4.0) asks for the source to be named, with a link, wherever the
/// data shows, so every place that shows a breach ends with this.
class BreachCredit extends ConsumerWidget {
  const BreachCredit({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = context.bmc;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        link: true,
        child: InkWell(
          onTap: () => unawaited(ref.read(linkOpenerProvider).open(context, Uri.parse(hibpSite))),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Flexible(
                  child: Text(
                    context.t('breaches.credit'),
                    style: AppType.caption.copyWith(color: b.faint, decoration: TextDecoration.underline, decorationColor: b.faint),
                  ),
                ),
                ExcludeSemantics(child: Icon(Icons.open_in_new_rounded, size: 13, color: b.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What is known of a breach, in the order every place shows it: when it happened, how
/// many accounts it held and the breached domain, then whether passwords were taken.
class BreachFacts extends StatelessWidget {
  const BreachFacts(this.breach, {super.key, this.color});

  final Breach breach;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final style = AppType.body2.copyWith(color: color ?? context.palette.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t('breaches.facts', {
            'date': DateFormat.yMMMd(locale).format(breach.happened),
            'count': breach.pwnCount,
            'domain': breach.domain,
          }),
          style: style,
        ),
        if (breach.passwords) Text(context.t('breaches.passwords'), style: style.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// The breaches of an account's service, on its sheet: a notice for each new one, with
/// what to do and "Dealt with", then the earlier ones as plain lines, then the credit.
/// Nothing at all for a service with no breach.
class AccountBreaches extends ConsumerWidget {
  const AccountBreaches({super.key, required this.account});

  final OtpAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(breachFindingsProvider.select((findings) => findings.of(account.id)));
    if (found.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    final b = context.bmc;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          for (final breach in found.fresh)
            AppAlert(
              key: ValueKey('breach-${breach.name}'),
              severity: AlertSeverity.warning,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    context.t('breaches.alert.title', {'name': breach.title}),
                    style: AppType.body2.copyWith(color: p.text, fontWeight: FontWeight.w600),
                  ),
                  BreachFacts(breach, color: p.text),
                  Text(context.t('breaches.advice'), style: AppType.body2.copyWith(color: p.text)),
                  TextButton(
                    onPressed: () =>
                        unawaited(ref.read(vaultControllerProvider.notifier).dismissBreach(breach.name, accountIds: [account.id])),
                    child: Text(context.t('breaches.dealtWith')),
                  ),
                ],
              ),
            ),
          if (found.earlier.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t('breaches.earlier'),
                  style: AppType.caption.copyWith(color: b.faint, fontWeight: FontWeight.w600),
                ),
                for (final breach in found.earlier)
                  Text(
                    context.t('breaches.earlier.item', {'name': breach.title, 'year': '${breach.year}'}),
                    style: AppType.body2.copyWith(color: p.textSecondary),
                  ),
              ],
            ),
          const BreachCredit(),
        ],
      ),
    );
  }
}
