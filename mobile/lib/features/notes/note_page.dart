import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell_page.dart';
import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../features/sync/sync_merge.dart' show canonical;
import '../../i18n/messages.dart';
import '../../models/custom_field.dart';
import '../../models/json.dart';
import '../../models/secure_note.dart';
import '../../platform/files.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../../vault/attachment_seal.dart';
import '../../vault/attachment_store.dart';
import '../../vault/vault_controller.dart';
import '../accounts/tag_input.dart';
import '../fields/custom_fields_editor.dart';
import '../links/linked_items_section.dart';
import '../sends/new_send_sheet.dart';
import '../spaces/hidden_passwords.dart';
import '../sync/attachment_downloads.dart';
import '../sync/kemlock/km_kinds.dart';
import '../sync/space_picker.dart';
import '../sync/sync_store.dart';
import '../vault/owner_check.dart';
import 'note_files.dart';

/// The id in a note page's path that opens a new, empty note.
const newNoteId = 'new';

/// What to do with a note's unsaved changes on the way out.
enum _Leave { stay, discard, save }

/// A note, opened from the Vault tab: its title, its text, tags, pin and
/// attached files. A file is encrypted and stored as soon as it is
/// attached, and becomes part of the note when it is saved. Save adds or
/// updates the note; leaving with unsaved changes asks whether to save or
/// discard them. [noteId] is [newNoteId] for a new note.
class NotePage extends ConsumerStatefulWidget {
  const NotePage({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<NotePage> createState() => _NotePageState();
}

class _NotePageState extends ConsumerState<NotePage> {
  late final bool _isNew = widget.noteId == newNoteId;

  /// The note as it was saved; for a new note, an empty one with its id.
  late SecureNote _saved;

  /// The note isn't in the vault (deleted, or a link to another vault's).
  var _missing = false;

  final _title = TextEditingController();
  final _text = TextEditingController();
  var _tags = <String>[];
  var _pinned = false;
  String? _spaceId;
  var _titleError = false;
  var _saving = false;
  var _files = <NoteAttachment>[];
  var _attaching = false;

  /// The custom fields, as the editor last gave them.
  var _customFields = <CustomField>[];

  /// Which of the note's files this phone holds, by attachment id, once looked.
  final _stored = <String, bool>{};

  /// Files opened on this page, decrypted in memory only, by attachment id.
  final _decrypted = <String, Future<Uint8List>>{};
  final _images = <String, MemoryImage>{};

  @override
  void initState() {
    super.initState();
    final existing = ref.read(vaultControllerProvider).notes.firstWhereOrNull((note) => note.id == widget.noteId);
    if (existing == null && !_isNew) _missing = true;
    _saved = existing ?? SecureNote(id: newUuid(), title: '', addedAt: 0);
    _title.text = _saved.title;
    _text.text = _saved.text;
    _tags = [...?_saved.tags];
    _pinned = _saved.isPinned;
    _spaceId = _saved.spaceId;
    _files = [..._saved.files];
    _customFields = [..._saved.fields];
    unawaited(_lookForFiles());
    _title.addListener(_changed);
    _text.addListener(_changed);
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    // Decrypted pictures leave memory with the page, as when the vault locks
    for (final image in _images.values) {
      unawaited(image.evict());
    }
    _images.clear();
    _decrypted.clear();
    super.dispose();
  }

  void _changed() => setState(() {
    if (_title.text.trim().isNotEmpty) _titleError = false;
  });

  SecureNote get _draft => _saved.copyWith(
    title: _title.text.trim(),
    text: _text.text,
    tags: _tags.isEmpty ? unset : [..._tags],
    pinned: _pinned ? true : unset,
    spaceId: _spaceId ?? unset,
    attachments: _files.isEmpty && _saved.attachments == null ? unset : [..._files],
    fields: _customFields,
  );

  bool get _dirty => canonical(_draft.toJson()) != canonical(_saved.toJson());

  int get _over => _text.text.length - noteTextLimit;

  /// Saves the note; false when it can't be, and the form says why.
  Future<bool> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _titleError = true);
      return false;
    }
    if (_over > 0) return false;
    setState(() => _saving = true);
    final vault = ref.read(vaultControllerProvider.notifier);
    final draft = _draft;
    final saved = _isNew && !ref.read(vaultControllerProvider).notes.any((note) => note.id == draft.id)
        ? await vault.addNote(draft)
        : await vault.updateNote(draft);
    if (!mounted) return saved;
    setState(() {
      _saving = false;
      if (saved) _saved = ref.read(vaultControllerProvider).notes.firstWhereOrNull((note) => note.id == draft.id) ?? draft;
    });
    return saved;
  }

  void _error(String id, [Map<String, Object?> args = const {}]) =>
      ref.read(toastsProvider.notifier).show(context.t(id, args), severity: ToastSeverity.error);

  /// Picks a file from [source], encrypts and stores it, and adds it to the
  /// draft. A file over the limits is refused with a message that states
  /// them, and a failed write leaves the note as it was.
  Future<void> _attach(AttachSource source) async {
    if (_files.length >= attachmentsPerNote) return _error('notes.attach.full', {'count': attachmentsPerNote});
    final files = ref.read(fileServiceProvider);
    final picked = await switch (source) {
      AttachSource.file => files.pickFile(),
      AttachSource.photo => files.pickImage(),
      AttachSource.camera => files.takePhoto(),
    };
    if (picked == null || !mounted) return;
    if (picked.bytes.length > attachmentSizeLimit) return _error('notes.attach.tooLarge', {'size': attachmentSizeLimit ~/ (1024 * 1024)});
    final vaultId = ref.read(vaultControllerProvider).vault.id;
    final now = ref.read(clockProvider)().millisecondsSinceEpoch;
    final NoteAttachment file;
    setState(() => _attaching = true);
    try {
      // Sealed as a File item's file is, so the entry carries the SHA-256 the duplicate finder reads
      final sealed = await sealAttachment(picked.bytes, name: picked.name, type: picked.mimeType, now: now);
      await ref.read(attachmentStoreProvider).writeSealed(vaultId, sealed.entry.id, sealed.sealed);
      file = sealed.entry;
    } catch (_) {
      if (mounted) _error('notes.attach.failed');
      return;
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
    if (!mounted) return;
    setState(() => _files = [..._files, file]);
  }

  Future<void> _lookForFiles() async {
    final store = ref.read(attachmentStoreProvider);
    final vaultId = ref.read(vaultControllerProvider).vault.id;
    for (final file in _files) {
      final here = await store.exists(vaultId, file.id);
      if (!mounted) return;
      setState(() => _stored[file.id] = here);
    }
  }

  /// How [file] stands: on this phone, being fetched, waiting, or missing.
  AttachmentStatus _status(NoteAttachment file) {
    final download = ref.watch(attachmentDownloadsProvider)[file.id];
    if (download != null) return download;
    return _stored[file.id] == false ? AttachmentStatus.missing : AttachmentStatus.here;
  }

  Future<Uint8List> _plain(NoteAttachment file) =>
      _decrypted[file.id] ??= ref.read(attachmentStoreProvider).read(ref.read(vaultControllerProvider).vault.id, file.id, unb64(file.key));

  /// [file]'s picture, decrypted in memory, once it opens.
  Future<MemoryImage> _image(NoteAttachment file) async {
    final bytes = await _plain(file);
    return _images[file.id] ??= MemoryImage(bytes);
  }

  void _open(NoteAttachment file) {
    switch (_status(file)) {
      case AttachmentStatus.here:
        break;
      case AttachmentStatus.fetching:
        return;
      case AttachmentStatus.waiting || AttachmentStatus.missing:
        // Fetched now if a sync folder has it; otherwise there's nothing to open
        if (!ref.read(attachmentDownloadsProvider.notifier).fetchNow(file.id)) _error('notes.file.missing');
        return;
    }
    if (!isPicture(file)) {
      unawaited(_fileActions(file));
      return;
    }
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (context, _, _) => PictureViewer(
            name: file.name,
            image: _image(file),
            actions: [
              IconButton(
                onPressed: () => unawaited(_copyOut(file, share: false, from: context)),
                tooltip: context.t('notes.copy.save'),
                color: Colors.white,
                icon: const Icon(Icons.download_rounded),
              ),
              IconButton(
                onPressed: () => unawaited(_copyOut(file, share: true, from: context)),
                tooltip: context.t('notes.copy.share'),
                color: Colors.white,
                icon: const Icon(Icons.ios_share_rounded),
              ),
              IconButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _remove(file);
                },
                tooltip: context.t('notes.file.remove'),
                color: Colors.white,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
        ),
      ),
    );
  }

  /// What can be done with a file that isn't a picture.
  Future<void> _fileActions(NoteAttachment file) => showAppBottomSheet<void>(
    context,
    label: file.name,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: Icon(fileIcon(file)), title: file.name),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Group(
            children: [
              GroupRow(
                first: true,
                icon: const Icon(Icons.download_rounded),
                primary: sheet.t('notes.copy.save'),
                secondary: fileSizeText(sheet, file.size),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_copyOut(file, share: false));
                },
              ),
              GroupRow(
                icon: const Icon(Icons.ios_share_rounded),
                primary: sheet.t('notes.copy.share'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_copyOut(file, share: true));
                },
              ),
              GroupRow(
                icon: const Icon(Icons.delete_outline_rounded),
                primary: sheet.t('notes.file.remove'),
                danger: true,
                onTap: () {
                  Navigator.of(sheet).pop();
                  _remove(file);
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// Takes [file] off the draft, with Undo in the toast. The stored file
  /// stays until the sweep at unlock finds it named by no note.
  void _remove(NoteAttachment file) {
    final index = _files.indexWhere((other) => other.id == file.id);
    if (index < 0) return;
    setState(() => _files = [..._files]..removeAt(index));
    ref
        .read(toastsProvider.notifier)
        .show(
          context.t('notes.file.removed', {'name': file.name}),
          actionLabel: context.t('app.undo'),
          onAction: () {
            if (!mounted || _files.any((other) => other.id == file.id)) return;
            setState(() => _files = [..._files]..insert(index.clamp(0, _files.length), file));
          },
        );
  }

  /// Saves or shares a copy of [file] under its own name, once the person
  /// has read that the copy isn't encrypted. [from] is where the question
  /// is asked, when not on this page.
  Future<void> _copyOut(NoteAttachment file, {required bool share, BuildContext? from}) async {
    final asker = from ?? context;
    final confirmed = await showConfirmDialog(
      asker,
      icon: const Icon(Icons.lock_open_rounded),
      title: asker.t('notes.copy.title'),
      body: Text(asker.t('notes.copy.body', {'name': file.name})),
      confirmLabel: asker.t(share ? 'notes.copy.share' : 'notes.copy.save'),
      cancelLabel: asker.t('export.cancel'),
      danger: false,
    );
    if (!confirmed || !mounted) return;
    final Uint8List bytes;
    try {
      bytes = await _plain(file);
    } on AttachmentMissingError {
      return _error('notes.file.missing');
    } catch (_) {
      _decrypted.remove(file.id)?.ignore();
      return _error('notes.file.damaged');
    }
    final files = ref.read(fileServiceProvider);
    final type = file.type ?? 'application/octet-stream';
    if (share) {
      await files.shareFile(file.name, bytes, mimeType: type);
      return;
    }
    final result = await files.saveFile(file.name, bytes, mimeType: type);
    if (result is Saved && mounted) ref.read(toastsProvider.notifier).show(context.t('notes.copy.saved', {'location': result.location}));
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/vault');
    }
  }

  Future<void> _saveAndClose() async {
    if (await _save() && mounted) _close();
  }

  Future<void> _leave() async {
    if (!_dirty) return _close();
    final choice = await showAppDialog<_Leave>(context, builder: (_) => const _UnsavedDialog());
    if (!mounted) return;
    switch (choice) {
      case _Leave.save:
        await _saveAndClose();
      case _Leave.discard:
        setState(() => _saved = _draft);
        _close();
      case _Leave.stay || null:
        break;
    }
  }

  Future<void> _delete() async {
    final note = ref.read(vaultControllerProvider).notes.firstWhereOrNull((note) => note.id == _saved.id);
    if (note == null) return;
    await ref.read(vaultControllerProvider.notifier).deleteNote(note);
    if (mounted) _close();
  }

  /// Starts a text Send of the note's text, named after the note, once the owner has shown it is them: the text
  /// leaves the vault. The Send is a copy, not linked to the note. A note's files aren't offered.
  Future<void> _send() async {
    final title = _title.text.trim().isEmpty ? _saved.title : _title.text.trim();
    final text = _text.text;
    final reason = context.t('sends.fromItem.reason');
    if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) return;
    unawaited(showNewSendSheet(context, text: text, name: title));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final padding = ShellPage.padding(context);
    final allTags = {for (final note in ref.watch(vaultControllerProvider.select((state) => state.notes))) ...?note.tags}.toList()..sort();
    final hasSpaces = ref.watch(syncProvider.select((sync) => sync.settings?.spaces.isNotEmpty ?? false));
    final stored = !_isNew || ref.watch(vaultControllerProvider.select((state) => state.notes.any((note) => note.id == _saved.id)));
    // The vault's copy of the note, which holds the links made since this page opened
    final held = ref.watch(vaultControllerProvider.select((state) => state.notes.firstWhereOrNull((n) => n.id == _saved.id))) ?? _saved;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: p.background,
        body: _missing
            ? Padding(
                padding: padding.copyWith(bottom: 24),
                child: Column(
                  children: [
                    _Header(title: context.t('notes.title'), onBack: _close),
                    EmptyState(icon: const Icon(Icons.search_off_rounded), title: context.t('notes.missing')),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The header stays put, so Save is at hand however long the note is
                  Padding(
                    padding: EdgeInsets.fromLTRB(padding.left, padding.top, padding.right, 8),
                    child: _Header(
                      title: context.t(_isNew && !stored ? 'notes.new' : 'notes.title'),
                      onBack: () => unawaited(_leave()),
                      action: FilledButton(
                        onPressed: _saving || (!_dirty && stored) ? null : () => unawaited(_saveAndClose()),
                        child: Text(context.t('notes.save')),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(padding.left, 16, padding.right, MediaQuery.paddingOf(context).bottom + 32),
                      children: [
                        // A note holds what the vault keeps secret: the keyboard neither suggests nor corrects it
                        TextField(
                          enableIMEPersonalizedLearning: false,
                          autocorrect: false,
                          enableSuggestions: false,
                          controller: _title,
                          autofocus: _isNew,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.next,
                          style: AppType.h5.copyWith(color: p.text),
                          decoration: InputDecoration(
                            labelText: context.t('notes.field.title'),
                            errorText: _titleError ? context.t('notes.error.title') : null,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          enableIMEPersonalizedLearning: false,
                          autocorrect: false,
                          enableSuggestions: false,
                          controller: _text,
                          minLines: 8,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(
                            labelText: context.t('notes.field.text'),
                            alignLabelWithHint: true,
                            errorText: _over > 0 ? context.t('notes.error.tooLong', {'count': _over, 'limit': noteTextLimit}) : null,
                            errorMaxLines: 3,
                          ),
                        ),
                        const SizedBox(height: 20),
                        CustomFieldsEditor(
                          kind: itemKindOf(_saved),
                          fields: _customFields,
                          onChanged: (next) => setState(() => _customFields = next),
                          hideSecrets: hidesSecretsOf(ref, _saved),
                        ),
                        const SizedBox(height: 20),
                        TagInput(value: _tags, onChanged: (tags) => setState(() => _tags = tags), suggestions: allTags),
                        // Shared with a space's members, files and all, as an account is
                        if (hasSpaces || _spaceId != null) ...[
                          const SizedBox(height: 14),
                          SpacePicker(value: _spaceId, onChanged: (id) => setState(() => _spaceId = id)),
                        ],
                        NoteFiles(
                          files: _files,
                          busy: _attaching,
                          onAttach: (source) => unawaited(_attach(source)),
                          onOpen: _open,
                          status: _status,
                          offline: ref.watch(offlineProvider),
                          preview: (file, size) => PictureThumb(image: _image(file), size: size),
                        ),
                        if (stored) LinkedItemsSection(entry: held),
                        const SizedBox(height: 8),
                        const SizedBox(height: 8),
                        Group(
                          children: [
                            GroupRow(
                              first: true,
                              icon: const Icon(Icons.push_pin_outlined),
                              primary: context.t('notes.pin'),
                              control: AppSwitch(value: _pinned, onChanged: (pinned) => setState(() => _pinned = pinned)),
                            ),
                            if (stored && _text.text.isNotEmpty)
                              GroupRow(
                                icon: const Icon(Icons.send_rounded),
                                primary: context.t('sends.fromItem.note'),
                                onTap: () => unawaited(_send()),
                              ),
                            if (stored)
                              GroupRow(
                                icon: const Icon(Icons.delete_outline_rounded),
                                primary: context.t('notes.delete'),
                                danger: true,
                                onTap: () => unawaited(_delete()),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The page's top row: back, the title, and the page's action.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onBack, this.action});

  final String title;
  final VoidCallback onBack;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ScreenHeader(title: title, onBack: onBack, backLabel: context.t('nav.back')),
      ),
      if (action != null) ...[const SizedBox(width: 8), action!],
    ],
  );
}

/// Asks what to do with a note's unsaved changes.
class _UnsavedDialog extends StatelessWidget {
  const _UnsavedDialog();

  @override
  Widget build(BuildContext context) => AppDialog(
    semanticLabel: context.t('notes.unsaved.title'),
    heading: DialogHeading(title: context.t('notes.unsaved.title')),
    content: Text(context.t('notes.unsaved.body')),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(_Leave.stay), child: Text(context.t('notes.unsaved.stay'))),
      TextButton(onPressed: () => Navigator.of(context).pop(_Leave.discard), child: Text(context.t('notes.unsaved.discard'))),
      FilledButton(onPressed: () => Navigator.of(context).pop(_Leave.save), child: Text(context.t('notes.save'))),
    ],
  );
}
