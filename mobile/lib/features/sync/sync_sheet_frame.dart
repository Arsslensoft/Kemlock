import 'package:flutter/material.dart';

import '../../ui/ui.dart';

/// The layout the sync and spaces sheets share, as their dialogs had it in
/// the web app: the heading with its icon tile, the [children] 16 apart
/// (scrolling when the sheet runs out of room), and the [actions] at the
/// bottom right, with [leading] alone at the left (such as Turn off).
class SyncSheetFrame extends StatelessWidget {
  const SyncSheetFrame({super.key, required this.icon, required this.title, required this.children, required this.actions, this.leading});

  final Widget icon;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DialogHeading(icon: icon, title: title),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: DefaultTextStyle.merge(
            style: AppType.body1.copyWith(color: context.palette.text),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 16, children: children),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Row(
          children: [
            ?leading,
            Expanded(
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                children: actions,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Secondary words under a sheet's heading (body2, `text.secondary`).
class SheetText extends StatelessWidget {
  const SheetText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: AppType.body2.copyWith(color: context.palette.textSecondary));
}

/// A text button in the sheet's text colour, MUI's `color="inherit"`, as Cancel and Close are.
ButtonStyle inheritButtonStyle(BuildContext context) => TextButton.styleFrom(foregroundColor: context.palette.text);
