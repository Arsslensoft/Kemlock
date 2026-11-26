import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../i18n/messages.dart';
import '../../models/json.dart' show unset;
import '../../models/otp_account.dart';
import '../../models/website_rule.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../autofill/autofill_copy.dart';
import '../autofill/website_dialog.dart';
import '../autofill/website_hints.dart';
import '../backup/two_factor_directory.dart';
import 'websites_editor.dart';

/// The websites AutoFill suggests an account's code on (openspec:
/// account-websites): those Kemlock's 2FA directory gives the account, which
/// stay first and can't be changed or removed, then those the person added, each
/// with its rule and where it fills, a button for its rule, and Remove, and
/// "Add a website". Changes go out through [onUpdate], as the sheet's edits do.
class AccountWebsites extends ConsumerWidget {
  const AccountWebsites({super.key, required this.account, required this.onUpdate});

  final OtpAccount account;
  final ValueChanged<OtpAccount> onUpdate;

  /// Hands on the account with [rules] as its own websites.
  void _apply(List<WebsiteRule> rules) {
    final made = websitesOf(rules);
    onUpdate(account.copyWith(websites: made.websites ?? unset, uris: made.uris ?? unset));
  }

  Future<void> _add(BuildContext context, List<WebsiteRule> own, PublicSuffixList? suffixes) async {
    final rule = await showWebsiteRuleDialog(context, kind: WebsiteKind.account, suffixes: suffixes);
    if (rule == null || own.contains(rule)) return;
    _apply([...own, rule]);
  }

  Future<void> _edit(BuildContext context, List<WebsiteRule> own, WebsiteRule old, PublicSuffixList? suffixes) async {
    final rule = await showWebsiteRuleDialog(context, kind: WebsiteKind.account, rule: old, suffixes: suffixes);
    if (rule == null || rule == old) return;
    final changed = [for (final other in own) identical(other, old) ? rule : other];
    // A website changed into one the account already has leaves it once
    _apply([
      for (final (i, other) in changed.indexed)
        if (changed.indexOf(other) == i) other,
    ]);
  }

  void _remove(List<WebsiteRule> own, WebsiteRule rule) => _apply([...own]..remove(rule));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final b = context.bmc;
    final directory = ref.watch(twoFactorDirectoryProvider).value;
    final suffixes = ref.watch(publicSuffixListProvider).value;
    final own = account.rules;
    // What Kemlock found by itself, as people read hosts: without the mark for exact hosts
    final found = [
      for (final domain in autofillDomains(account.issuer, directory: directory, suffixes: suffixes))
        if (!own.any((rule) => rule.host == domain.replaceFirst('=', ''))) domain.replaceFirst('=', ''),
    ];
    final otherApps = otherAppsLines(context.t, own, WebsiteKind.account, suffixes: suffixes);
    final name = account.issuer.isNotEmpty ? account.issuer : account.label;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Group(
            label: context.t('accountWebsites.title'),
            children: [
              for (final (i, host) in found.indexed)
                GroupRow(
                  key: ValueKey('found:$host'),
                  first: i == 0,
                  icon: const Icon(Icons.public_rounded),
                  primary: host,
                  secondary: context.t('accountWebsites.found'),
                ),
              for (final (i, rule) in own.indexed)
                GroupRow(
                  key: ValueKey('own:${rule.uri}:${rule.match}'),
                  first: found.isEmpty && i == 0,
                  icon: const Icon(Icons.public_rounded),
                  primary: rule.uri,
                  secondary: websiteHint(context.t, rule, WebsiteKind.account, suffixes: suffixes),
                  control: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: context.t('websiteRules.edit.title'),
                        icon: const Icon(Icons.tune_rounded, size: 20),
                        onPressed: () => unawaited(_edit(context, own, rule, suffixes)),
                      ),
                      TextButton(
                        onPressed: () => _remove(own, rule),
                        style: TextButton.styleFrom(foregroundColor: p.error),
                        child: Text(context.t('accountWebsites.remove')),
                      ),
                    ],
                  ),
                ),
              GroupRow(
                first: found.isEmpty && own.isEmpty,
                accent: true,
                icon: const Icon(Icons.add_rounded),
                primary: context.t('accountWebsites.add'),
                onTap: () => unawaited(_add(context, own, suffixes)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Text(
              found.isEmpty ? context.t('accountWebsites.noneFound', {'name': name}) : context.t('accountWebsites.body'),
              style: AppType.caption.copyWith(color: b.faint),
            ),
          ),
          if (otherApps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    context.t('websiteRules.other.title'),
                    style: AppType.caption.copyWith(color: b.faint, fontWeight: FontWeight.w600),
                  ),
                  for (final line in otherApps) Text(line, style: AppType.caption.copyWith(color: b.faint)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
