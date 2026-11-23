import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../ui/ui.dart';
import 'code_import.dart';
import 'code_readers.dart';

/// Where the person picks the file to read codes from.
enum CodeSource { photos, camera, file }

/// The files the file picker offers: pictures, PDFs and text files.
const codeFileExtensions = ['png', 'jpg', 'jpeg', 'heic', 'heif', 'webp', 'gif', 'bmp', 'pdf', 'txt', 'csv', 'md'];

/// The text files every build reads codes from.
const codeTextExtensions = ['txt', 'csv', 'md'];

/// Reads backup codes from a screenshot, a photo, a PDF or a text file
/// `CodeImportButton.tsx`. The button offers the photo library, the camera
/// or a file, as the phone's own menu did in front of the web app's file
/// input. A bar runs while the file is read, and a warning says when it
/// held no codes or couldn't be read.
///
/// A build that reads neither pictures nor PDFs, the free build, opens the file picker
/// straight away, held to text files, and says why under the button (openspec:
/// add-fdroid-release, design decision 4).
class CodeImportButton extends ConsumerStatefulWidget {
  const CodeImportButton({super.key, required this.onCodes});

  /// The codes found in the chosen file.
  final ValueChanged<List<String>> onCodes;

  @override
  ConsumerState<CodeImportButton> createState() => _CodeImportButtonState();
}

class _CodeImportButtonState extends ConsumerState<CodeImportButton> {
  final _menu = MenuController();
  bool _busy = false;

  /// The message id of the warning shown, if any.
  String? _error;

  /// Whether only text files can be read: no pictures and no PDFs in this build.
  bool get _textOnly => !ref.read(readsPicturesProvider) && !ref.read(readsPdfsProvider);

  void _pick() {
    setState(() => _error = null);
    if (_textOnly) {
      unawaited(_read(CodeSource.file));
      return;
    }
    _menu.isOpen ? _menu.close() : _menu.open();
  }

  Future<void> _read(CodeSource source) async {
    final files = ref.read(fileServiceProvider);
    final PickedFile? file;
    try {
      file = await switch (source) {
        CodeSource.photos => files.pickImage(),
        CodeSource.camera => files.takePhoto(),
        CodeSource.file => files.pickFile(
          extensions: [
            if (ref.read(readsPicturesProvider)) ...codeFileExtensions.where((ext) => ext != 'pdf' && !codeTextExtensions.contains(ext)),
            if (ref.read(readsPdfsProvider)) 'pdf',
            ...codeTextExtensions,
          ],
        ),
      };
    } catch (_) {
      // The camera or the photos refused, say.
      if (mounted) setState(() => _error = 'codeImport.failed');
      return;
    }
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    String? error;
    try {
      final codes = await ref.read(codeFileReaderProvider).codesFromFile(file, kind: source == CodeSource.file ? null : ImportKind.image);
      if (!mounted) return;
      if (codes.isEmpty) {
        error = 'codeImport.none';
      } else {
        widget.onCodes(codes);
      }
    } on NotInThisBuild {
      // A picture or a PDF the picker handed over all the same; nothing is added
      error = 'backup.import.notInThisBuild';
    } on UnsupportedFileError {
      error = _textOnly ? 'backup.import.notInThisBuild' : 'codeImport.unsupported';
    } catch (_) {
      error = 'codeImport.failed';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final pictures = ref.watch(readsPicturesProvider);
    final textOnly = !pictures && !ref.watch(readsPdfsProvider);
    final error = _error;

    MenuItemButton choice(CodeSource source, IconData icon, String label) =>
        MenuItemButton(leadingIcon: Icon(icon, size: 20), onPressed: () => unawaited(_read(source)), child: Text(context.t(label)));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: MenuAnchor(
            controller: _menu,
            alignmentOffset: const Offset(0, 6),
            menuChildren: [
              if (pictures) ...[
                choice(CodeSource.photos, Icons.photo_library_outlined, 'codeImport.from.photos'),
                choice(CodeSource.camera, Icons.photo_camera_outlined, 'codeImport.from.camera'),
              ],
              choice(CodeSource.file, Icons.description_outlined, 'codeImport.from.file'),
            ],
            child: PressScale(
              enabled: !_busy,
              child: TextButton.icon(
                onPressed: _busy ? null : _pick,
                style: TextButton.styleFrom(backgroundColor: b.accentSoft, foregroundColor: b.accentText),
                icon: Icon(textOnly ? Icons.description_outlined : Icons.document_scanner_outlined, size: 20),
                label: Text(context.t(textOnly ? 'backup.import.freeButton' : 'codeImport.button')),
              ),
            ),
          ),
        ),
        if (textOnly)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AppAlert(severity: AlertSeverity.info, child: Text(context.t('backup.import.freeNote'))),
          ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 4, semanticsLabel: context.t('codeImport.reading')),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FadeIn(
              duration: const Duration(milliseconds: 300),
              child: AppAlert(
                severity: AlertSeverity.warning,
                onClose: () => setState(() => _error = null),
                closeLabel: MaterialLocalizations.of(context).closeButtonTooltip,
                child: Text(context.t(error)),
              ),
            ),
          ),
      ],
    );
  }
}
