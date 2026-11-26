import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../i18n/messages.dart';
import '../../models/contact.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'contact_person.dart';

/// Opens the sheet that adds a person with no key.
Future<void> showAddPersonSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('contacts.person.add'), builder: (_) => const AddPersonSheet());

/// "Add a person": a name, and company, email, phone, address and a note, all optional but the name. No key is needed: the contact is
/// saved as typed in (`manual`), and a key can be added to it later from its sheet.
class AddPersonSheet extends ConsumerStatefulWidget {
  const AddPersonSheet({super.key});

  @override
  ConsumerState<AddPersonSheet> createState() => _AddPersonSheetState();
}

class _AddPersonSheetState extends ConsumerState<AddPersonSheet> {
  final _name = TextEditingController();
  final _note = TextEditingController();
  final _person = PersonFields();
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _person.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final note = _note.text.trim();
    final contact = _person.applyTo(
      Contact(id: newUuid(), name: _name.text.trim(), source: ContactSource.manual, note: note.isEmpty ? null : note, addedAt: 0),
    );
    final saved = await ref.read(vaultControllerProvider.notifier).addContact(contact);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.person_add_alt_1_outlined), title: context.t('contacts.person.add')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Text(context.t('contacts.person.add.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: context.t('keys.field.name')),
                ),
                _person.form(context),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('passkeys.note'), alignLabelWithHint: true),
                ),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _name.text.trim().isEmpty || _saving ? null : () => unawaited(_save()),
                  child: Text(context.t('contacts.person.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
