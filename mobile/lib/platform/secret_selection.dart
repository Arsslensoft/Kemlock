import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secret_clipboard.dart';

/// Text selected in a view of secrets (a private key, a Recovery Kit piece,
/// a PIV management key, a decrypted message, a password shown) is copied
/// through the secret clipboard, as the view's own Copy button copies it:
/// marked sensitive on Android, kept off Universal Clipboard on iOS, and
/// cleared after the delay chosen in Settings. Flutter's own copy puts it
/// on the plain clipboard, for good.
///
/// Two ways out need closing. The selection toolbar's Copy and Cut write
/// the clipboard themselves, so the view's SelectableText or TextField
/// takes [secretTextMenu] as its `contextMenuBuilder`, which also leaves
/// out Share, Look Up and Search Web, which hand the text to another app.
/// A keyboard's copy and cut come as a [CopySelectionTextIntent], which
/// [SecretSelection] around the view takes over. Text elsewhere copies as
/// before.
class SecretSelection extends StatefulWidget {
  const SecretSelection({super.key, required this.child});

  final Widget child;

  @override
  State<SecretSelection> createState() => _SecretSelectionState();
}

class _SecretSelectionState extends State<SecretSelection> {
  final _copy = _SecretCopyAction();

  @override
  Widget build(BuildContext context) => Actions(actions: {CopySelectionTextIntent: _copy}, child: widget.child);
}

/// The secret clipboard's copy, as the app's providers hold it above [context].
Future<bool> Function(String text) _secretCopy(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(secretClipboardProvider).copy;

/// The selection toolbar of a view of secrets ([SecretSelection]), for a
/// SelectableText's or TextField's `contextMenuBuilder`.
Widget secretTextMenu(BuildContext context, EditableTextState editable) {
  final copy = _secretCopy(editable.context);
  final items = <ContextMenuButtonItem>[
    for (final item in editable.contextMenuButtonItems)
      if (item.type == ContextMenuButtonType.copy)
        item.copyWith(onPressed: () => copySecretSelection(editable, copy, cut: false, cause: SelectionChangedCause.toolbar))
      else if (item.type == ContextMenuButtonType.cut)
        item.copyWith(onPressed: () => copySecretSelection(editable, copy, cut: true, cause: SelectionChangedCause.toolbar))
      else if (!_handsTextOn.contains(item.type))
        item,
  ];
  return AdaptiveTextSelectionToolbar.buttonItems(anchors: editable.contextMenuAnchors, buttonItems: items);
}

/// Toolbar buttons that give the selected text to another app or service.
const _handsTextOn = {ContextMenuButtonType.share, ContextMenuButtonType.lookUp, ContextMenuButtonType.searchWeb};

/// Copies what is selected in [editable] with [copy], the secret
/// clipboard's, or with [cut] cuts it, as `EditableTextState.copySelection`
/// and `cutSelection` do with the plain clipboard. Nothing is copied from
/// an obscured field.
void copySecretSelection(
  EditableTextState editable,
  Future<bool> Function(String text) copy, {
  required bool cut,
  required SelectionChangedCause cause,
}) {
  final value = editable.textEditingValue;
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed || editable.widget.obscureText) return;
  unawaited(copy(selection.textInside(value.text)));
  if (cut && !editable.widget.readOnly) {
    editable.userUpdateTextEditingValue(
      TextEditingValue(
        text: selection.textBefore(value.text) + selection.textAfter(value.text),
        selection: TextSelection.collapsed(offset: selection.start),
      ),
      cause,
    );
  }
  if (cause == SelectionChangedCause.toolbar) editable.hideToolbar();
}

/// A keyboard's copy or cut in a view of secrets: through the secret
/// clipboard, or not at all when the field it came from can't be found.
class _SecretCopyAction extends ContextAction<CopySelectionTextIntent> {
  @override
  Object? invoke(CopySelectionTextIntent intent, [BuildContext? context]) {
    final editable = _editableOf(context);
    if (editable == null || !editable.mounted) return null;
    copySecretSelection(editable, _secretCopy(editable.context), cut: intent.collapseSelection, cause: intent.cause);
    return null;
  }

  /// The field the intent came from: [context] is its own, or the focused
  /// one inside it.
  static EditableTextState? _editableOf(BuildContext? context) {
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) return context.state as EditableTextState;
    return context.findAncestorStateOfType<EditableTextState>();
  }
}
