import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// What the lock screen's dial shows.
enum VaultDialState {
  /// Slow drift, waiting for the password.
  idle,

  /// Verifying: the inner rings light up and a beam scans the emblem.
  busy,

  /// Unlocked: the dial blooms away and the emblem turns Azure.
  open,
}

/// The lock screen's emblem: concentric dashed rings turning slowly around
/// the vault mark. [icon] sits in the middle (a lock, then a check once
/// [state] is open, which pops it in). The dial is [size] across, at most
/// 78% of the screen's width; the emblem stays 104px. Decoration only, so
/// screen readers skip it.
class VaultDial extends StatelessWidget {
  const VaultDial({super.key, required this.state, required this.icon, this.size = 280});

  final VaultDialState state;
  final Widget icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final busy = state == VaultDialState.busy;
    final open = state == VaultDialState.open;
    final reduced = Motion.reduced(context);
    Duration time(int ms) => reduced ? Duration.zero : Duration(milliseconds: ms);
    final side = math.min(size, MediaQuery.sizeOf(context).width * 0.78);

    Widget ring(double r, List<double> dash, int seconds, bool reverse, bool active, [double width = 1.2]) => Positioned.fill(
      child: Spin(
        period: Duration(seconds: seconds),
        reverse: reverse,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: active ? b.accentLine : b.line2),
          duration: time(500),
          curve: Ease.css,
          builder: (context, color, _) => CustomPaint(
            painter: _DashedRingPainter(radius: r, dash: dash, width: width, color: color!),
          ),
        ),
      ),
    );

    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: side,
        child: Stack(
          children: [
            // The rings: they bloom away when the vault opens and tighten while it checks.
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: open ? 0 : 1,
                duration: time(700),
                curve: Ease.css,
                child: AnimatedRotation(
                  turns: open ? 25 / 360 : 0,
                  duration: time(900),
                  curve: Ease.out,
                  child: AnimatedScale(
                    scale: open
                        ? 1.22
                        : busy
                        ? 0.96
                        : 1,
                    duration: time(900),
                    curve: Ease.out,
                    child: Stack(
                      children: [
                        ring(148, const [1.5, 7], 90, false, false),
                        ring(118, const [64, 18, 6, 18], 46, true, busy, 1.5),
                        ring(88, const [2, 9], 26, false, busy),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: Breathe(
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: open ? p.onPrimary : b.accentText),
                  duration: time(500),
                  curve: Ease.css,
                  builder: (context, foreground, _) => AnimatedContainer(
                    duration: time(500),
                    curve: Ease.css,
                    width: 104,
                    height: 104,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: open ? p.primary : p.paper,
                      borderRadius: BorderRadius.circular(34),
                      border: Border.all(color: busy ? b.accentLine : b.line2),
                      boxShadow: b.shadow,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (busy) const Positioned.fill(child: _Beam()),
                        IconTheme.merge(
                          data: IconThemeData(color: foreground, size: open ? 46 : 40),
                          child: open ? PopIn(duration: const Duration(milliseconds: 550), child: icon) : icon,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The scanning line that sweeps the emblem while the password is checked:
/// from 18% to 80% of its height and back, once a second each way.
class _Beam extends StatefulWidget {
  const _Beam();

  @override
  State<_Beam> createState() => _BeamState();
}

class _BeamState extends State<_Beam> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  late final CurvedAnimation _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _controller
        ..stop()
        ..value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _curve,
        builder: (context, _) => Stack(
          children: [
            Positioned(
              left: 16,
              right: 16,
              top: constraints.maxHeight * (0.18 + 0.62 * _curve.value),
              height: 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.primary,
                  borderRadius: BorderRadius.circular(1),
                  // 0 0 14px 2px accentLine
                  boxShadow: [BoxShadow(color: b.accentLine, blurRadius: 14, spreadRadius: 2)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the dial's rings: a circle of [radius] in a 300-unit box, stroked
/// [width] wide with round caps along the [dash] pattern, scaled to the
/// paint size.
class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter({required this.radius, required this.dash, required this.width, required this.color});

  final double radius;
  final List<double> dash;
  final double width;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 300;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;
    // As SVG draws a circle: from three o'clock, clockwise.
    final circumference = 2 * math.pi * radius;
    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);
    var at = 0.0;
    var i = 0;
    while (at < circumference) {
      final length = math.min(dash[i % dash.length], circumference - at);
      if (i.isEven && length > 0) {
        canvas.drawArc(rect, at / radius, math.max(length, 0.001) / radius, false, paint);
      }
      at += dash[i % dash.length];
      i++;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.radius != radius || old.width != width || old.color != color || old.dash != dash;
}
