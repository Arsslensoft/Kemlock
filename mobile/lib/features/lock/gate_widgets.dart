import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';

/// The column the setup and lock screens stand in, as their `<main>` was
/// laid out: [maxWidth] wide at most and centred, 24 at the sides, 48 below
/// the notch and 28 above the home bar. It is at least as tall as the
/// screen, so an [Expanded] in [child] pushes what follows it to the
/// bottom, and it scrolls when the keyboard or a large text size leaves too
/// little room.
class GateLayout extends StatelessWidget {
  const GateLayout({super.key, required this.maxWidth, required this.child});

  final double maxWidth;

  /// Usually a [Column]. Its height is measured before it is laid out, so it
  /// must not hold a [LayoutBuilder] that isn't inside a box of fixed size.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth, minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(padding: EdgeInsets.fromLTRB(24, safe.top + 48, 24, safe.bottom + 28), child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The eye at the end of a password field, which shows or hides what was
/// typed. Screen readers call it "Show password" or "Hide password".
class RevealPasswordButton extends StatelessWidget {
  const RevealPasswordButton({super.key, required this.shown, required this.onPressed});

  /// Whether the password shows now.
  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    style: IconButton.styleFrom(foregroundColor: context.bmc.faint),
    icon: Icon(
      shown ? Icons.visibility_off_rounded : Icons.visibility_rounded,
      semanticLabel: context.t(shown ? 'lock.hidePassword' : 'lock.showPassword'),
    ),
  );
}

/// A dash of a circle turning round once every .9s, as the web app drew a
/// spinner with a dashed SVG circle: [length] of the circle of [radius],
/// [strokeWidth] wide with round ends, starting at three o'clock. It fills
/// its box, centred in it. Decoration only.
class SpinningArc extends StatelessWidget {
  const SpinningArc({super.key, required this.color, required this.radius, required this.strokeWidth, required this.length});

  final Color color;
  final double radius;
  final double strokeWidth;
  final double length;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Spin(
      child: CustomPaint(
        painter: _ArcPainter(color: color, radius: radius, strokeWidth: strokeWidth, length: length),
        child: const SizedBox.expand(),
      ),
    ),
  );
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color, required this.radius, required this.strokeWidth, required this.length});

  final Color color;
  final double radius;
  final double strokeWidth;
  final double length;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    canvas.drawArc(
      rect,
      0,
      length / radius,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.color != color || old.radius != radius || old.strokeWidth != strokeWidth || old.length != length;
}
