import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/effects.dart';
import 'status_tag.dart';

/// The small spaced capitals above a group, in faint ink.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(6, 26, 6, 8)});

  final String text;

  /// Around the label: 26 above, 8 below and 6 at the sides by default.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Semantics(
      header: true,
      child: Text(text.toUpperCase(), style: AppType.overline.copyWith(color: context.bmc.faint)),
    ),
  );
}

/// A rounded paper card (22px corners, a divider edge) that holds rows.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: p.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A section of a settings-style page: an optional [label] over a card of
/// [children], usually [GroupRow]s (mark the first one `first`).
class Group extends StatelessWidget {
  const Group({super.key, this.label, required this.children});

  final String? label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (label != null) SectionLabel(label!),
      GroupCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ],
  );
}

/// A row in a [Group]: an optional [icon] in a small tile, the [primary]
/// text with a [secondary] line under it, then a [value] or a [control] on
/// the right. With [onTap] and no control the whole row is a button with a
/// chevron, or with a [tag] in the chevron's place. A hairline separates it
/// from the row above, unless it is [first]. [secondaryStyle] changes how
/// the secondary line is written, and [secondarySemanticsLabel] what is
/// read out for it, for a line shortened for the eye such as a fingerprint.
/// [danger] paints it red, for actions like deleting; [accent] paints its
/// tile in the accent colour with a soft standing glow, and
/// [muted] its primary text faint, for an item that is no longer in use.
class GroupRow extends StatelessWidget {
  const GroupRow({
    super.key,
    this.icon,
    required this.primary,
    this.secondary,
    this.secondaryStyle,
    this.secondarySemanticsLabel,
    this.value,
    this.control,
    this.tag,
    this.onTap,
    this.danger = false,
    this.accent = false,
    this.muted = false,
    this.first = false,
  });

  final Widget? icon;
  final String primary;
  final String? secondary;

  /// Merged over the secondary line's style: the monospace face for a fingerprint.
  final TextStyle? secondaryStyle;

  /// What a screen reader says for the secondary line, when that is not its text.
  final String? secondarySemanticsLabel;

  /// Shown on the right in secondary text; usually a [Text].
  final Widget? value;

  /// Shown on the right instead of a chevron, such as a [Switch].
  final Widget? control;

  /// A small tag on the right, such as a [StatusTag]. A row with [onTap]
  /// shows it where its chevron would be, and is still a button.
  final Widget? tag;
  final VoidCallback? onTap;
  final bool danger;

  /// The tile in the accent colour on its soft ground.
  final bool accent;

  /// The primary text in faint ink.
  final bool muted;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final tappable = onTap != null && control == null;
    final tileInk = danger
        ? p.error
        : accent
        ? b.accentText
        : p.textSecondary;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 54),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            if (icon != null) ...[
              ExcludeSemantics(
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: danger
                        ? b.dangerSoft
                        : accent
                        ? b.accentSoft
                        : b.raised,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: accent && !danger ? StandingGlow.tile(b) : null,
                  ),
                  // A tile holds an icon, or a few letters such as "PGP"
                  child: DefaultTextStyle.merge(
                    style: TextStyle(fontFamily: fontSans, fontSize: 12, fontWeight: FontWeight.w600, height: 1, color: tileInk),
                    child: IconTheme.merge(
                      data: IconThemeData(size: 18, color: tileInk),
                      child: icon!,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: secondary != null ? 8 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      primary,
                      style: AppType.body1.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        color: danger
                            ? p.error
                            : muted
                            ? b.faint
                            : p.text,
                      ),
                    ),
                    if (secondary != null)
                      Text(
                        secondary!,
                        semanticsLabel: secondarySemanticsLabel,
                        style: AppType.caption.copyWith(color: p.textSecondary).merge(secondaryStyle),
                      ),
                  ],
                ),
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 14),
              DefaultTextStyle.merge(
                style: AppType.body2.copyWith(color: p.textSecondary),
                child: value!,
              ),
            ],
            if (control != null) ...[const SizedBox(width: 14), control!],
            // A long tag wraps within two fifths of the screen, so the texts keep their room on a narrow phone
            if (tag != null) ...[
              const SizedBox(width: 14),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
                child: tag!,
              ),
            ],
            if (tappable && tag == null) ...[
              const SizedBox(width: 14),
              ExcludeSemantics(child: Icon(Icons.chevron_right_rounded, size: 20, color: b.faint)),
            ],
          ],
        ),
      ),
    );

    final row = CustomPaint(
      painter: first ? null : _SeparatorPainter(color: p.divider, inset: icon != null ? 60 : 14),
      // A tappable row reads as one button; otherwise the row holds its texts and its control keeps its own semantics.
      child: tappable
          ? MergeSemantics(
              child: Semantics(
                button: true,
                child: InkWell(onTap: onTap, highlightColor: p.hover, child: content),
              ),
            )
          : Semantics(container: true, child: content),
    );
    return row;
  }
}

/// The hairline above a row, starting at [inset] from the left.
class _SeparatorPainter extends CustomPainter {
  const _SeparatorPainter({required this.color, required this.inset});

  final Color color;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(Rect.fromLTWH(inset, 0, size.width - inset, 1), Paint()..color = color);

  @override
  bool shouldRepaint(_SeparatorPainter old) => old.color != color || old.inset != inset;
}
