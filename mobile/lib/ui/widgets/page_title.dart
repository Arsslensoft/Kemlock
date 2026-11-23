import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// The large left-aligned title of the tab screens (36px), with an optional
/// small [count] after it (the number of accounts, say), a [trailing]
/// control at the right, level with the title's foot, and a [subtitle]
/// below.
class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.title, this.count, this.trailing, this.subtitle});

  final String title;
  final int? count;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text.rich(
                    TextSpan(
                      text: title,
                      children: [
                        if (count != null)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.top,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(
                                '$count',
                                style: TextStyle(
                                  fontFamily: fontSans,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0,
                                  height: 1,
                                  color: context.bmc.faint,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    style: AppType.h1.copyWith(color: p.text),
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 16), trailing!],
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
              child: Text(subtitle!, style: AppType.body1.copyWith(color: p.textSecondary)),
            ),
        ],
      ),
    );
  }
}

/// The compact header of pushed screens (About, Terms): a round back button
/// on the left, named [backLabel] for screen readers, and the [title]
/// centred.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({super.key, required this.title, required this.onBack, required this.backLabel});

  final String title;
  final VoidCallback onBack;
  final String backLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 40,
            child: PressScale(
              scale: 0.94,
              child: IconButton(
                onPressed: onBack,
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  backgroundColor: p.paper,
                  foregroundColor: p.textSecondary,
                  fixedSize: const Size.square(40),
                  minimumSize: const Size.square(40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: CircleBorder(side: BorderSide(color: p.divider)),
                ),
                icon: Icon(Icons.arrow_back_ios_new_rounded, size: 16, semanticLabel: backLabel),
              ),
            ),
          ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: AppType.h5.copyWith(color: p.text),
              ),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}
