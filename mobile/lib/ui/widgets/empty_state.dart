import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// What a list shows when it has nothing in it: an icon in a soft Azure
/// tile, a [title], an optional [body] and an [action] (usually a button),
/// centred and rising into place.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});

  final Widget icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Rise(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 64, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: b.accentSoft,
                  borderRadius: BorderRadius.circular(21),
                  border: Border.all(color: p.divider),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(size: 28, color: b.accentText),
                  child: icon,
                ),
              ),
            ),
            // The tile's 8px margin and the column's 10px gap.
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppType.h4.copyWith(color: p.text),
            ),
            if (body != null) ...[
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  body!,
                  textAlign: TextAlign.center,
                  textWidthBasis: TextWidthBasis.longestLine,
                  style: AppType.body2.copyWith(color: p.textSecondary),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}
