import 'package:flutter/material.dart';

/// The frame of a tab's page, as the layout's `<main>` set it: at most
/// 600 wide and centred, 16 from the sides, clear of the status bar at the
/// top and of the floating tab bar at the bottom.
class ShellPage extends StatelessWidget {
  const ShellPage({super.key, required this.children, this.controller});

  final List<Widget> children;
  final ScrollController? controller;

  /// Room for the floating tab bar under the last item.
  static const bottomClearance = 132.0;

  static const maxWidth = 600.0;

  /// The page's padding, for pages that build their own scroll view.
  static EdgeInsets padding(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final side = width > maxWidth + 32 ? (width - maxWidth) / 2 : 16.0;
    return EdgeInsets.fromLTRB(side, safe.top + 16, side, safe.bottom + bottomClearance);
  }

  @override
  Widget build(BuildContext context) => ListView(controller: controller, padding: padding(context), children: children);
}
