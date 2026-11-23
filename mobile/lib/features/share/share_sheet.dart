/// "Shared to Kemlock" (openspec: add-share-extension, decision 10): what
/// another app shared, when it is not PGP data, and the two things to do
/// with it, each opening its sheet of add-pgp-messages with the item in
/// place. Closing the sheet drops the item.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/shared_items.dart';
import '../../ui/ui.dart';
import '../notes/note_files.dart' show fileSizeText;
import '../pgp/encrypt_sheet.dart';
import '../pgp/pgp_widgets.dart' show ClosesOnLock;
import '../pgp/sign_sheet.dart';

/// Opens "Shared to Kemlock" for [item], already taken from
/// [pendingShareProvider]: the sheet is its holder now.
Future<void> showShareSheet(BuildContext context, SharedItem item) => showAppBottomSheet<void>(
  context,
  label: context.t('share.title'),
  builder: (_) => ShareSheet(item: item),
);

/// [item] as the PGP sheets take a picked file.
PickedPath pickedOf(SharedFile item) => PickedPath(name: item.name, size: item.size, path: item.path);

/// The first four lines of [text], and of long ones the first 200
/// characters, with an ellipsis when there was more: what fits in the
/// eight lines the card shows on a phone. The text is cut here rather than
/// by the card: an ellipsis Flutter draws where it stops at a line break
/// does not show.
String firstLines(String text) {
  const lines = 4, characters = 200;
  final all = text.replaceAll('\r\n', '\n').split('\n');
  var shown = all.take(lines).join('\n');
  var more = all.length > lines;
  if (shown.length > characters) {
    shown = shown.substring(0, characters);
    more = true;
  }
  return '${shown.trimRight()}${more ? '…' : ''}';
}

class ShareSheet extends ConsumerStatefulWidget {
  const ShareSheet({super.key, required this.item});

  final SharedItem item;

  @override
  ConsumerState<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<ShareSheet> with ClosesOnLock {
  /// The item went to the Encrypt or Sign sheet, whose file it now is.
  var _handedOn = false;

  @override
  void initState() {
    super.initState();
    closeOnLock();
  }

  @override
  void dispose() {
    // Closed, or the vault locked: the item is gone, and its file with it
    final item = widget.item;
    if (!_handedOn && item is SharedFile) deleteSharedFile(item.path);
    super.dispose();
  }

  void _open(Future<void> Function(BuildContext context, {String? text, PickedPath? file}) show) {
    final item = widget.item;
    _handedOn = true;
    if (item is SharedFile) ref.read(pendingShareProvider.notifier).inUse(item.path);
    // The page under the sheet, which is still there once this one is gone
    final under = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    unawaited(switch (item) {
      SharedText(:final text) => show(under, text: text),
      final SharedFile file => show(under, file: pickedOf(file)),
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final item = widget.item;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.ios_share_rounded), title: context.t('share.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Rise(
                  child: switch (item) {
                    SharedText(:final text) => GroupCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          firstLines(text),
                          // 200 characters and three line breaks, wrapped on a phone
                          maxLines: 8,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.body1.copyWith(height: 1.55, color: p.text),
                        ),
                      ),
                    ),
                    SharedFile(:final name, :final size) => Group(
                      children: [
                        GroupRow(
                          first: true,
                          icon: const Icon(Icons.insert_drive_file_outlined),
                          primary: name,
                          secondary: fileSizeText(context, size),
                        ),
                      ],
                    ),
                  },
                ),
                const SizedBox(height: 12),
                Rise(
                  delay: const Duration(milliseconds: 60),
                  child: Group(
                    children: [
                      GroupRow(
                        first: true,
                        icon: const Icon(Icons.lock_outline_rounded),
                        accent: true,
                        primary: context.t('share.encrypt'),
                        secondary: context.t('share.encrypt.hint'),
                        onTap: () => _open(showEncryptSheet),
                      ),
                      GroupRow(
                        icon: const Icon(Icons.draw_outlined),
                        accent: true,
                        primary: context.t('share.sign'),
                        secondary: context.t('share.sign.hint'),
                        onTap: () => _open(showSignSheet),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
