/// The Settings group "Mail apps that use your PGP keys" (openspec:
/// add-pgp-mail-provider, decision 11; Settings.dc.html): a row per mail
/// app the open vault approved, with its two letters, its name, the key it
/// uses or how many and the day it was allowed, and Remove; a row saying
/// how to add one when there is none; and the note under the card. On
/// Android only, where mail apps can ask; on iPhone the group is absent.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../contacts/contact_widgets.dart' show contactDate;
import '../pgp/pgp_widgets.dart' show vaultKeyTitle;
import 'mail_apps.dart';
import 'request_screens.dart' show mailAppLetters;

class MailAppsGroup extends ConsumerWidget {
  const MailAppsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform != TargetPlatform.android) return const SizedBox.shrink();
    final apps = ref.watch(mailAppsProvider);
    final keys = ref.watch(vaultControllerProvider.select((state) => state.keys));
    final p = context.palette;
    String usesLine(MailApp app) {
      final allowed = [for (final id in app.keys) ?keys.where((key) => key.id == id).firstOrNull];
      // "2 November", as the contact screens write a date
      final date = contactDate(context, DateTime.fromMillisecondsSinceEpoch(app.allowedAt), year: false);
      return allowed.length == 1
          ? context.t('settings.mailApps.uses', {'key': vaultKeyTitle(ref, allowed.single), 'date': date})
          : context.t('settings.mailApps.usesKeys', {'count': allowed.length, 'date': date});
    }

    Future<void> remove(MailApp app) async {
      final removed = context.t('settings.mailApps.removed', {'app': app.name});
      await ref.read(mailAppsProvider.notifier).remove(app.package);
      ref.read(toastsProvider.notifier).show(removed);
    }

    return Rise(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Group(
            label: context.t('settings.section.mailApps'),
            children: [
              if (apps.isEmpty)
                GroupRow(
                  first: true,
                  icon: const Icon(Icons.mail_outline_rounded),
                  primary: context.t('settings.mailApps.none'),
                  secondary: context.t('settings.mailApps.none.hint'),
                ),
              for (final (index, app) in apps.indexed)
                GroupRow(
                  key: ValueKey('mail-app-${app.package}'),
                  first: index == 0,
                  icon: Text(mailAppLetters(app.name)),
                  primary: app.name,
                  secondary: usesLine(app),
                  control: Semantics(
                    label: context.t('settings.mailApps.removeApp', {'app': app.name}),
                    excludeSemantics: true,
                    button: true,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: p.error,
                        textStyle: AppType.body2.copyWith(fontWeight: FontWeight.w600),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      ),
                      onPressed: () => unawaited(remove(app)),
                      child: Text(context.t('settings.mailApps.remove')),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Text(context.t('settings.mailApps.note'), style: AppType.caption.copyWith(color: p.textSecondary)),
          ),
        ],
      ),
    );
  }
}
