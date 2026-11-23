import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'dialog_heading.dart';

/// Asks before something that can't be undone, and resolves to true when it
/// is confirmed (false when cancelled or dismissed). With [danger], the
/// default, the confirm button and the icon tile are red; otherwise Azure.
Future<bool> showConfirmDialog(
  BuildContext context, {
  Widget? icon,
  required String title,
  required Widget body,
  required String confirmLabel,
  required String cancelLabel,
  bool danger = true,
}) async {
  final confirmed = await showAppDialog<bool>(
    context,
    builder: (context) =>
        ConfirmDialog(icon: icon, title: title, body: body, confirmLabel: confirmLabel, cancelLabel: cancelLabel, danger: danger),
  );
  return confirmed ?? false;
}

/// The confirmation dialog [showConfirmDialog] opens: the heading (with an
/// icon tile when [icon] is given), the [body] in secondary text, and Cancel
/// beside the confirm button. The buttons pop the dialog with false and
/// true.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    this.icon,
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.cancelLabel,
    this.danger = true,
  });

  final Widget? icon;
  final String title;

  /// Usually a [Text]; it is set in body2 and `text.secondary`.
  final Widget body;
  final String confirmLabel;
  final String cancelLabel;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: icon, title: title, tone: danger ? DialogTone.danger : DialogTone.accent),
      content: DefaultTextStyle.merge(
        style: AppType.body2.copyWith(color: p.textSecondary),
        child: body,
      ),
      actions: [
        TextButton(
          // MUI's color="inherit": the dialog's text colour.
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: danger ? filledButtonColors(background: p.error, foreground: p.onError) : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
