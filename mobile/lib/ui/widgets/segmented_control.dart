import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// One choice of a [SegmentedControl].
class SegmentOption<T> {
  const SegmentOption({required this.value, required this.label, this.icon});

  final T value;
  final String label;

  /// Shown before the label, at 17px.
  final Widget? icon;
}

/// What a [SegmentedControl] is to screen readers.
enum SegmentSemantics {
  /// It switches between panels: a tab bar of tabs.
  tabs,

  /// It picks a value: a group of radio buttons.
  radio,
}

/// Its height: 34 for [small], 44 for [medium].
enum SegmentSize { small, medium }

/// A pill-shaped control whose thumb slides between equal-width options.
/// It fills the width it is given; in a row, give it one (the settings use
/// 196). Arrow keys move the choice along. [semanticLabel] names the group
/// for screen readers. With [mono] the labels are set in Geist Mono.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.semantics = SegmentSemantics.radio,
    this.size = SegmentSize.medium,
    this.mono = false,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String semanticLabel;
  final SegmentSemantics semantics;
  final SegmentSize size;
  final bool mono;

  int get _index => options.indexWhere((o) => o.value == value).clamp(0, options.length - 1);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final delta = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown
        ? 1
        : key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp
        ? -1
        : 0;
    if (delta == 0 || options.isEmpty) return KeyEventResult.ignored;
    onChanged(options[(_index + delta + options.length) % options.length].value);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final small = size == SegmentSize.small;
    final height = small ? 34.0 : 44.0;
    final pad = small ? 3.0 : 4.0;
    final index = _index;
    final tabs = semantics == SegmentSemantics.tabs;
    final reduced = Motion.reduced(context);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: tabs ? SemanticsRole.tabBar : SemanticsRole.radioGroup,
      label: semanticLabel,
      // No semantics of its own: the tabs must be the tab bar's direct children.
      child: Focus(
        includeSemantics: false,
        onKeyEvent: _onKey,
        child: Container(
          height: height,
          padding: EdgeInsets.all(pad),
          decoration: BoxDecoration(color: b.raised, borderRadius: BorderRadius.circular(small ? 11 : 14)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth / options.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: reduced ? Duration.zero : Motion.thumb,
                    curve: Ease.sheet,
                    left: index * width,
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: ExcludeSemantics(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: b.thumb,
                          borderRadius: BorderRadius.circular(small ? 8 : 10),
                          // 0 2px 8px rgba(0,0,0,.18)
                          boxShadow: const [BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.18), offset: Offset(0, 2), blurRadius: 8)],
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Row(
                      children: [
                        for (final (i, option) in options.indexed)
                          Expanded(
                            child: _Segment(
                              option: option,
                              selected: i == index,
                              tabs: tabs,
                              small: small,
                              mono: mono,
                              color: i == index ? p.text : p.textSecondary,
                              reduced: reduced,
                              onTap: () => onChanged(option.value),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.selected,
    required this.tabs,
    required this.small,
    required this.mono,
    required this.color,
    required this.reduced,
    required this.onTap,
  });

  final SegmentOption<T> option;
  final bool selected;
  final bool tabs;
  final bool small;
  final bool mono;
  final Color color;
  final bool reduced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    role: tabs ? SemanticsRole.tab : null,
    selected: tabs ? selected : null,
    inMutuallyExclusiveGroup: tabs ? null : true,
    checked: tabs ? null : selected,
    label: option.label,
    onTap: onTap,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: color),
        duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
        curve: Ease.css,
        builder: (context, color, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (option.icon != null) ...[
              IconTheme.merge(
                data: IconThemeData(size: 17, color: color),
                child: option.icon!,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: mono ? fontMono : fontSans,
                  fontSize: small ? 12.5 : 13.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
