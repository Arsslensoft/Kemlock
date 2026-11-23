import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// The height of a digit's window, in ems (`line-height: 1.15`).
const _lineHeight = 1.15;

/// A one-time code drawn as odometer strips that roll to each new value.
/// On first build every strip rolls up from 0 to its digit, one after the
/// other; later changes roll from where the strip is. A 6- or 8-digit code
/// is split in two halves with a small gap. Letters (Steam codes) stand
/// still. Screen readers (and tests) get the code grouped, as "123 456".
///
/// The [style] is merged over Geist Mono with tabular figures, medium
/// weight; give it the font size and colour. A colour change fades over .4s.
class CodeDigits extends StatelessWidget {
  const CodeDigits({super.key, required this.code, this.style});

  final String code;
  final TextStyle? style;

  /// [code] split in two halves when it has 6 or 8 characters, as screen
  /// readers hear it.
  static String grouped(String code) {
    if (code.length != 6 && code.length != 8) return code;
    final half = code.length ~/ 2;
    return '${code.substring(0, half)} ${code.substring(half)}';
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style
        .merge(AppType.mono(fontWeight: FontWeight.w500).copyWith(height: _lineHeight, leadingDistribution: TextLeadingDistribution.even));
    final merged = base.merge(style);
    final fontSize = merged.fontSize ?? 14;
    final textStyle = merged.copyWith(letterSpacing: merged.letterSpacing ?? 0.01 * fontSize);
    final half = code.length == 6 || code.length == 8 ? code.length ~/ 2 : -1;
    final chars = code.split('');
    return Semantics(
      label: grouped(code),
      excludeSemantics: true,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: textStyle.color),
        duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 400),
        curve: Ease.css,
        builder: (context, color, _) {
          final s = textStyle.copyWith(color: color);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, ch) in chars.indexed) ...[
                if (_isDigit(ch)) _DigitStrip(digit: int.parse(ch), index: i, style: s) else Text(ch, style: s),
                if (i == half - 1) SizedBox(width: 0.3 * fontSize),
              ],
            ],
          );
        },
      ),
    );
  }

  static bool _isDigit(String ch) => ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;
}

/// One digit's window onto a 0-9 strip, rolled to [digit].
class _DigitStrip extends StatefulWidget {
  const _DigitStrip({required this.digit, required this.index, required this.style});

  final int digit;

  /// The digit's place in the code, which staggers its roll.
  final int index;
  final TextStyle style;

  @override
  State<_DigitStrip> createState() => _DigitStripState();
}

class _DigitStripState extends State<_DigitStrip> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  Animation<double> _curve = kAlwaysCompleteAnimation;
  CurvedAnimation? _curved;

  /// Where the strip rolls from and to, in digits.
  double _from = 0;
  late double _to = widget.digit.toDouble();
  bool _started = false;

  double get _position => _from + (_to - _from) * _curve.value;

  /// Rolls from where the strip is now to [digit] over [duration], after
  /// [delay]; the wait is part of the animation so tests can settle it.
  void _roll(double from, int digit, Duration duration, Duration delay) {
    _from = from;
    _to = digit.toDouble();
    _curved?.dispose();
    _curved = null;
    if (Motion.reduced(context)) {
      _curve = kAlwaysCompleteAnimation;
      return;
    }
    final total = delay + duration;
    _controller.duration = total;
    _curve = _curved = CurvedAnimation(
      parent: _controller,
      curve: Interval(delay.inMicroseconds / total.inMicroseconds, 1, curve: Ease.roll),
    );
    _controller.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // On mount the strip rolls up from 0: .9s, 45ms later for each place.
    _roll(0, widget.digit, const Duration(milliseconds: 900), Duration(milliseconds: 45 * widget.index));
  }

  @override
  void didUpdateWidget(_DigitStrip old) {
    super.didUpdateWidget(old);
    // Later changes: .7s, 35ms later for each place, from wherever it is.
    if (old.digit != widget.digit) {
      _roll(_position, widget.digit, const Duration(milliseconds: 700), Duration(milliseconds: 35 * widget.index));
    }
  }

  @override
  void dispose() {
    _curved?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Text digit(int d) => Text('$d', style: widget.style, textAlign: TextAlign.center);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final position = _position;
        return ClipRect(
          child: Stack(
            children: [
              // Sizes the window: one digit wide and one line tall.
              Visibility.maintain(visible: false, child: digit(0)),
              for (var d = 0; d <= 9; d++)
                if ((d - position).abs() < 1)
                  Positioned.fill(
                    child: FractionalTranslation(translation: Offset(0, d - position), child: digit(d)),
                  ),
            ],
          ),
        );
      },
    );
  }
}
