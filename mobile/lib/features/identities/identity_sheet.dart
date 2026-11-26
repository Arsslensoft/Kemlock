import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/identity.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../fields/custom_fields_view.dart';
import '../lock/gate_widgets.dart';
import '../settings/prefs.dart';
import '../vault/owner_check.dart';
import 'countries.dart';
import 'identity_edit_sheet.dart';

/// What a hidden document number shows.
const _dots = '••••••••';

/// The message that names a document type.
String documentTypeId(IdentityDocumentType type) => 'identities.doc.${type.wire}';

/// A `yyyy-mm-dd` date as the language writes it ("14 Mar 2031"), or the text as stored when it isn't one.
String identityDateText(String stored, String locale) {
  final date = DateTime.tryParse(stored);
  return date == null ? stored : DateFormat('d MMM y', locale).format(date);
}

/// Opens an identity from the Vault tab.
Future<void> showIdentitySheet(BuildContext context, Identity identity) => showAppBottomSheet<void>(
  context,
  label: identity.name,
  builder: (_) => IdentitySheet(identityId: identity.id),
);

/// An identity (the add-cards-identities-and-websites plan): the person's
/// names, contact details and birth date, their address, and their documents
/// with each number hidden until shown, Copy through the clipboard that
/// clears itself, and Expired on a document past its date; Edit and Delete.
class IdentitySheet extends ConsumerStatefulWidget {
  const IdentitySheet({super.key, required this.identityId});

  final String identityId;

  @override
  ConsumerState<IdentitySheet> createState() => _IdentitySheetState();
}

class _IdentitySheetState extends ConsumerState<IdentitySheet> {
  /// The ids of the documents whose number shows.
  final _shown = <String>{};

  Future<void> _copy(String text, String messageId) async {
    if (await ref.read(secretClipboardProvider).copy(text) && mounted) {
      ref.read(toastsProvider.notifier).show(context.t(messageId));
    }
  }

  Future<void> _toggle(String documentId) async {
    if (!_shown.contains(documentId) && ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('identities.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) return;
    }
    setState(() => _shown.contains(documentId) ? _shown.remove(documentId) : _shown.add(documentId));
  }

  Future<void> _delete(Identity identity) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('identities.delete.title'),
      body: Text(context.t('identities.delete.body', {'name': identity.name})),
      confirmLabel: context.t('identities.delete.confirm'),
      cancelLabel: context.t('identities.cancel'),
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deleteIdentity(identity);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final identity = ref.watch(
      vaultControllerProvider.select((state) => state.identities.firstWhereOrNull((i) => i.id == widget.identityId)),
    );
    if (identity == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('identities.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final locale = Localizations.localeOf(context).toLanguageTag();
    final language = Localizations.localeOf(context).languageCode;
    final now = ref.watch(clockProvider)();
    final mono = AppType.mono();

    Widget copyButton(String text, String messageId, String label) =>
        IconButton(tooltip: label, icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () => unawaited(_copy(text, messageId)));

    final address = identity.address;
    final addressLines = [
      ...?address?.lines,
      [address?.postalCode, address?.city].whereType<String>().where((part) => part.isNotEmpty).join(' '),
      address?.region ?? '',
      if (address?.country case final country? when country.isNotEmpty) countryLabel(country, language),
    ].where((line) => line.trim().isNotEmpty).toList();

    final rows = <GroupRow Function(bool first)>[
      if (identity.fullName case final name?)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.badge_outlined),
          primary: context.t('identities.name'),
          secondary: [?identity.title, name].join(' '),
        ),
      if (identity.company case final company? when company.isNotEmpty)
        (first) =>
            GroupRow(first: first, icon: const Icon(Icons.business_outlined), primary: context.t('identities.company'), secondary: company),
      if (identity.email case final email? when email.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.mail_outline_rounded),
          primary: context.t('identities.email'),
          secondary: email,
          control: copyButton(email, 'identities.copied.email', context.t('identities.copy.email')),
        ),
      if (identity.phone case final phone? when phone.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.phone_outlined),
          primary: context.t('identities.phone'),
          secondary: phone,
          control: copyButton(phone, 'identities.copied.phone', context.t('identities.copy.phone')),
        ),
      if (identity.username case final username? when username.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.person_outline_rounded),
          primary: context.t('identities.username'),
          secondary: username,
        ),
      if (identity.birthDate case final birth? when birth.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.cake_outlined),
          primary: context.t('identities.birthDate'),
          secondary: identityDateText(birth, locale),
        ),
      if (addressLines.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.home_outlined),
          primary: context.t('identities.address'),
          secondary: addressLines.join('\n'),
        ),
    ];

    GroupRow documentRow(IdentityDocument document, bool first) {
      final expired = document.isExpired(now);
      final shown = _shown.contains(document.id);
      final line = [
        context.t(documentTypeId(document.kind)),
        if (document.issuingCountry case final country? when country.isNotEmpty) countryLabel(country, language),
        if (document.expiresOn case final expires? when expires.isNotEmpty)
          context.t('identities.doc.expires', {'date': identityDateText(expires, locale)}),
      ].join(' · ');
      return GroupRow(
        key: ValueKey('document:${document.id}'),
        first: first,
        icon: const Icon(Icons.assignment_ind_outlined),
        primary: expired ? '$line · ${context.t('identities.expired')}' : line,
        secondary: shown ? document.number : _dots,
        secondaryStyle: mono,
        secondarySemanticsLabel: shown ? null : context.t('identities.hidden'),
        control: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevealPasswordButton(shown: shown, onPressed: () => unawaited(_toggle(document.id))),
            copyButton(document.number, 'identities.copied.number', context.t('identities.copy.number')),
          ],
        ),
      );
    }

    final documents = identity.documents ?? const <IdentityDocument>[];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.badge_outlined), title: identity.name),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rows.isNotEmpty) Group(children: [for (final (i, row) in rows.indexed) row(i == 0)]),
                if (documents.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionLabel(context.t('identities.documents')),
                  Group(children: [for (final (i, document) in documents.indexed) documentRow(document, i == 0)]),
                ],
                if (identity.note case final note? when note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionLabel(context.t('identities.note')),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
                    child: Text(note, style: AppType.body2.copyWith(color: p.text)),
                  ),
                ],
                if (identity.tags case final tags? when tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                    child: Text(tags.join(' · '), style: AppType.caption.copyWith(color: p.textSecondary)),
                  ),
                CustomFieldsView(fields: identity.fields),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: largeButtonStyle,
                  onPressed: () => unawaited(showIdentityEditSheet(context, identity: identity)),
                  child: Text(context.t('identities.edit')),
                ),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t('identities.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(identity)),
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
