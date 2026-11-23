import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What a [StatusTag] is about: something to look at soon, something
/// wrong, or, in the accent colour, where the item is ("On your key").
enum StatusTone { warning, danger, accent }

/// A small tag saying what state a row's item is in, in the shape of
/// [AccentTag]: the warning colour on `warnSoft`, or the error colour on
/// `dangerSoft`. [label] is its words ("Expires in 7 days", "Revoked"),
/// shown in capitals and read by a screen reader as written.
class StatusTag extends StatelessWidget {
  const StatusTag({super.key, required this.label, required this.tone});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final p = context.palette;
    final (background, ink) = switch (tone) {
      StatusTone.warning => (b.warnSoft, p.warning),
      StatusTone.danger => (b.dangerSoft, p.error),
      StatusTone.accent => (b.accentSoft, b.accentText),
    };
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          // 20 high for one line; a long label wraps and the tag grows with it
          constraints: const BoxConstraints(minHeight: 20),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
          // As wide as the words, wherever it is put.
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label.toUpperCase(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: fontSans,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.42,
                height: 1,
                color: ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
