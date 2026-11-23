/// The request screen's pages that are not the approval (openspec:
/// add-pgp-mail-provider, decision 11): which key to sign with, letting
/// the app use one more key, the addresses with no key, and an unchecked
/// key. They have no mockup: each is a plain page with Kemlock's mark at
/// the top, built from the app's own widgets.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../pgp/pgp_people.dart' show groupedFingerprint, shortKeyId;
import 'mail_caller.dart';
import 'mail_keys.dart';

/// A request page: Kemlock's mark, a [title], what goes under it, and the
/// buttons at the foot, the main one last.
class MailRequestPage extends StatelessWidget {
  const MailRequestPage({super.key, required this.title, this.children = const [], this.actions = const []});

  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: BrandWordmark(height: 26, label: context.t('app.title')),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(title, style: AppType.h2.copyWith(fontSize: 26, letterSpacing: -0.8, color: p.text)),
                  ),
                  const SizedBox(height: 12),
                  ...children,
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 8, children: actions.reversed.toList()),
              ),
          ],
        ),
      ),
    );
  }
}

/// A short line under a page's title.
class MailRequestText extends StatelessWidget {
  const MailRequestText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: AppType.body1.copyWith(color: context.palette.textSecondary)),
  );
}

/// The two letters of a mail app's tile: the first letters of its first
/// two words, a capital inside a name starting a word (`Fe` for FairEmail,
/// `K9` for K-9 Mail), or the first two letters of a single word (`Th` for
/// Thunderbird).
String mailAppLetters(String name) {
  final spaced = name.replaceAllMapped(RegExp(r'(\p{Ll})(\p{Lu})', unicode: true), (m) => '${m[1]} ${m[2]}');
  final words = spaced.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  String first(String word) => String.fromCharCode(word.runes.first);
  if (words.length > 1) return first(words[0]).toUpperCase() + first(words[1]).toLowerCase();
  final runes = words.single.runes.take(2).toList();
  return String.fromCharCode(runes.first).toUpperCase() + (runes.length > 1 ? String.fromCharCode(runes[1]).toLowerCase() : '');
}

/// Which key the mail app should sign with: the vault's keys that can
/// sign, those with [address] first. Picking one hands its id to
/// [onPick].
class MailKeyPicker extends ConsumerWidget {
  const MailKeyPicker({super.key, required this.caller, this.address, this.preselect, required this.onPick, required this.onCancel});

  final MailCaller caller;
  final String? address;
  final int? preselect;
  final void Function(MailOwnKey key) onPick;
  final VoidCallback onCancel;

  /// The keys offered, in order: [address]'s first, then the vault's order.
  static List<MailOwnKey> offered(MailKeys keys, String? address) {
    final usable = keys.own.where((k) => k.canSignAt(keys.now)).toList();
    if (address == null) return usable;
    return [...usable.where((k) => k.addresses.contains(address)), ...usable.whereNot((k) => k.addresses.contains(address))];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(vaultControllerProvider.select((state) => state.keys));
    final keys = offered(readMailKeys(ref.read), address);
    return MailRequestPage(
      title: context.t('mail.pick.title', {'app': caller.name}),
      actions: [TextButton(onPressed: onCancel, child: Text(context.t('mail.lock.cancel')))],
      children: [
        if (keys.isEmpty)
          MailRequestText(context.t('mail.pick.none'))
        else
          GroupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, key) in keys.indexed)
                  GroupRow(
                    key: ValueKey('pick-${key.key.id}'),
                    first: index == 0,
                    icon: const Text('PGP'),
                    primary: key.title,
                    secondary: key.userId ?? groupedFingerprint(shortKeyId(key.fingerprint)),
                    value: key.keyId == preselect ? const Icon(Icons.check_rounded) : null,
                    onTap: () => onPick(key),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Whether the mail app may use one more of the vault's keys.
class MailAddKeyScreen extends StatelessWidget {
  const MailAddKeyScreen({super.key, required this.caller, required this.keyTitle, required this.onAllow, required this.onDeny});

  final MailCaller caller;
  final String keyTitle;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) => MailRequestPage(
    title: context.t('mail.addKey.title', {'app': caller.name, 'key': keyTitle}),
    actions: [
      TextButton(onPressed: onDeny, child: Text(context.t('mail.approve.deny'))),
      FilledButton(onPressed: onAllow, child: Text(context.t('mail.approve.allow'))),
    ],
    children: [
      MailRequestText(context.t('mail.addKey.body', {'app': caller.name})),
    ],
  );
}

/// The addresses a message could not be encrypted to. It can only close.
class MailMissingKeysScreen extends StatelessWidget {
  const MailMissingKeysScreen({super.key, required this.addresses, required this.onClose});

  final List<String> addresses;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => MailRequestPage(
    title: context.t('mail.missing.title'),
    actions: [FilledButton(onPressed: onClose, child: Text(context.t('mail.missing.close')))],
    children: [
      MailRequestText(context.t('mail.missing.body')),
      GroupCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, address) in addresses.indexed)
              GroupRow(first: index == 0, icon: const Icon(Icons.alternate_email_rounded), primary: address),
          ],
        ),
      ),
    ],
  );
}

/// A recipient's key that is not checked for the address the mail app
/// encrypts to: never compared, or compared before the key named that
/// address, which the check then doesn't cover. Check it now, or go on.
class MailUncheckedScreen extends StatelessWidget {
  const MailUncheckedScreen({
    super.key,
    required this.caller,
    required this.contacts,
    required this.onCheck,
    required this.onGoOn,
    required this.onCancel,
  });

  final MailCaller caller;
  final List<({Contact contact, String fingerprint})> contacts;
  final void Function(Contact contact) onCheck;
  final VoidCallback onGoOn;
  final VoidCallback onCancel;

  /// Whether [entry]'s fingerprint was compared, as `contactStanding` tells:
  /// it is asked about then only for an address its check doesn't cover.
  static bool _compared(({Contact contact, String fingerprint}) entry) =>
      entry.contact.checkedFingerprint?.toUpperCase() == entry.fingerprint.toUpperCase();

  @override
  Widget build(BuildContext context) {
    final first = contacts.first.contact;
    final compared = contacts.where(_compared).length;
    final bodyId = compared == 0
        ? 'mail.unchecked.body'
        : compared == contacts.length
        ? 'mail.unchecked.body.otherAddress'
        : 'mail.unchecked.body.mixed';
    return MailRequestPage(
      title: context.t('mail.unchecked.title', {
        'name': contacts.length == 1 ? first.name : contacts.map((c) => c.contact.name).join(', '),
      }),
      actions: [
        TextButton(onPressed: onCancel, child: Text(context.t('mail.lock.cancel'))),
        OutlinedButton(onPressed: onGoOn, child: Text(context.t('mail.unchecked.anyway'))),
      ],
      children: [
        MailRequestText(context.t(bodyId, {'app': caller.name})),
        GroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, entry) in contacts.indexed)
                GroupRow(
                  key: ValueKey('unchecked-${entry.contact.id}'),
                  first: index == 0,
                  primary: entry.contact.name,
                  secondary: groupedFingerprint(entry.fingerprint),
                  secondaryStyle: AppType.mono(fontSize: 12),
                  control: TextButton(onPressed: () => onCheck(entry.contact), child: Text(context.t('mail.unchecked.check'))),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
