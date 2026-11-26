import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../crypto/bytes.dart';
import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../models/vault_file.dart';
import '../../platform/files.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../../vault/attachment_store.dart';
import '../../vault/vault_controller.dart';
import '../links/linked_items_section.dart';
import '../notes/note_files.dart';
import '../sync/attachment_downloads.dart';
import 'file_added.dart';
import 'file_edit_sheet.dart';
import 'file_size.dart';

/// Opens a File item from the Vault tab.
Future<void> showFileSheet(BuildContext context, VaultFile file) => showAppBottomSheet<void>(
  context,
  label: file.name,
  builder: (_) => FileSheet(fileId: file.id),
);

/// A File item: its name, size, type and the day it was added, its notes, and what can be done with the file: open it when it is a
/// picture, share it or save a copy to the phone, once the person has read that the copy isn't encrypted. A file this phone doesn't
/// hold yet is fetched when it is opened, if a sync folder has it. Edit changes the name, notes and favourite or replaces the file;
/// Delete has Undo in the toast, and the stored file goes with the sweep at unlock, as a removed note attachment's does.
class FileSheet extends ConsumerStatefulWidget {
  const FileSheet({super.key, required this.fileId});

  final String fileId;

  @override
  ConsumerState<FileSheet> createState() => _FileSheetState();
}

class _FileSheetState extends ConsumerState<FileSheet> {
  /// Whether this phone holds the file, by attachment id, once looked.
  final _stored = <String, bool>{};
  final _asked = <String>{};

  /// The file opened, decrypted in memory only, by attachment id.
  final _decrypted = <String, Future<Uint8List>>{};
  final _images = <String, MemoryImage>{};

  @override
  void initState() {
    super.initState();
    final item = _item;
    if (item != null) unawaited(_look(item.file));
  }

  @override
  void dispose() {
    for (final image in _images.values) {
      unawaited(image.evict());
    }
    _images.clear();
    _decrypted.clear();
    super.dispose();
  }

  VaultFile? get _item => ref.read(vaultControllerProvider).files.firstWhereOrNull((item) => item.id == widget.fileId);

  Future<void> _look(NoteAttachment file) async {
    if (!_asked.add(file.id)) return;
    final here = await ref.read(attachmentStoreProvider).exists(ref.read(vaultControllerProvider).vault.id, file.id);
    if (mounted) setState(() => _stored[file.id] = here);
  }

  /// How [file] stands: on this phone, being fetched, waiting, or missing.
  AttachmentStatus _status(NoteAttachment file, Map<String, AttachmentStatus> downloads) {
    final download = downloads[file.id];
    if (download != null) return download;
    return _stored[file.id] == false ? AttachmentStatus.missing : AttachmentStatus.here;
  }

  void _error(String id) => ref.read(toastsProvider.notifier).show(context.t(id), severity: ToastSeverity.error);

  Future<Uint8List> _plain(NoteAttachment file) =>
      _decrypted[file.id] ??= ref.read(attachmentStoreProvider).read(ref.read(vaultControllerProvider).vault.id, file.id, unb64(file.key));

  Future<MemoryImage> _image(NoteAttachment file) async {
    final bytes = await _plain(file);
    return _images[file.id] ??= MemoryImage(bytes);
  }

  /// Whether the file can be used now; when it can't, says why, and asks for it when a sync folder may have it.
  bool _ready(NoteAttachment file) {
    switch (_status(file, ref.read(attachmentDownloadsProvider))) {
      case AttachmentStatus.here:
        return true;
      case AttachmentStatus.fetching:
        return false;
      case AttachmentStatus.waiting || AttachmentStatus.missing:
        if (!ref.read(attachmentDownloadsProvider.notifier).fetchNow(file.id)) _error('notes.file.missing');
        return false;
    }
  }

  void _open(NoteAttachment file) {
    if (!_ready(file)) return;
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
            ],
          ),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
        ),
      ),
    );
  }

  /// Saves or shares a copy of [file] under its own name, once the person has read that the copy isn't encrypted.
  Future<void> _copyOut(NoteAttachment file, {required bool share, BuildContext? from}) async {
    if (!_ready(file)) return;
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

  Future<void> _delete(VaultFile item) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('files.delete.title'),
      body: Text(context.t('files.delete.body', {'name': item.name})),
      confirmLabel: context.t('files.delete.confirm'),
      cancelLabel: context.t('files.cancel'),
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(vaultControllerProvider.notifier).deleteFile(item);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final item = ref.watch(vaultControllerProvider.select((state) => state.files.firstWhereOrNull((f) => f.id == widget.fileId)));
    if (item == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(context.t('files.missing'), style: AppType.body1.copyWith(color: p.textSecondary)),
      );
    }
    final file = item.file;
    unawaited(_look(file));
    final locale = Localizations.localeOf(context).toLanguageTag();
    final status = _status(file, ref.watch(attachmentDownloadsProvider));
    final offline = ref.watch(offlineProvider);
    final picture = isPicture(file);
    final notes = item.notes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: Icon(fileIcon(file)), title: item.name),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Group(
                  key: const ValueKey('file-facts'),
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.insert_drive_file_outlined),
                      primary: context.t('files.field.fileName'),
                      secondary: file.name,
                    ),
                    GroupRow(
                      icon: const Icon(Icons.straighten_rounded),
                      primary: context.t('files.field.size'),
                      secondary: switch (status) {
                        AttachmentStatus.here => fileSizeText(context, file.size),
                        AttachmentStatus.fetching => context.t('notes.file.fetching'),
                        AttachmentStatus.waiting => context.t(offline ? 'notes.file.offline' : 'notes.file.waiting'),
                        AttachmentStatus.missing => context.t('notes.file.notHere'),
                      },
                    ),
                    if (file.type case final type? when type.isNotEmpty)
                      GroupRow(icon: const Icon(Icons.category_outlined), primary: context.t('files.field.type'), secondary: type),
                    GroupRow(
                      icon: const Icon(Icons.event_outlined),
                      primary: context.t('files.field.added'),
                      secondary: fileDateText(fileAddedAt(item), locale),
                    ),
                  ],
                ),
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionLabel(context.t('files.field.notes')),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
                    child: Text(notes, style: AppType.body2.copyWith(color: p.text)),
                  ),
                ],
                const SizedBox(height: 16),
                Group(
                  key: const ValueKey('file-actions'),
                  children: [
                    if (picture)
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.open_in_full_rounded),
                        primary: context.t('files.open'),
                        onTap: () => _open(file),
                      ),
                    GroupRow(
                      first: !picture,
                      icon: const Icon(Icons.ios_share_rounded),
                      primary: context.t('notes.copy.share'),
                      onTap: () => unawaited(_copyOut(file, share: true)),
                    ),
                    GroupRow(
                      icon: const Icon(Icons.download_rounded),
                      primary: context.t('files.save'),
                      onTap: () => unawaited(_copyOut(file, share: false)),
                    ),
                  ],
                ),
                // custom fields: none for files
                LinkedItemsSection(entry: item),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: largeButtonStyle,
                  onPressed: () => unawaited(showFileEditSheet(context, item)),
                  child: Text(context.t('files.edit')),
                ),
                const SizedBox(height: 8),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      icon: const Icon(Icons.delete_outline_rounded),
                      primary: context.t('files.delete'),
                      danger: true,
                      onTap: () => unawaited(_delete(item)),
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
