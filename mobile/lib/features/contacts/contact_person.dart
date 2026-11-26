import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../models/json.dart';
import '../../platform/links.dart';
import '../../ui/ui.dart';

/// The text fields of the person a contact is: company, email, phone and address (free text, with line breaks). Each is optional, and
/// an empty one is left out of the contact.
class PersonFields {
  PersonFields([Contact? contact])
    : company = TextEditingController(text: contact?.company ?? ''),
      email = TextEditingController(text: contact?.email ?? ''),
      phone = TextEditingController(text: contact?.phone ?? ''),
      address = TextEditingController(text: contact?.address ?? '');

  final TextEditingController company;
  final TextEditingController email;
  final TextEditingController phone;
  final TextEditingController address;

  List<TextEditingController> get all => [company, email, phone, address];

  void addListener(VoidCallback listener) {
    for (final field in all) {
      field.addListener(listener);
    }
  }

  void dispose() {
    for (final field in all) {
      field.dispose();
    }
  }

  static Object _text(TextEditingController field) => field.text.trim().isEmpty ? unset : field.text.trim();

  /// [contact] with these fields in it; an empty field removes the member.
  Contact applyTo(Contact contact) =>
      contact.copyWith(company: _text(company), email: _text(email), phone: _text(phone), address: _text(address));

  /// The four fields, one under the other, to sit in a form.
  Widget form(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 14,
    children: [
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: company,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: context.t('contacts.person.company')),
      ),
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: email,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        decoration: InputDecoration(labelText: context.t('contacts.person.email')),
      ),
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: phone,
        keyboardType: TextInputType.phone,
        decoration: InputDecoration(labelText: context.t('contacts.person.phone')),
      ),
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: address,
        minLines: 2,
        maxLines: 5,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: context.t('contacts.person.address'), alignLabelWithHint: true),
      ),
    ],
  );
}

/// What a contact is as a person, one row each for the fields it has, with Copy, and Mail and Call that hand the address and the number
/// to the phone's own apps. Nothing when it has none of them.
class PersonRows extends ConsumerWidget {
  const PersonRows({super.key, required this.contact});

  final Contact contact;

  Future<void> _copy(BuildContext context, WidgetRef ref, String text) async {
    final toasts = ref.read(toastsProvider.notifier);
    final copied = context.t('contacts.person.copied');
    await Clipboard.setData(ClipboardData(text: text));
    toasts.show(copied);
  }

  Future<void> _launch(BuildContext context, WidgetRef ref, Uri uri) async {
    final toasts = ref.read(toastsProvider.notifier);
    final failed = context.t('contacts.person.cantOpen');
    if (!await ref.read(linkLauncherProvider).launch(uri)) toasts.show(failed, severity: ToastSeverity.error);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget copyButton(String text, String label) =>
        IconButton(tooltip: label, icon: const Icon(Icons.copy_rounded, size: 20), onPressed: () => unawaited(_copy(context, ref, text)));
    final company = contact.company;
    final email = contact.email;
    final phone = contact.phone;
    final address = contact.address;
    final rows = <GroupRow Function(bool first)>[
      if (company != null && company.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.business_outlined),
          primary: context.t('contacts.person.company'),
          secondary: company,
          control: copyButton(company, context.t('contacts.person.copy.company')),
        ),
      if (email != null && email.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.mail_outline_rounded),
          primary: context.t('contacts.person.email'),
          secondary: email,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('person-mail'),
                tooltip: context.t('contacts.person.mail'),
                icon: const Icon(Icons.send_outlined, size: 20),
                onPressed: () => unawaited(_launch(context, ref, Uri(scheme: 'mailto', path: email))),
              ),
              copyButton(email, context.t('contacts.person.copy.email')),
            ],
          ),
        ),
      if (phone != null && phone.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.phone_outlined),
          primary: context.t('contacts.person.phone'),
          secondary: phone,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('person-call'),
                tooltip: context.t('contacts.person.call'),
                icon: const Icon(Icons.call_outlined, size: 20),
                onPressed: () => unawaited(_launch(context, ref, Uri(scheme: 'tel', path: phone))),
              ),
              copyButton(phone, context.t('contacts.person.copy.phone')),
            ],
          ),
        ),
      if (address != null && address.isNotEmpty)
        (first) => GroupRow(
          first: first,
          icon: const Icon(Icons.home_outlined),
          primary: context.t('contacts.person.address'),
          secondary: address,
          control: copyButton(address, context.t('contacts.person.copy.address')),
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Group(key: const ValueKey('contact-person'), children: [for (final (i, row) in rows.indexed) row(i == 0)]),
    );
  }
}

/// The line under a person with no key in the vault list: their company and email, or none.
String? personLine(Contact contact) {
  final parts = [?contact.company, ?contact.email].where((part) => part.isNotEmpty);
  return parts.isEmpty ? null : parts.join(' · ');
}
