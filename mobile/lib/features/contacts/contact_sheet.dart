import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../crypto/keys/keys.dart' as crypto;
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../models/custom_field.dart';
import '../../models/json.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../fields/custom_fields_editor.dart';
import '../keys/key_bridge.dart';
import '../keys/key_standing.dart';
import '../keys/key_widgets.dart';
import '../links/linked_items_section.dart';
import '../spaces/hidden_passwords.dart';
import '../sync/kemlock/km_kinds.dart';
import 'add_contact_sheet.dart';
import 'contact_check.dart';
import 'contact_keys.dart';
import 'contact_person.dart';
import 'contact_standing.dart';
import 'contact_widgets.dart';
import 'lookup/key_search_sheet.dart';

/// Opens someone's key from the Vault tab.
Future<void> showContactSheet(BuildContext context, Contact contact) => showAppBottomSheet<void>(
  context,
  label: contact.name,
  builder: (_) => ContactSheet(contactId: contact.id),
);

/// Someone's public key (openspec: add-pgp-contacts, decision 16): whether
/// its fingerprint was checked and when, what the key is and when it
/// expires, where it came from, its fingerprint in groups, the names on it
/// and its subkeys, and the key itself to copy, share or show as a QR code.
/// The key can be checked by comparing the groups or by scanning its
/// owner's code, the mark taken back, and the key updated; the name and the
/// note can change. Delete has Undo in the toast. A key that expired, was
/// revoked or holds no encryption key says that it can't be encrypted to.
class ContactSheet extends ConsumerStatefulWidget {
  const ContactSheet({super.key, required this.contactId});

  final String contactId;

  @override
  ConsumerState<ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends ConsumerState<ContactSheet> {
  late final Contact? _initial = ref.read(vaultControllerProvider).contacts.firstWhereOrNull((c) => c.id == widget.contactId);
  late final _name = TextEditingController(text: _initial?.name ?? '');
  late final _note = TextEditingController(text: _initial?.note ?? '');
  late final _person = PersonFields(_initial);

  /// The custom fields, as the editor last gave them.
  late var _customFields = <CustomField>[...?_initial?.fields];

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _note.addListener(() => setState(() {}));
    _person.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _person.dispose();
    super.dispose();
  }

  Contact _edited(Contact contact) {
    final name = _name.text.trim();
    final note = _note.text.trim();
    return _person
        .applyTo(contact)
        .copyWith(name: name.isEmpty ? contact.name : name, note: note.isEmpty ? unset : note, fields: _customFields);
  }

  Future<void> _copy(String text) async {
    final toasts = ref.read(toastsProvider.notifier);
    final copied = context.t('keys.public.copied');
    await Clipboard.setData(ClipboardData(text: text));
    toasts.show(copied);
  }

  Future<void> _share(Contact contact, String text) {
    final base = contact.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return ref
        .read(fileServiceProvider)
        .shareFile('${base.isEmpty ? 'key' : base}.pub.asc', Uint8List.fromList(utf8.encode(text)), mimeType: 'text/plain');
  }

  Future<void> _save(Contact contact) async {
    if (await ref.read(vaultControllerProvider.notifier).updateContact(_edited(contact)) && mounted) Navigator.of(context).pop();
  }

