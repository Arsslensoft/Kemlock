import 'package:flutter/material.dart';

import '../../ui/ui.dart';

/// What the Recovery Kit's sheets hold, laid out as their MUI dialogs were:
/// the kit's shield over [title], the [content], which scrolls when the
/// sheet runs out of room, and the [actions] at the bottom right, with
/// [leading] (such as Remove kit) at the bottom left. When they don't fit
/// on one line, [leading] goes above the others, at the right.
class RecoverySheetLayout extends StatelessWidget {
  const RecoverySheetLayout({super.key, required this.title, required this.content, this.leading, this.actions = const []});

  final String title;
  final Widget content;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DialogHeading(icon: const Icon(Icons.health_and_safety_outlined), title: title),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: DefaultTextStyle.merge(
            style: AppType.body1.copyWith(color: context.palette.text),
            child: content,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        // Too wide for one line, the actions go under each other at the right, [leading] on top.
        child: OverflowBar(
          alignment: leading == null ? MainAxisAlignment.end : MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 14,
          overflowSpacing: 8,
          children: [
            ?leading,
            Wrap(alignment: WrapAlignment.end, spacing: 14, runSpacing: 8, children: actions),
          ],
        ),
      ),
    ],
  );
}

/// A Cancel or Close button in the page's ink rather than Azure, MUI's `color="inherit"`.
class InkTextButton extends StatelessWidget {
  const InkTextButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: context.palette.text),
    child: Text(label),
  );
}

/// Children of a sheet's content with [gap] between them, as `gap: 2` in a
/// flex column (16px).
class GapColumn extends StatelessWidget {
  const GapColumn({super.key, required this.children, this.gap = 16});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, child) in children.indexed) ...[if (i > 0) SizedBox(height: gap), child],
    ],
  );
}
