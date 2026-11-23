/// "Open a Send": a field the person pastes a Send link into (`docs/plans/add-sends.md`, design 9). The app never reads
/// the clipboard itself, which would show iOS's paste prompt, and never clears a clipboard it didn't write. A whole
/// message pasted is fine: the first Send link in it opens. The field is emptied when the sheet closes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../sync/sync_sheet_frame.dart';
import 'received_send_sheet.dart';

/// Shows the paste field.
Future<void> showOpenSendSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('sends.openSheet.title'), builder: (_) => const OpenSendSheet());

/// The sheet with the paste field.
class OpenSendSheet extends ConsumerStatefulWidget {
  const OpenSendSheet({super.key});

  @override
  ConsumerState<OpenSendSheet> createState() => _OpenSendSheetState();
}

class _OpenSendSheetState extends ConsumerState<OpenSendSheet> {
  final _link = TextEditingController();
  var _notALink = false;

  @override
  void initState() {
    super.initState();
    _link.addListener(_changed);
  }

  void _changed() {
    if (mounted) {
      setState(() => _notALink = false);
    }
  }

  @override
  void dispose() {
    // The link holds the key: it doesn't stay in the field. The listener goes first, so emptying the field runs no
    // setState on an element that is going away.
    _link.removeListener(_changed);
    _link.clear();
    _link.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final text = _link.text;
    final handled = await openSendLinkText(context, ref, text);
    if (!mounted) return;
    if (!handled) {
      setState(() => _notALink = true);
    } else {
      _link.clear();
    }
  }

  @override
  Widget build(BuildContext context) => SyncSheetFrame(
    icon: const Icon(Icons.link_rounded),
    title: context.t('sends.openSheet.title'),
    actions: [
      TextButton(
        style: inheritButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.t('changePw.cancel')),
      ),
      FilledButton(onPressed: _link.text.trim().isEmpty ? null : () => unawaited(_open()), child: Text(context.t('sends.openSheet.open'))),
    ],
    children: [
      SheetText(context.t('sends.openSheet.body')),
      SecretSelection(
        child: TextField(
          enableIMEPersonalizedLearning: false,
          controller: _link,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          contextMenuBuilder: secretTextMenu,
          decoration: InputDecoration(
            labelText: context.t('sends.openSheet.field'),
            errorText: _notALink ? context.t('sends.received.notASend') : null,
          ),
        ),
      ),
    ],
  );
}
