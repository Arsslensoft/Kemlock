/// "Add someone": picks whom to encrypt to, or whose key to check a
/// signature with (openspec: add-pgp-messages). One of the people at hand,
/// the vault's own keys or the other people's keys it keeps, is added at a
/// tap. A public key pasted or chosen as a file is read, shown with its
/// user ID and its whole fingerprint, and added only when the person says
/// so; it is used for this action and not kept.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/keys/pgp.dart' as pgp;
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
// Both name a userIdName of their own: this one is prefixed
import '../contacts/contact_keys.dart' as contact_keys;
import '../contacts/recipients.dart';
import 'pgp_people.dart';
import 'pgp_widgets.dart';

/// Opens the sheet and gives the person chosen, or null. People whose
/// fingerprint is in [exclude] are not offered again. With [forSigner]
/// the key is wanted to check a signature: an expired key will do, and
/// the words say "for this check".
Future<PgpPerson?> showAddSomeoneSheet(BuildContext context, {Set<String> exclude = const {}, bool forSigner = false}) =>
    showAppBottomSheet<PgpPerson>(
      context,
      label: context.t(forSigner ? 'pgp.people.giveKey.title' : 'pgp.people.title'),
      builder: (_) => AddSomeoneSheet(exclude: exclude, forSigner: forSigner),
    );

class AddSomeoneSheet extends ConsumerStatefulWidget {
  const AddSomeoneSheet({super.key, this.exclude = const {}, this.forSigner = false});

  final Set<String> exclude;
  final bool forSigner;

  @override
  ConsumerState<AddSomeoneSheet> createState() => _AddSomeoneSheetState();
}

class _AddSomeoneSheetState extends ConsumerState<AddSomeoneSheet> with ClosesOnLock {
  final _paste = TextEditingController();
  var _pasting = false;
  var _reading = false;
  String? _error;

  /// A key that was read and waits for a yes or no.
  PgpPerson? _found;
  String _foundUserId = '';

  @override
  void initState() {
    super.initState();
    _paste.addListener(() => setState(() {}));
    closeOnLock();
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    await _read(picked.bytes);
  }

  Future<void> _read(Object input) async {
    if (_reading) return;
    setState(() {
      _reading = true;
      _error = null;
    });
    final messages = context.messages;
    try {
      // A secret key pasted by mistake comes back as its public part alone
      final key = await ref.read(pgpPublicKeyReaderProvider)(input);
      final person = personOfGivenKey(key, unnamed: messages.t('pgp.people.unnamed', {'id': shortKeyId(key.fingerprintHex)}));
      // To encrypt, the key must be usable now; a signature may be older than that
      final trouble = widget.forSigner ? null : await ref.read(pgpKeyTroubleProvider)(key.transferableKey, ref.read(clockProvider)());
      if (!mounted) return;
      if (trouble != null) {
        setState(() => _error = pgpErrorText(messages, trouble, name: person.name));
        return;
      }
      setState(() {
        _found = person;
        _foundUserId = key.userId;
      });
    } on pgp.PgpException catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error.problem) {
          pgp.PgpProblem.notAMessage => messages.t('pgp.people.error.notAKey'),
          pgp.PgpProblem.damaged || pgp.PgpProblem.tooLarge => messages.t('pgp.people.error.damaged'),
          _ => pgpErrorText(messages, error),
        },
      );
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(
          icon: const Icon(Icons.person_add_alt_1_outlined),
          title: context.t(
            found != null
                ? 'pgp.people.confirm.title'
                : widget.forSigner
                ? 'pgp.people.giveKey.title'
                : 'pgp.people.title',
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: found != null ? _confirmation(context, found) : _choices(context),
          ),
        ),
      ],
    );
  }

  Widget _choices(BuildContext context) {
    final p = context.palette;
    final own = [
      for (final person in ref.watch(pgpOwnPeopleProvider))
        if (!widget.exclude.contains(person.fingerprint)) person,
    ];
    // A contact whose key can't be encrypted to now is not offered as a
    // recipient; to check a signature, any of them will do
    final recipients = widget.forSigner ? null : {for (final recipient in ref.watch(contactRecipientsProvider)) recipient.contact.id};
    final contacts = [
      for (final person in ref.watch(pgpContactPeopleProvider))
        if (!widget.exclude.contains(person.fingerprint) && (recipients?.contains(person.contactId) ?? true)) person,
    ];
    Widget row(int i, PgpPerson person) => GroupRow(
      key: ValueKey('person:${person.fingerprint}'),
      first: i == 0,
      icon: person.isContact ? Text(contact_keys.contactInitials(person.name)) : const Text('PGP'),
      accent: person.isUsable,
      muted: !person.isUsable,
      primary: person.name,
      secondary: personLine(person),
      tag: person.standing.isOver ? StatusTag(label: context.t('keys.standing.${person.standing.name}'), tone: StatusTone.danger) : null,
      onTap: () => Navigator.of(context).pop(person),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (own.isNotEmpty)
          Group(label: context.t('pgp.people.yourKeys'), children: [for (final (i, person) in own.indexed) row(i, person)]),
        if (contacts.isNotEmpty)
          Group(label: context.t('vault.section.contacts'), children: [for (final (i, person) in contacts.indexed) row(i, person)]),
        const SizedBox(height: 16),
        if (_error != null) PgpErrorLine(_error!),
        if (_pasting) ...[
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _paste,
            minLines: 4,
            maxLines: 8,
            autocorrect: false,
            enableSuggestions: false,
            style: AppType.mono(fontSize: 12, color: p.text),
            decoration: InputDecoration(
              labelText: context.t('pgp.people.paste'),
              hintText: '-----BEGIN PGP PUBLIC KEY BLOCK-----',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _paste.text.trim().isEmpty || _reading ? null : () => unawaited(_read(_paste.text)),
            child: Text(context.t('pgp.people.read')),
          ),
        ] else
          OutlinedButton.icon(
            onPressed: () => setState(() => _pasting = true),
            icon: const Icon(Icons.content_paste_rounded),
            label: Text(context.t('pgp.people.paste')),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _reading ? null : () => unawaited(_pickFile()),
          icon: const Icon(Icons.folder_open_rounded),
          label: Text(context.t('pgp.people.chooseFile')),
        ),
      ],
    );
  }

  Widget _confirmation(BuildContext context, PgpPerson person) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _foundUserId.isEmpty ? person.name : _foundUserId,
                  style: AppType.body1.copyWith(fontWeight: FontWeight.w600, color: p.text),
                ),
                const SizedBox(height: 10),
                Text(context.t('pgp.people.fingerprint'), style: AppType.caption.copyWith(color: p.textSecondary)),
                const SizedBox(height: 2),
                SelectableText(groupedFingerprint(person.fingerprint), style: AppType.mono(fontSize: 13, color: p.text)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          context.t(widget.forSigner ? 'pgp.people.confirm.bodyForCheck' : 'pgp.people.confirm.body'),
          style: AppType.body2.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: largeButtonStyle,
          onPressed: () => Navigator.of(context).pop(person),
          child: Text(context.t(widget.forSigner ? 'pgp.people.useForCheck' : 'pgp.people.use')),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => setState(() {
            _found = null;
            _foundUserId = '';
          }),
          child: Text(context.t('pgp.people.back')),
        ),
      ],
    );
  }
}
