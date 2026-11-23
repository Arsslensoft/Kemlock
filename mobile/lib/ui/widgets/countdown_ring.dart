import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// Drains clockwise over one TOTP window. The arc animates linearly toward
/// where it will be at the next tick, so it moves continuously instead of
/// stepping; when a new window starts it refills over half a second. From
/// [urgentAt] seconds left it turns from Azure to the warning colour. With
/// [label] the seconds left show in the middle.
class CountdownRing extends StatelessWidget {
  const CountdownRing({
    super.key,
    required this.remaining,
    required this.period,
    this.size = 44,
    this.stroke = 3,
    this.label = false,
    this.urgentAt = 5,
  });

  /// Seconds left in the window, from [period] down to 1.
  final int remaining;
  final int period;
  final double size;
  final double stroke;
  final bool label;
  final int urgentAt;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final reduced = Motion.reduced(context);
    final fraction = period <= 0 ? 0.0 : math.max(remaining - 1, 0) / period;
    final refill = remaining == period;
    final color = remaining <= urgentAt ? context.palette.warning : b.accentText;
    final colourTime = reduced ? Duration.zero : const Duration(milliseconds: 400);
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: color),
        duration: colourTime,
        curve: Ease.css,
        builder: (context, color, _) => Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: fraction),
                duration: reduced
                    ? Duration.zero
                    : refill
                    ? const Duration(milliseconds: 500)
                    : const Duration(seconds: 1),
                curve: refill ? Ease.out : Curves.linear,
                builder: (context, value, _) => CustomPaint(
                  painter: CountdownRingPainter(fraction: value, stroke: stroke, track: b.line2, color: color ?? b.accentText),
                ),
              ),
            ),
            if (label)
              Center(
                child: Text(
                  '$remaining',
                  style: AppType.mono(fontSize: (size * 0.3).roundToDouble(), fontWeight: FontWeight.w600, color: color),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Paints a [CountdownRing]: the line2 track and, over it, the arc of
/// what is left, from twelve o'clock clockwise, with a soft glow of its own
/// colour under it that follows it as it shortens and changes colour.
class CountdownRingPainter extends CustomPainter {
  const CountdownRingPainter({required this.fraction, required this.stroke, required this.track, required this.color});

  /// How much of the ring is left, from 0 to 1.
  final double fraction;
  final double stroke;
  final Color track;
  final Color color;

  /// The blur of the glow under the arc, as `drop-shadow(0 0 3px)`.
  static const glowBlur = 3.0;

  /// The glow under the arc: the arc's own colour at .8.
  Color get glow => color.withValues(alpha: color.a * 0.8);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = (size.shortestSide - stroke) / 2 - 1;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(center, r, paint..color = track);
    if (fraction <= 0) return;
    final arc = Rect.fromCircle(center: center, radius: r);
    final sweep = 2 * math.pi * fraction.clamp(0.0, 1.0);
    // The glow: the arc once more underneath, blurred. A CSS blur radius is twice the sigma of its Gaussian.
    canvas.drawArc(
      arc,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = glow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, glowBlur / 2),
    );
    // From twelve o'clock, clockwise.
    canvas.drawArc(
      arc,
      -math.pi / 2,
      sweep,
      false,
      paint
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(CountdownRingPainter old) =>
      old.fraction != fraction || old.stroke != stroke || old.track != track || old.color != color;
}
