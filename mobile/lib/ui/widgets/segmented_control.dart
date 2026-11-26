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
    this.scrollable = false,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String semanticLabel;
  final SegmentSemantics semantics;
  final SegmentSize size;
  final bool mono;

  /// For many options: each is as wide as its label needs, and the row scrolls sideways when they don't all fit (the thumb follows the
  /// choice into view). Without it the options are of equal width and share the width given.
  final bool scrollable;

  /// The widths of the options in [available] pixels: equal, or, when [scrollable], as wide as each label needs (and no narrower than
  /// an equal share when they all fit).
  List<double> _widths(BuildContext context, double available, bool small) {
    if (!scrollable) {
      return List.filled(options.length, available / options.length);
    }
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final natural = [
      for (final option in options)
        (TextPainter(
              text: TextSpan(
                text: option.label,
                style: TextStyle(fontFamily: mono ? fontMono : fontSans, fontSize: small ? 12.5 : 13.5, fontWeight: FontWeight.w600),
              ),
              maxLines: 1,
              textDirection: direction,
              textScaler: scaler,
            )..layout()).width +
            (option.icon != null ? 23 : 0) +
            24,
    ];
    final total = natural.fold(0.0, (sum, width) => sum + width);
    if (total >= available) {
      return natural;
    }
    final extra = (available - total) / options.length;
    return [for (final width in natural) width + extra];
  }

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
              final widths = _widths(context, constraints.maxWidth, small);
              final left = widths.take(index).fold(0.0, (sum, width) => sum + width);
              final stack = Stack(
                children: [
                  AnimatedPositioned(
                    duration: reduced ? Duration.zero : Motion.thumb,
                    curve: Ease.sheet,
                    left: left,
                    top: 0,
                    bottom: 0,
                    width: widths[index],
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
                          SizedBox(
                            width: widths[i],
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
              if (!scrollable) {
                return stack;
              }
              return _Scrolling(
                width: widths.fold(0.0, (sum, width) => sum + width),
                left: left,
                selectedWidth: widths[index],
                child: stack,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The options of a scrollable [SegmentedControl]: a row as wide as they are, scrolled sideways, which brings the chosen one into
/// view when the choice moves.
class _Scrolling extends StatefulWidget {
  const _Scrolling({required this.width, required this.left, required this.selectedWidth, required this.child});

  final double width;
  final double left;
  final double selectedWidth;
  final Widget child;

  @override
  State<_Scrolling> createState() => _ScrollingState();
}

class _ScrollingState extends State<_Scrolling> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_Scrolling oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.left == oldWidget.left || !_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final start = position.pixels;
    final end = start + position.viewportDimension;
    final target = widget.left < start
        ? widget.left
        : widget.left + widget.selectedWidth > end
        ? widget.left + widget.selectedWidth - position.viewportDimension
        : null;
    if (target == null) {
      return;
    }
    final offset = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    // animateTo refuses a zero duration, so reduced motion jumps
    if (Motion.reduced(context)) {
      _controller.jumpTo(offset);
    } else {
      _controller.animateTo(offset, duration: Motion.thumb, curve: Ease.sheet);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: _controller,
    scrollDirection: Axis.horizontal,
    child: SizedBox(width: widget.width, child: widget.child),
  );
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
