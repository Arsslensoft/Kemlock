import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell_page.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../cards/card_sheet.dart';
import '../contacts/contact_keys.dart';
import '../contacts/contact_sheet.dart';
import '../contacts/contact_standing.dart';
import '../contacts/contact_widgets.dart';
import '../files/file_sheet.dart';
import '../files/file_size.dart';
import '../identities/identity_sheet.dart';
import '../keys/key_bridge.dart';
import '../keys/key_reminders.dart';
import '../keys/key_sheet.dart';
import '../keys/key_standing.dart';
import '../keys/key_widgets.dart';
import '../keys/ssh_fingerprint.dart';
import '../keys/verify_sheet.dart';
import '../logins/login_health.dart';
import '../logins/login_listing.dart';
import '../logins/login_sheet.dart';
import '../logins/password_health.dart';
import '../passkeys/passkey_sheet.dart';
import '../pgp/pgp_actions.dart';
import '../settings/prefs.dart';
import 'add_to_vault_sheet.dart';
import 'vault_items.dart';

/// The Vault tab: the vault's keys, notes and passkeys, searched by what
/// they hold and filtered by kind, pinned ones first. A PGP key that is
/// expiring soon, expired or revoked carries a tag saying so, and under the
/// Keys filter the PGP keys sit in a group of their own. Each opens where
/// it is edited; Add opens "Add to vault". The first time the vault holds a
/// PGP key that will expire, a card offers to warn before it does, once. The
/// Keys filter ends with "Verify an SSH signature", whatever keys the vault
/// holds. Other people's public keys are listed under All and Keys in a
/// section of their own, after the vault's own items, each with its initials
/// and whether its fingerprint was checked.
class VaultPage extends ConsumerStatefulWidget {
  const VaultPage({super.key});

