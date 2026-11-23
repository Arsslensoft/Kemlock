import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One choice of a column of cards, as the generate sheet's key types are
/// offered (`.opt` in `kemlock.css`): a bordered card with a radio mark, a
/// [title], an optional [tag] beside it (the shape of [AccentTag]) and
/// a [caption]. The [selected] card has the accent's border and ground and
/// a filled mark. A screen reader hears a radio button named by the title,
/// in its group of one choice.
class OptionCard extends StatelessWidget {
  const OptionCard({super.key, required this.title, required this.caption, required this.selected, this.tag, this.onTap});

  final String title;
  final String caption;
  final bool selected;

  /// Beside the title: "Recommended".
  final String? tag;

  /// Null when it cannot be chosen now.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final border = selected ? b.accentLine : p.divider;
    final ground = selected ? Color.alphaBlend(b.accentSoft, p.paper) : p.paper;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: false,
      enabled: onTap != null,
      label: title,
      hint: caption,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: ground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RadioMark(selected: selected),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Text(
                            title,
                            style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
                          ),
                          if (tag != null) _Tag(label: tag!),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(caption, style: AppType.caption.copyWith(color: selected ? p.text : p.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The radio mark: a ring, filled with the accent when [selected].
class _RadioMark extends StatelessWidget {
  const _RadioMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? context.bmc.sunken : null,
        border: Border.all(color: selected ? p.primary : p.textSecondary, width: selected ? 7 : 2),
      ),
    );
  }
}

/// The tag beside a title, in the shape of [AccentTag].
class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(6)),
      child: Center(
        widthFactor: 1,
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          style: TextStyle(
            fontFamily: fontSans,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.42,
            height: 1,
            color: b.accentText,
          ),
        ),
      ),
    );
  }
}
