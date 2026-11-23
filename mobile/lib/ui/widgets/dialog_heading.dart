import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The colour of a dialog's icon tile.
enum DialogTone { accent, danger }

/// The shared header of every dialog: an icon in a soft 48px tile, Azure or
/// red by [tone], over the [title] (19px, semibold). Without an [icon] it is
/// the title alone, as MUI's DialogTitle.
class DialogHeading extends StatelessWidget {
  const DialogHeading({super.key, this.icon, required this.title, this.tone = DialogTone.accent});

  final Widget? icon;
  final String title;
  final DialogTone tone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final danger = tone == DialogTone.danger;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null)
          ExcludeSemantics(
            child: Container(
              width: 48,
              height: 48,
              margin: const EdgeInsets.only(left: 24, top: 24),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: danger ? b.dangerSoft : b.accentSoft, borderRadius: BorderRadius.circular(16)),
              child: IconTheme.merge(
                data: IconThemeData(color: danger ? p.error : b.accentText, size: 24),
                child: icon!,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
          child: Semantics(
            header: true,
            child: Text(title, style: AppType.h4.copyWith(color: p.text)),
          ),
        ),
      ],
    );
  }
}