  @override
  ConsumerState<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends ConsumerState<VaultPage> {
  final _query = TextEditingController();
  var _filter = VaultFilter.all;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(VaultListItem item) {
    switch (item.kind) {
      case VaultItemKind.login:
        final login = ref.read(vaultControllerProvider).logins.where((l) => l.id == item.id).firstOrNull;
        if (login != null) unawaited(showLoginSheet(context, login));
      case VaultItemKind.card:
        final card = ref.read(vaultControllerProvider).cards.where((c) => c.id == item.id).firstOrNull;
        if (card != null) unawaited(showCardSheet(context, card));
      case VaultItemKind.identity:
        final identity = ref.read(vaultControllerProvider).identities.where((i) => i.id == item.id).firstOrNull;
        if (identity != null) unawaited(showIdentitySheet(context, identity));
      case VaultItemKind.note:
        context.go('/vault/notes/${item.id}');
      case VaultItemKind.file:
        final file = ref.read(vaultControllerProvider).files.where((f) => f.id == item.id).firstOrNull;
        if (file != null) unawaited(showFileSheet(context, file));
      case VaultItemKind.passkey:
        final passkey = ref.read(vaultControllerProvider).passkeys.where((p) => p.id == item.id).firstOrNull;
        if (passkey != null) unawaited(showPasskeySheet(context, passkey));
      case VaultItemKind.key:
        final key = ref.read(vaultControllerProvider).keys.where((k) => k.id == item.id).firstOrNull;
        if (key != null) unawaited(showKeySheet(context, key));
      case VaultItemKind.contact:
        final contact = ref.read(vaultControllerProvider).contacts.where((c) => c.id == item.id).firstOrNull;
        if (contact != null) unawaited(showContactSheet(context, contact));
    }
  }

  /// Answers the offer of key reminders, which is then never made again.
  /// Accepting asks the phone for permission to notify.
  Future<void> _answerOffer(bool accept) async {
    if (!accept) return ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(keyRemindersOffered: true));
    final denied = context.t('settings.keyReminders.denied');
    final toasts = ref.read(toastsProvider.notifier);
    if (!await turnKeyRemindersOn(ref)) toasts.show(denied, severity: ToastSeverity.error);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    // Each PGP key's standing, against the clock now: read from the key, never stored
    final now = ref.watch(clockProvider)();
    final messages = context.messages;
    final keyListings = <String, KeyListing>{};
    for (final key in state.keys) {
      // An SSH key's fingerprint, hashed once per unlock
      if (key.kind == KeyKind.ssh) {
        keyListings[key.id] = KeyListing(sshFingerprint: ref.watch(sshFingerprintProvider(key.id)));
      }
      if (key.kind != KeyKind.pgp) continue;
      final info = ref.watch(pgpKeyInfoProvider(key.id));
      final standing = keyStanding(info, now);
      keyListings[key.id] = KeyListing(
        standing: standing,
        tag: standingLabel(messages, standing),
        pgpLine: info == null ? null : pgpListLine(info),
        cardTag: key.isOnCard ? messages.t('keys.card.tag') : null,
        cardWords: key.isOnCard ? messages.t('keys.card.search') : null,
        version6: info?.version == 6,
        postQuantum: info != null && pgpReadersMessageId(info) != null,
      );
    }
    // Each contact's check and the standing of its key, against the clock now
    final contactListings = <String, ContactListing>{};
    for (final contact in state.contacts) {
      final info = ref.watch(contactKeyInfoProvider(contact.id));
      final standing = contactStanding(contact, now, info: info);
      contactListings[contact.id] = ContactListing(
        checked: standing.checked,
        line: contactCheckLine(context, standing, now),
        standing: info == null ? null : standing.key,
        tag: info == null ? null : standingLabel(messages, standing.key),
        userIds: info?.userIds ?? const [],
        fingerprint: standing.fingerprint,
      );
    }
    final offerReminders = offersKeyReminders(
      vault: state.vault,
      listed: ref.watch(vaultRegistryProvider).isListed(state.vault.id),
      prefs: ref.watch(prefsProvider),
      standings: [for (final listing in keyListings.values) ?listing.standing],
    );
    // Each login's tag: a health warning, else New for a few days after AutoFill saved it, else Code when one is linked
    final accountIds = {for (final account in state.accounts) account.id};
    final locale = Localizations.localeOf(context).toLanguageTag();
    final health = ref.watch(loginHealthProvider);
    final loginListings = {
      for (final login in state.logins)
        login.id: loginListing(messages, login, now: now, accountIds: accountIds, locale: locale, warnings: health.of(login.id)),
    };
    // A card past its expiry month carries a tag saying so
    final cardTags = {
      for (final card in state.cards)
        if (card.isExpired(now)) card.id: messages.t('vault.card.expired'),
    };
    // A File item's line: its size and the day it was added
    final fileLines = {for (final file in state.files) file.id: fileLine(context, file.file, locale)};
    final items = vaultListItems(
      state,
      filter: _filter,
      query: _query.text,
      keyListings: keyListings,
      contactListings: contactListings,
      loginListings: loginListings,
      cardTags: cardTags,
      fileLines: fileLines,
    );
    final searching = _query.text.trim().isNotEmpty;
    final shown = items.pgp.length + items.ssh.length + items.pinned.length + items.rest.length + items.contacts.length;
    // With the PGP or the SSH keys in their group, what follows them is the other keys
    final restLabel = items.pgp.isNotEmpty || items.ssh.isNotEmpty
        ? 'vault.section.otherKeys'
        : searching
        ? 'accounts.section.results'
        : 'vault.section.all';

    return ShellPage(
      children: [
        const SizedBox(height: 40),
        PageTitle(title: context.t('vault.title'), count: items.total, subtitle: context.t('vault.subtitle')),
        if (items.total == 0) ...[
          EmptyState(
            icon: const Icon(Icons.inventory_2_outlined),
            title: context.t('vault.empty.title'),
            body: context.t('vault.empty.body'),
            action: FilledButton.icon(
              style: largeButtonStyle,
              onPressed: () => unawaited(showAddToVaultSheet(context)),
              icon: const Icon(Icons.add_rounded),
              label: Text(context.t('vault.empty.action')),
            ),
          ),
          // Encrypting with a passphrase needs no key, so an empty vault has the four actions too
          const PgpActionsRow(),
        ] else ...[
          if (offerReminders) _RemindersOffer(onAnswer: (accept) => unawaited(_answerOffer(accept))),
          const SizedBox(height: 20),
          SearchField(
            controller: _query,
            label: context.t('vault.searchLabel'),
            hint: context.t('vault.search', {'count': items.total}),
            clearLabel: context.t('accounts.clearSearch'),
          ),
          const SizedBox(height: 12),
          SegmentedControl<VaultFilter>(
            options: [for (final filter in VaultFilter.values) SegmentOption(value: filter, label: context.t(filter.labelId))],
            value: _filter,
            onChanged: (filter) => setState(() => _filter = filter),
            semanticLabel: context.t('vault.filter.label'),
            size: SegmentSize.small,
          ),
          if (_filter == VaultFilter.keys) const PgpActionsRow(),
          if (_filter == VaultFilter.logins && !searching) const PasswordHealthRow(),
          if (shown == 0)
            EmptyState(
              icon: Icon(searching ? Icons.search_off_rounded : _filterIcon(_filter)),
              title: searching ? context.t('vault.noMatches.title', {'query': _query.text.trim()}) : context.t('vault.noneOfKind'),
              body: searching ? context.t('vault.noMatches.body') : null,
            )
          else ...[
            if (items.pgp.isNotEmpty) ...[
              SectionLabel(context.t('vault.section.pgp')),
              _ItemCard(key: const ValueKey('pgp-keys'), items: items.pgp, onOpen: _open, pgpGroup: true),
            ],
            if (items.ssh.isNotEmpty) ...[
              SectionLabel(context.t('vault.section.ssh')),
              Rise(
                key: const ValueKey('ssh-keys'),
                child: _ItemCard(items: items.ssh, onOpen: _open),
              ),
            ],
            if (items.pinned.isNotEmpty) ...[
              SectionLabel(context.t('accounts.section.pinned')),
              _ItemCard(items: items.pinned, onOpen: _open),
            ],
            // A vault of other people's keys alone has nothing to head with "Everything"
            if (items.rest.isNotEmpty || (items.pgp.isEmpty && items.ssh.isEmpty && items.contacts.isEmpty))
              SectionLabel(context.t(restLabel)),
            if (items.rest.isNotEmpty) _ItemCard(items: items.rest, onOpen: _open),
            if (items.contacts.isNotEmpty) ...[
              SectionLabel(context.t('vault.section.contacts')),
              Rise(
                key: const ValueKey('contacts'),
                child: _ItemCard(items: items.contacts, onOpen: _open),
              ),
            ],
          ],
          // Checking someone else's SSH signature needs no key of the vault
          if (_filter == VaultFilter.keys) ...[
            const SizedBox(height: 26),
            Group(
              key: const ValueKey('verify-ssh'),
              children: [
                GroupRow(
                  first: true,
                  icon: const Icon(Icons.verified_outlined),
                  primary: context.t('keys.verify.entry'),
                  onTap: () => unawaited(showVerifySheet(context)),
                ),
              ],
            ),
          ],
        ],
        // Sends are made from the open vault and listed on a page of their own
        const SizedBox(height: 26),
        Group(
          key: const ValueKey('sends-entry'),
          children: [
            GroupRow(
              first: true,
              icon: const Icon(Icons.send_rounded),
              primary: context.t('sends.title'),
              secondary: context.t('sends.subtitle'),
              onTap: () => context.go('/vault/sends'),
            ),
          ],
        ),
      ],
    );
  }
}

