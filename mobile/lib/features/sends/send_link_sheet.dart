/// The link of a Send, with Copy and Share (`docs/plans/add-sends.md`, tasks 5.3 and 11).
///
/// The link holds the key that opens the Send, so Copy goes through the secret clipboard (marked sensitive on Android,
/// local only on iOS, cleared after the delay set in Settings), the field shows it where selecting copies through the
/// same clipboard, and the field is emptied when the sheet closes. The sheet says that anyone who has the link can
/// open the Send, and that Share is better than Copy for a message.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/secret_clipboard.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';

/// Shows [link], a Send's link.
Future<void> showSendLinkSheet(BuildContext context, String link) => showAppBottomSheet<void>(
  context,
  label: context.t('sends.link.title'),
  builder: (_) => SendLinkSheet(link: link),
);

/// A Send's link with Copy and Share. [onDone] closes it; by default it pops the route it is in.
class SendLinkSheet extends ConsumerStatefulWidget {
  const SendLinkSheet({super.key, required this.link, this.onDone});

  final String link;
  final VoidCallback? onDone;

  @override
  ConsumerState<SendLinkSheet> createState() => _SendLinkSheetState();
}

class _SendLinkSheetState extends ConsumerState<SendLinkSheet> {
  late final _field = TextEditingController(text: widget.link);

  @override
  void dispose() {
    // The link holds the key: it doesn't stay in the field
    _field.clear();
    _field.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final copied = await ref.read(secretClipboardProvider).copy(widget.link);
    if (!mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show(context.t(copied ? 'sends.copied' : 'sends.copyFailed'), severity: copied ? ToastSeverity.success : ToastSeverity.error);
  }

  Future<void> _share() => ref.read(fileServiceProvider).shareText(widget.link);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SyncSheetFrame(
      icon: const Icon(Icons.link_rounded),
      title: context.t('sends.link.title'),
      actions: [
        TextButton.icon(
          onPressed: () => unawaited(_share()),
          icon: const Icon(Icons.ios_share_rounded, size: 20),
          label: Text(context.t('sends.detail.share')),
        ),
        TextButton.icon(
          onPressed: () => unawaited(_copy()),
          icon: const Icon(Icons.copy_rounded, size: 20),
          label: Text(context.t('sends.detail.copy')),
        ),
        FilledButton(onPressed: widget.onDone ?? () => Navigator.of(context).pop(), child: Text(context.t('sends.link.done'))),
      ],
      children: [
        SheetText(context.t('sends.link.body')),
        SecretSelection(
          child: TextField(
            enableIMEPersonalizedLearning: false,
            controller: _field,
            readOnly: true,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            contextMenuBuilder: secretTextMenu,
            style: AppType.mono(fontSize: 13, color: p.text),
            decoration: InputDecoration(labelText: context.t('sends.link.field')),
          ),
        ),
      ],
    );
  }
}
