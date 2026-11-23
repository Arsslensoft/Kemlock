/// The contacts a message can be encrypted to, and the warning shown when
/// one of the chosen ones was never checked (openspec: add-pgp-contacts,
/// decision 18). The sheet that encrypts belongs to add-pgp-messages: it
/// takes its recipients from [contactRecipientsProvider] and places
/// [UncheckedRecipientsWarning] above its button.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'contact_check.dart';
import 'contact_standing.dart';

/// A contact that can be a recipient, with its standing now.
@immutable
class ContactRecipient {
  const ContactRecipient(this.contact, this.standing);

  final Contact contact;

  /// Whether it is checked, and what its key holds: an encryption key that
  /// is neither expired nor revoked, or it would not be a recipient.
  final ContactStanding standing;
}

/// The open vault's contacts a message can be encrypted to, by name: those
/// whose key holds an encryption key that is still valid. A contact whose
/// key expired, was revoked, only signs or can't be read is left out.
/// Checked or not makes no difference here: an unchecked contact is
/// offered, and warned about each time.
final contactRecipientsProvider = Provider<List<ContactRecipient>>((ref) {
  final contacts = ref.watch(vaultControllerProvider.select((state) => state.contacts));
  final now = ref.watch(clockProvider)();
  final recipients = [
    for (final contact in contacts)
      if (contactStanding(contact, now, info: ref.watch(contactKeyInfoProvider(contact.id))) case final standing when standing.canEncrypt)
        ContactRecipient(contact, standing),
  ];
  return recipients..sort((a, b) => a.contact.name.toLowerCase().compareTo(b.contact.name.toLowerCase()));
});

/// Warns that some of the contacts about to be encrypted to were never
/// checked: it names them, says what that means, and offers to check each
/// now. It renders nothing when every one of [contactIds] is checked, and
/// it cannot be put away for good: it is worked out from the contacts each
/// time it is built, so it shows again the next time the same unchecked
/// contact is chosen, until that contact is checked.
class UncheckedRecipientsWarning extends ConsumerWidget {
  const UncheckedRecipientsWarning({super.key, required this.contactIds});

  /// The ids of the chosen contacts.
  final List<String> contactIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(vaultControllerProvider.select((state) => state.contacts));
    final now = ref.watch(clockProvider)();
    final chosen = {...contactIds};
    final unchecked = [
      for (final contact in contacts)
        if (chosen.contains(contact.id) && !contactStanding(contact, now, info: ref.watch(contactKeyInfoProvider(contact.id))).checked)
          contact,
    ];
    if (unchecked.isEmpty) return const SizedBox.shrink();
    final one = unchecked.length == 1;
    return AppAlert(
      key: const ValueKey('unchecked-recipients'),
      severity: AlertSeverity.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            one
                ? context.t('contacts.warning.one', {'name': unchecked.single.name})
                : context.t('contacts.warning.many', {'names': unchecked.map((contact) => contact.name).join(', ')}),
          ),
          Wrap(
            spacing: 4,
            children: [
              for (final contact in unchecked)
                TextButton(
                  onPressed: () => unawaited(checkContactFingerprint(context, ref, contact)),
                  child: Text(one ? context.t('contacts.warning.check') : context.t('contacts.warning.checkOne', {'name': contact.name})),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
