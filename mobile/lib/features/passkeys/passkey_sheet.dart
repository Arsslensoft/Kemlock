import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../i18n/messages.dart';
import '../../models/json.dart';
import '../../models/passkey.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/tag_input.dart';
import '../links/linked_items_section.dart';

/// Opens a passkey from the Vault tab.
Future<void> showPasskeySheet(BuildContext context, Passkey passkey) => showAppBottomSheet<void>(
  context,
  label: passkey.displayName,
  builder: (_) => PasskeySheet(passkeyId: passkey.id),
);

/// A passkey: the site and account it signs in to and when it was made,
/// which can't change, and a label, note and tags that can. Its key is
/// never shown, and nothing here offers it. Deleting it warns first, and
/// the toast that follows has Undo.
class PasskeySheet extends ConsumerStatefulWidget {
  const PasskeySheet({super.key, required this.passkeyId});

  final String passkeyId;

  @override
  ConsumerState<PasskeySheet> createState() => _PasskeySheetState();
}

class _PasskeySheetState extends ConsumerState<PasskeySheet> {
  late final Passkey? _initial = ref.read(vaultControllerProvider).passkeys.firstWhereOrNull((p) => p.id == widget.passkeyId);
  late final _label = TextEditingController(text: _initial?.label ?? '');
  late final _note = TextEditingController(text: _initial?.note ?? '');
  late var _tags = <String>[...?_initial?.tags];

  @override
  void initState() {
    super.initState();
    _label.addListener(() => setState(() {}));
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  Passkey _edited(Passkey passkey) {
    final label = _label.text.trim();
    final note = _note.text.trim();
    return passkey.copyWith(
      label: label.isEmpty ? unset : label,
      note: note.isEmpty ? unset : note,
      tags: _tags.isEmpty ? unset : [..._tags],
    );
  }

  Future<void> _save(Passkey passkey) async {
    if (await ref.read(vaultControllerProvider.notifier).updatePasskey(_edited(passkey)) && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete(Passkey passkey) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('passkeys.delete.title'),
      body: Text(context.t('passkeys.delete.body', {'site': passkey.rpId})),
      confirmLabel: context.t('passkeys.delete.confirm'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deletePasskey(passkey);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final passkey = ref.watch(vaultControllerProvider.select((state) => state.passkeys.firstWhereOrNull((p) => p.id == widget.passkeyId)));
    if (passkey == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('passkeys.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final locale = Localizations.localeOf(context).toLanguageTag();
    final changed = _edited(passkey) != passkey;
    final allTags = {for (final other in ref.watch(vaultControllerProvider.select((state) => state.passkeys))) ...?other.tags}.toList()
      ..sort();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.fingerprint_rounded), title: passkey.displayName),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.language_rounded),
                      primary: context.t('passkeys.site'),
                      value: Text(passkey.rpName == null ? passkey.rpId : '${passkey.rpName} · ${passkey.rpId}'),
                    ),
                    GroupRow(
                      icon: const Icon(Icons.person_outline_rounded),
                      primary: context.t('passkeys.user'),
                      value: Text(passkey.userName),
                    ),
                    if (passkey.userDisplayName case final name? when name.isNotEmpty)
                      GroupRow(icon: const Icon(Icons.badge_outlined), primary: context.t('passkeys.displayName'), value: Text(name)),
                    GroupRow(
                      icon: const Icon(Icons.event_outlined),
                      primary: context.t('passkeys.created'),
                      value: Text(DateFormat.yMMMd(locale).format(DateTime.fromMillisecondsSinceEpoch(passkey.addedAt))),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(context.t('passkeys.keyHidden'), style: AppType.caption.copyWith(color: p.textSecondary)),
                const SizedBox(height: 18),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('passkeys.label'), hintText: passkey.rpName ?? passkey.rpId),
                ),
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
                TagInput(value: _tags, onChanged: (tags) => setState(() => _tags = tags), suggestions: allTags),
                LinkedItemsSection(entry: passkey),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t('passkeys.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(passkey)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: changed ? () => unawaited(_save(passkey)) : null,
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
