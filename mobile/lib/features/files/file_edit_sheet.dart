import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/json.dart';
import '../../models/vault_file.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../notes/note_files.dart';
import '../sync/space_picker.dart';
import '../sync/sync_merge.dart' show canonical;
import 'new_file.dart';

/// Opens the sheet that edits [file]: its name, notes, favourite and space, and the file itself, which can be replaced.
Future<void> showFileEditSheet(BuildContext context, VaultFile file) => showAppBottomSheet<void>(
  context,
  label: context.t('files.edit.title'),
  builder: (_) => FileEditSheet(file: file),
);

/// A File item's fields. The name needs to be filled; a replaced file is encrypted and stored as soon as it is chosen, and becomes the
/// item's file when it is saved. While the name is still the old file's, it follows the new one.
class FileEditSheet extends ConsumerStatefulWidget {
  const FileEditSheet({super.key, required this.file});

  final VaultFile file;

  @override
  ConsumerState<FileEditSheet> createState() => _FileEditSheetState();
}

class _FileEditSheetState extends ConsumerState<FileEditSheet> {
  late final _name = TextEditingController(text: widget.file.name);
  late final _notes = TextEditingController(text: widget.file.notes ?? '');
  late var _favorite = widget.file.favorite == true;
  late String? _spaceId = widget.file.spaceId;
  late var _entry = widget.file.file;
  var _busy = false;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _notes.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  VaultFile get _draft {
    final notes = _notes.text.trim();
    final edited = widget.file.copyWith(
      name: _name.text.trim(),
      notes: notes.isEmpty ? unset : notes,
      favorite: _favorite ? true : unset,
      file: _entry,
    );
    return (_spaceId ?? '') == (widget.file.spaceId ?? '') ? edited : edited.inSpace(_spaceId);
  }

  bool get _changed => canonical(_draft.toJson()) != canonical(widget.file.toJson());

  Future<void> _replace() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final picked = await ref.read(fileServiceProvider).pickFile();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    final entry = await sealAndStoreFile(container, picked);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (entry != null) {
        // The name follows the file until the person has typed one of their own
        final current = _name.text.trim();
        if (current.isEmpty || current == _entry.name || current == widget.file.name) _name.text = entry.name;
        _entry = entry;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final saved = await ref.read(vaultControllerProvider.notifier).updateFile(_draft);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final named = _name.text.trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: Icon(fileIcon(_entry)), title: context.t('files.edit.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('files.field.name')),
                ),
                Group(
                  children: [
                    GroupRow(
                      key: const ValueKey('file-current'),
                      first: true,
                      icon: _busy ? const Spinner(size: 20) : Icon(fileIcon(_entry)),
                      primary: _entry.name,
                      secondary: fileSizeText(context, _entry.size),
                      control: TextButton(
                        onPressed: _busy ? null : () => unawaited(_replace()),
                        child: Text(context.t(_busy ? 'notes.attach.busy' : 'files.replace')),
                      ),
                    ),
                  ],
                ),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _notes,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: context.t('files.field.notes'), alignLabelWithHint: true),
                ),
                // custom fields: none for files
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.star_outline_rounded),
                      primary: context.t('files.favorite'),
                      control: AppSwitch(value: _favorite, onChanged: (value) => setState(() => _favorite = value)),
                    ),
                  ],
                ),
                SpacePicker(value: _spaceId, onChanged: (id) => setState(() => _spaceId = id)),
                if (!named) Text(context.t('files.error.name'), style: AppType.caption.copyWith(color: p.textSecondary)),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: named && !_busy && !_saving && _changed ? () => unawaited(_save()) : null,
                  child: Text(context.t('files.save.button')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