  /// Takes the key off the person, who stays with their details; the check goes with the key. Asks first.
  Future<void> _removeKey(Contact contact) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.key_off_outlined),
      title: context.t('contacts.person.removeKey.title'),
      body: Text(context.t('contacts.person.removeKey.confirmBody', {'name': contact.name})),
      confirmLabel: context.t('contacts.person.removeKey.confirm'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!confirmed || !mounted) return;
    await ref
        .read(vaultControllerProvider.notifier)
        .updateContact(
          contact.copyWith(
            publicKey: '',
            source: ContactSource.manual,
            sourceEmail: unset,
            checkedAt: unset,
            checkedFingerprint: unset,
            checkedAddresses: unset,
          ),
        );
  }

  Future<void> _delete(Contact contact) async {
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deleteContact(contact);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final contact = ref.watch(vaultControllerProvider.select((state) => state.contacts.firstWhereOrNull((c) => c.id == widget.contactId)));
    if (contact == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('contacts.sheet.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final now = ref.watch(clockProvider)();
    final info = ref.watch(contactKeyInfoProvider(contact.id));
    final standing = contactStanding(contact, now, info: info);
    final changed = _edited(contact) != contact;
    final armored = info == null ? null : crypto.writeArmor(crypto.pgpPublicKeyBlock, unb64(contact.publicKey));
    // The address a newer copy is looked for at (openspec: add-key-lookup): the one the key was found for, else
    // the first its user IDs name; none for a key that names no address
    final addresses = info?.userIds.map(userIdAddress).nonNulls.toList() ?? const <String>[];
    final lookupAddress = addresses.isEmpty ? null : contact.sourceEmail ?? addresses.first;
    // What the key names since it was checked, which the check does not cover
    final notCovered = standing.checked ? standing.uncheckedAddresses : const <String>{};
    final controller = ref.read(vaultControllerProvider.notifier);
    String purposes(crypto.PgpKey key) => [
      if (key.canCertify) context.t('keys.pgp.certify'),
      if (key.canSign) context.t('keys.pgp.sign'),
      if (key.canEncrypt) context.t('keys.pgp.encrypt'),
      if (key.canAuthenticate) context.t('keys.pgp.authenticate'),
    ].join(', ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: Text(contactInitials(contact.name), style: AppType.body1.copyWith(fontWeight: FontWeight.w600)),
          title: contact.name,
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PersonRows(contact: contact),
                if (!contact.hasKey)
                  AppAlert(
                    key: const ValueKey('contact-no-key'),
                    severity: AlertSeverity.info,
                    child: Text(context.t('contacts.person.noKey')),
                  )
                else if (info == null)
                  AppAlert(severity: AlertSeverity.error, child: Text(context.t('contacts.sheet.unreadable')))
                else ...[
                  if (standing.key.standing.isOver || !standing.canEncrypt) ...[
                    AppAlert(
                      key: const ValueKey('contact-standing'),
                      severity: standing.key.standing.isOver ? AlertSeverity.error : AlertSeverity.info,
                      child: Text(switch (standing.key.standing) {
                        Standing.revoked => context.t('contacts.review.revokedBody'),
                        Standing.expired => context.t('contacts.review.expired', {'date': contactDate(context, standing.key.expires!)}),
                        _ => context.t('contacts.review.cannotEncrypt'),
                      }),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (notCovered.isNotEmpty) ...[
                    AppAlert(
                      key: const ValueKey('contact-not-covered'),
                      severity: AlertSeverity.warning,
                      child: Text(context.t('contacts.sheet.notCovered', {'addresses': notCovered.join(', ')})),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Group(
                    key: const ValueKey('contact-facts'),
                    children: [
                      GroupRow(
                        first: true,
                        icon: Icon(standing.checked ? Icons.verified_outlined : Icons.gpp_maybe_outlined),
                        accent: standing.checked,
                        primary: context.t('contacts.sheet.check'),
                        value: DefaultTextStyle.merge(
                          style: standing.checked ? null : TextStyle(color: p.warning),
                          child: RowValue(contactCheckLine(context, standing, now), key: const ValueKey('contact-check')),
                        ),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.memory_rounded),
                        primary: context.t('keys.field.algorithm'),
                        value: Text(pgpAlgorithmLabel(info.primary)),
                      ),
                      GroupRow(
                        key: const ValueKey('contact-expiry'),
                        icon: const Icon(Icons.event_busy_outlined),
                        primary: context.t('keys.field.expiry'),
                        value: Text(
                          standing.key.expires == null
                              ? context.t('keys.expiry.never')
                              : contactDate(context, standing.key.expires!, short: true),
                        ),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.call_received_rounded),
                        primary: context.t('contacts.review.source'),
                        value: RowValue(contactSourceText(context.messages, contact.source, contact.sourceEmail)),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.event_outlined),
                        primary: context.t('keys.field.added'),
                        value: Text(contactDate(context, DateTime.fromMillisecondsSinceEpoch(contact.addedAt), short: true)),
                      ),
                    ],
                  ),
                  SectionLabel(context.t('contacts.review.fingerprint')),
                  FingerprintCard(fingerprint: info.primary.fingerprintHex),
                  SectionLabel(context.t('contacts.sheet.userIds')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final user in info.userIds) Text(user, style: AppType.body2.copyWith(color: p.text)),
                        const SizedBox(height: 6),
                        Text(
                          context.t('keys.pgp.primary', {'algorithm': info.primary.algorithm, 'purposes': purposes(info.primary)}),
                          style: AppType.caption.copyWith(color: p.textSecondary),
                        ),
                        for (final subkey in info.subkeys)
                          Text(
                            context.t('keys.pgp.subkey', {'algorithm': subkey.algorithm, 'purposes': purposes(subkey)}),
                            style: AppType.caption.copyWith(color: p.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  if (armored != null) ...[
                    SectionLabel(context.t('contacts.sheet.publicKey')),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: context.bmc.raised, borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        armored,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.mono(fontSize: 11, color: p.text),
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () => unawaited(_copy(armored)),
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: Text(context.t('keys.public.copy')),
                        ),
                        TextButton.icon(
                          onPressed: () => unawaited(_share(contact, armored)),
                          icon: const Icon(Icons.ios_share_rounded, size: 18),
                          label: Text(context.t('notes.copy.share')),
                        ),
                        TextButton.icon(
                          onPressed: () => unawaited(showPublicKeyQr(context, armored, fingerprint: info.primary.fingerprintHex)),
                          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                          label: Text(context.t('keys.public.qr')),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Group(
                    key: const ValueKey('contact-actions'),
                    children: [
                      // Checked again, for what the key names now, when it names an address its check does not cover
                      if (!standing.checked || notCovered.isNotEmpty) ...[
                        GroupRow(
                          first: true,
                          icon: const Icon(Icons.fact_check_outlined),
                          primary: context.t('contacts.sheet.checkNow'),
                          secondary: context.t('contacts.sheet.checkNow.body'),
                          onTap: () => unawaited(checkContactFingerprint(context, ref, contact)),
                        ),
                        GroupRow(
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          primary: context.t('contacts.sheet.checkScan'),
                          secondary: context.t('contacts.sheet.checkScan.body'),
                          onTap: () => unawaited(checkContactByScanning(context, ref, contact)),
                        ),
                      ],
                      if (standing.checked)
                        GroupRow(
                          first: notCovered.isEmpty,
                          icon: const Icon(Icons.remove_moderator_outlined),
                          primary: context.t('contacts.sheet.uncheck'),
                          secondary: context.t('contacts.sheet.uncheck.body'),
                          onTap: () => unawaited(controller.updateContact(contact.unchecked())),
                        ),
                      GroupRow(
                        icon: const Icon(Icons.sync_rounded),
                        primary: context.t('contacts.sheet.update'),
                        secondary: context.t('contacts.sheet.update.body'),
                        onTap: () =>
                            unawaited(showAddContactSheet(context, replacingId: contact.id, title: context.t('contacts.sheet.update'))),
                      ),
                      if (lookupAddress != null)
                        GroupRow(
                          key: const ValueKey('contact-lookup'),
                          icon: const Icon(Icons.travel_explore_rounded),
                          primary: context.t('contacts.sheet.lookup'),
                          secondary: lookupAddress,
                          // Filled in and waiting for "Search", so what is sent is read first
                          onTap: () => unawaited(showKeySearchSheet(context, address: lookupAddress, replacingId: contact.id)),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Group(
                  key: const ValueKey('contact-key-actions'),
                  children: [
                    if (!contact.hasKey)
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.vpn_key_outlined),
                        primary: context.t('contacts.person.addKey'),
                        secondary: context.t('contacts.person.addKey.body'),
                        onTap: () =>
                            unawaited(showAddContactSheet(context, replacingId: contact.id, title: context.t('contacts.person.addKey'))),
                      )
                    else
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.key_off_outlined),
                        primary: context.t('contacts.person.removeKey'),
                        secondary: context.t('contacts.person.removeKey.body'),
                        onTap: () => unawaited(_removeKey(contact)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  decoration: InputDecoration(labelText: context.t('keys.field.name')),
                ),
                const SizedBox(height: 14),
                _person.form(context),
                const SizedBox(height: 14),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('passkeys.note'), alignLabelWithHint: true),
                ),
                const SizedBox(height: 14),
                CustomFieldsEditor(
                  kind: itemKindOf(contact),
                  fields: _customFields,
                  onChanged: (next) => setState(() => _customFields = next),
                  hideSecrets: hidesSecretsOf(ref, contact),
                ),
                LinkedItemsSection(entry: contact),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t(contact.hasKey ? 'contacts.sheet.delete' : 'contacts.person.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(contact)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: changed ? () => unawaited(_save(contact)) : null,
                  child: Text(context.t('passkeys.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