IconData _filterIcon(VaultFilter filter) => switch (filter) {
  VaultFilter.all => Icons.inventory_2_outlined,
  VaultFilter.logins => VaultItemKind.login.icon,
  VaultFilter.cards => VaultItemKind.card.icon,
  VaultFilter.identities => VaultItemKind.identity.icon,
  VaultFilter.keys => VaultItemKind.key.icon,
  VaultFilter.notes => VaultItemKind.note.icon,
  VaultFilter.files => VaultItemKind.file.icon,
  VaultFilter.passkeys => VaultItemKind.passkey.icon,
};

/// Offers, once, to warn before a PGP key expires. Either answer puts it
/// away for good; Settings keeps the switch.
class _RemindersOffer extends StatelessWidget {
  const _RemindersOffer({required this.onAnswer});

  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Rise(
        child: Semantics(
          container: true,
          child: GroupCard(
            key: const ValueKey('key-reminders-offer'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      context.t('keys.reminders.offer.title'),
                      style: AppType.body1.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0, color: p.text),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(context.t('keys.reminders.offer.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => onAnswer(false), child: Text(context.t('keys.reminders.offer.dismiss'))),
                      const SizedBox(width: 4),
                      TextButton(onPressed: () => onAnswer(true), child: Text(context.t('keys.reminders.offer.accept'))),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded card of item rows. A key that needs attention has its tag
/// where the chevron would be, popping in once the row is there. In the PGP
/// group ([pgpGroup]) each row has a "PGP" tile and the key's address and
/// algorithm under its name, and a key that is over is written faint. An
/// SSH key's row, wherever it is listed, has an "SSH" tile and the key's
/// fingerprint, shortened and in the monospace face, under its name; it is
/// read out whole.
class _ItemCard extends StatelessWidget {
  const _ItemCard({super.key, required this.items, required this.onOpen, this.pgpGroup = false});

  final List<VaultListItem> items;
  final ValueChanged<VaultListItem> onOpen;
  final bool pgpGroup;

  @override
  Widget build(BuildContext context) => Group(
    children: [
      for (final (i, item) in items.indexed)
        GroupRow(
          key: ValueKey('${item.kind.name}:${item.id}'),
          first: i == 0,
          icon: pgpGroup
              ? const Text('PGP')
              : item.kind == VaultItemKind.contact
              ? Text(contactInitials(item.title))
              : item.isSsh
              ? Text(context.t('keys.ssh.tile'))
              : Icon(item.kind.icon),
          accent: pgpGroup && !(item.standing?.standing.isOver ?? false),
          muted: pgpGroup && (item.standing?.standing.isOver ?? false),
          primary: item.title,
          secondary: pgpGroup ? item.pgpLine ?? item.subtitle : item.subtitle,
          secondaryStyle: item.unchecked
              ? TextStyle(color: context.palette.warning)
              : item.fingerprint == null
              ? null
              : AppType.mono(),
          secondarySemanticsLabel: item.fingerprint,
          tag: item.tagTone != null && item.tag != null
              ? PopIn(
                  delay: Duration(milliseconds: 200 + 60 * i),
                  child: StatusTag(label: item.tag!, tone: item.tagTone!),
                )
              : item.cardTag == null && (item.standing == null || item.tag == null) && !item.version6
              ? null
              : PopIn(
                  delay: Duration(milliseconds: 200 + 60 * i),
                  // The row caps its tag slot, so the badges wrap onto a second line rather than overflow
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (item.cardTag != null) const KeyOnCardTag(),
                      if (item.standing != null && item.tag != null) KeyStandingTag(standing: item.standing!),
                      if (item.version6) const AccentTag(key: ValueKey('v6'), label: 'v6'),
                    ],
                  ),
                ),
          onTap: () => onOpen(item),
        ),
    ],
  );
}
