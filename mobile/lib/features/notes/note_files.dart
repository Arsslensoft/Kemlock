import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../ui/ui.dart';
import '../sync/attachment_downloads.dart';

/// Where an attached file comes from.
enum AttachSource {
  file('notes.attach.file', Icons.description_outlined),
  photo('notes.attach.photo', Icons.photo_library_outlined),
  camera('notes.attach.camera', Icons.photo_camera_outlined);

  const AttachSource(this.labelId, this.icon);

  final String labelId;
  final IconData icon;
}

/// [bytes] as the note lists a file's size: bytes, KB or MB, one decimal.
String fileSizeText(BuildContext context, int bytes) {
  if (bytes < 1024) return context.t('notes.file.bytes', {'count': bytes});
  if (bytes < 1024 * 1024) return context.t('notes.file.kb', {'size': (bytes / 1024 * 10).round() / 10});
  return context.t('notes.file.mb', {'size': (bytes / (1024 * 1024) * 10).round() / 10});
}

/// Whether the note shows [file] as a picture.
bool isPicture(NoteAttachment file) {
  final type = file.type ?? '';
  if (type.startsWith('image/')) return const {'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp'}.contains(type);
  final name = file.name.toLowerCase();
  return const ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'].any(name.endsWith);
}

/// The icon a file is listed with.
IconData fileIcon(NoteAttachment file) {
  final type = file.type ?? '';
  final name = file.name.toLowerCase();
  if (isPicture(file)) return Icons.image_outlined;
  if (type == 'application/pdf' || name.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
  if (type.startsWith('text/') || name.endsWith('.txt')) return Icons.article_outlined;
  return Icons.insert_drive_file_outlined;
}

/// The note's files: a row per file and the Attach button, whose menu picks
/// a file, a photo or the camera.
class NoteFiles extends StatelessWidget {
  const NoteFiles({
    super.key,
    required this.files,
    required this.busy,
    required this.onAttach,
    this.onOpen,
    this.preview,
    this.status,
    this.offline = false,
  });

  final List<NoteAttachment> files;

  /// A file is being encrypted and stored.
  final bool busy;
  final ValueChanged<AttachSource> onAttach;
  final ValueChanged<NoteAttachment>? onOpen;

  /// A picture, decrypted, at [size]: shown above the list and in its row.
  final Widget Function(NoteAttachment file, double size)? preview;

  /// How each file stands on this phone; all here without it.
  final AttachmentStatus Function(NoteAttachment file)? status;

  /// Whether offline mode is on, which is then why a file still waits.
  final bool offline;

  bool _here(NoteAttachment file) => (status?.call(file) ?? AttachmentStatus.here) == AttachmentStatus.here;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(context.t('notes.files', {'count': files.length})),
        if (preview != null && files.any((file) => isPicture(file) && _here(file))) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final file in files.where((file) => isPicture(file) && _here(file)))
                Semantics(
                  button: true,
                  label: file.name,
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: ValueKey('picture:${file.id}'),
                    onTap: onOpen == null ? null : () => onOpen!(file),
                    child: preview!(file, 104),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (files.isNotEmpty)
          Group(
            children: [
              for (final (i, file) in files.indexed)
                GroupRow(
                  key: ValueKey(file.id),
                  first: i == 0,
                  icon: preview != null && isPicture(file) && _here(file) ? preview!(file, 32) : Icon(fileIcon(file)),
                  primary: file.name,
                  secondary: switch (status?.call(file) ?? AttachmentStatus.here) {
                    AttachmentStatus.here => fileSizeText(context, file.size),
                    AttachmentStatus.fetching => context.t('notes.file.fetching'),
                    AttachmentStatus.waiting => context.t(offline ? 'notes.file.offline' : 'notes.file.waiting'),
                    AttachmentStatus.missing => context.t('notes.file.notHere'),
                  },
                  onTap: onOpen == null ? null : () => onOpen!(file),
                ),
            ],
          ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: MenuAnchor(
            menuChildren: [
              for (final source in AttachSource.values)
                MenuItemButton(
                  leadingIcon: Icon(source.icon, color: p.textSecondary),
                  onPressed: () => onAttach(source),
                  child: Text(context.t(source.labelId)),
                ),
            ],
            builder: (context, controller, _) => OutlinedButton.icon(
              onPressed: busy || files.length >= attachmentsPerNote
                  ? null
                  : () => controller.isOpen ? controller.close() : controller.open(),
              icon: busy ? const Spinner(size: 16) : const Icon(Icons.attach_file_rounded),
              label: Text(context.t(busy ? 'notes.attach.busy' : 'notes.attach')),
            ),
          ),
        ),
        if (files.length >= attachmentsPerNote) ...[
          const SizedBox(height: 6),
          Text(context.t('notes.attach.full', {'count': attachmentsPerNote}), style: AppType.caption.copyWith(color: p.textSecondary)),
        ],
      ],
    );
  }
}

/// A picture shown small, once it is decrypted: a spinner until then, and
/// a broken picture when it doesn't open.
class PictureThumb extends StatelessWidget {
  const PictureThumb({super.key, required this.image, this.size = 32});

  final Future<MemoryImage> image;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: FutureBuilder(
      future: image,
      builder: (context, snapshot) => switch (snapshot) {
        AsyncSnapshot(:final MemoryImage data) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image(image: data, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
        ),
        AsyncSnapshot(hasError: true) => const Icon(Icons.broken_image_outlined),
        _ => const Padding(padding: EdgeInsets.all(8), child: Spinner()),
      },
    ),
  );
}

/// An attached picture full screen, to pinch and pan, over a dark backdrop.
/// [actions] sit beside the close button.
class PictureViewer extends StatelessWidget {
  const PictureViewer({super.key, required this.name, required this.image, this.actions = const []});

  final String name;
  final Future<MemoryImage> image;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: name,
      explicitChildNodes: true,
      child: Material(
        color: Colors.black.withValues(alpha: .94),
        child: Stack(
          children: [
            Positioned.fill(
              child: FutureBuilder(
                future: image,
                builder: (context, snapshot) => switch (snapshot) {
                  AsyncSnapshot(:final MemoryImage data) => InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      child: Image(
                        image: data,
                        semanticLabel: name,
                        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48),
                      ),
                    ),
                  ),
                  AsyncSnapshot(hasError: true) => Center(
                    child: Text(context.t('notes.file.damaged'), style: AppType.body1.copyWith(color: Colors.white70)),
                  ),
                  _ => const Center(child: Spinner(size: 32, color: Colors.white70)),
                },
              ),
            ),
            Positioned(
              top: safe.top + 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: context.t('notes.file.close'),
                    color: Colors.white,
                    icon: const Icon(Icons.close_rounded),
                  ),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body1.copyWith(color: Colors.white),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
