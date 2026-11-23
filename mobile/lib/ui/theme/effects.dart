/// The app's decorative effects (openspec: visual-effects): light, sheen,
/// glow, scan and reveal, beside the motion of `motion.dart` and on the same
/// loop driver, which holds them still under reduced motion, stops them
/// while they cannot be seen, rests them when the screen is left alone and
/// lets tests pin them (`loop.dart`).
///
/// An effect is decoration only: nothing here is the only sign of a state,
/// and a screen is correct with every effect removed. Each paints its own
/// layer and nothing else, takes no touch, has no semantics and leaves the
/// size and place of what it decorates alone.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_theme.dart';
import 'loop.dart';
import 'motion.dart';

/// A soft light in the accent colour that drifts slowly behind a surface:
/// two of them behind a tab page, one behind a sheet. Fill the surface with
/// it, under the content; a surface with rounded corners clips it itself.
///
/// The first light sits off the top right corner and drifts 70 left and 50
/// down while it grows to 1.3 times its size, over 12 seconds, and back.
/// The second sits at the bottom left and makes the same way over 16
/// seconds, starting from its far end. Under reduced motion both hold
/// still at their starting place.
class AmbientLight extends StatelessWidget {
  const AmbientLight({super.key, this.lights = 1}) : assert(lights == 1 || lights == 2, 'A surface has one light or two');

  /// How many lights: 2 behind a page, 1 behind a sheet.
  final int lights;

  /// How far a light drifts over its period.
  static const drift = Offset(-70, 50);

  /// How much a light has grown at the end of its drift.
  static const growth = 1.3;

  /// Where the light [index] (0 or 1) is on a surface of [size] at [phase]:
  /// its middle, and the radius at which it has faded to nothing.
  static ({Offset center, double radius}) lightAt(int index, Size size, double? phase) {
    final first = index == 0;
    // A 340 box 110 off the top and right edges, and a 320 one 140 off the left edge and 60 above the bottom.
    final box = first ? 340.0 : 320.0;
    final start = first ? Offset(size.width + 110 - box / 2, box / 2 - 110) : Offset(box / 2 - 140, size.height - 60 - box / 2);
    // The second light plays the same drift from its far end (`alternate-reverse`).
    final t = phase == null ? 0.0 : Curves.easeInOut.transform(first ? phase : 1 - phase);
    // The gradient reaches nothing at 66% of the way to the box's corner.
    return (center: start + drift * t, radius: box / 2 * math.sqrt2 * 0.66 * (1 + (growth - 1) * t));
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [for (var index = 0; index < lights; index++) _Light(index: index)],
      ),
    ),
  );
}

class _Light extends StatefulWidget {
  const _Light({required this.index});

  final int index;

  @override
  State<_Light> createState() => _LightState();
}

class _LightState extends LoopState<_Light> {
  @override
  Duration get period => Duration(seconds: widget.index == 0 ? 12 : 16);

  @override
  bool get alternate => true;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return RepaintBoundary(
      child: CustomPaint(
        painter: AmbientLightPainter(index: widget.index, color: widget.index == 0 ? b.ambient : b.ambient2, phase: phase),
        size: Size.infinite,
      ),
    );
  }
}

/// Paints one light of an [AmbientLight]: a radial gradient from [color]
/// to nothing, where [AmbientLight.lightAt] puts it.
class AmbientLightPainter extends CustomPainter {
  const AmbientLightPainter({required this.index, required this.color, required this.phase}) : super(repaint: phase);

  final int index;
  final Color color;
  final ValueListenable<double?> phase;

  @override
  void paint(Canvas canvas, Size size) {
    final light = AmbientLight.lightAt(index, size, phase.value);
    final bounds = Rect.fromCircle(center: light.center, radius: light.radius);
    canvas.drawCircle(
      light.center,
      light.radius,
      Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(AmbientLightPainter old) => old.index != index || old.color != color || old.phase != phase;
}

/// The glows that stand still: the soft accent shadows of a main button, a
/// switch that is on, an accent tile, a progress bar and a card with a
/// [NeonBorder]. They are the same with reduced motion on or off. Each is
/// the `glow` token at the strength the mockups give it when dark, and at
/// the same share of the token when light.
abstract final class StandingGlow {
  static Color _at(BmcTokens b, double strength) => b.glow.withValues(alpha: (b.glow.a * strength / BmcTokens.dark.glow.a).clamp(0.0, 1.0));

  /// Under a screen's main button: `0 8px 28px` at .3.
  static List<BoxShadow> button(BmcTokens b) => [BoxShadow(color: _at(b, 0.3), offset: const Offset(0, 8), blurRadius: 28)];

  /// Under the tab bar's Add button: `0 8px 28px` at .35.
  static List<BoxShadow> add(BmcTokens b) => [BoxShadow(color: _at(b, 0.35), offset: const Offset(0, 8), blurRadius: 28)];

  /// Round the track of a switch that is on: `0 0 14px` at .45.
  static List<BoxShadow> toggle(BmcTokens b) => [BoxShadow(color: _at(b, 0.45), blurRadius: 14)];

  /// Round an icon tile in the accent colour: `0 0 12px` at .22.
  static List<BoxShadow> tile(BmcTokens b) => [BoxShadow(color: _at(b, 0.22), blurRadius: 12)];

  /// Round a card with a [NeonBorder]: `0 0 22px` at .28.
  static List<BoxShadow> card(BmcTokens b) => [BoxShadow(color: _at(b, 0.28), blurRadius: 22)];

  /// Round the filled part of a progress bar: `0 0 10px` at .7.
  static List<BoxShadow> bar(BmcTokens b) => [BoxShadow(color: _at(b, 0.7), blurRadius: 10)];
}

/// Passes a slanted band of light across [child], a screen's main button,
/// once every 4.5 seconds (the first after 1.2), and gives it a soft
/// standing shadow in the accent colour. [faint] is the weaker band of a
/// chip: every 5.5 seconds, the first after 2, with no shadow.
///
/// Only a filled main button takes one, never an outlined, text or
/// destructive button; pass `enabled: false` while the button cannot be
/// pressed, which takes the band and the shadow away. The band is clipped
/// to [borderRadius], which is the child's own. Under reduced motion the
/// shadow stays and no band passes.
class Sheen extends StatefulWidget {
  const Sheen({
    super.key,
    required this.child,
    this.enabled = true,
    this.faint = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  final Widget child;
  final bool enabled;
  final bool faint;

  /// The child's corners: 18 for a large button.
  final BorderRadius borderRadius;

  /// The part of each period the band waits off the left edge before it crosses.
  static const wait = 0.62;

  /// How wide the band is on a child [width] wide.
  static double bandWidth(double width, {bool faint = false}) => width * (faint ? 0.4 : 0.38);

  /// The left edge of the band on a child [width] wide at [phase], before
  /// its slant: 1.4 band widths off the left edge until [wait], then across
  /// to 3.4 band widths from it, which is past the right edge (`k-sheen`).
  static double bandLeft(double phase, double width, {bool faint = false}) {
    final crossed = phase <= wait ? 0.0 : Ease.standard.transform((phase - wait) / (1 - wait));
    return (-1.4 + 4.8 * crossed) * bandWidth(width, faint: faint);
  }

  @override
  State<Sheen> createState() => _SheenState();
}

class _SheenState extends LoopState<Sheen> {
  @override
  Duration get period => Duration(milliseconds: widget.faint ? 5500 : 4500);

  @override
  Duration get delay => Duration(milliseconds: widget.faint ? 2000 : 1200);

  @override
  bool get enabled => widget.enabled;

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    // A chip's band is .22 where a button's is .5.
    final color = widget.faint ? b.sheen.withValues(alpha: b.sheen.a * 0.44) : b.sheen;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        boxShadow: widget.enabled && !widget.faint ? StandingGlow.button(b) : null,
      ),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: ClipRRect(
                    borderRadius: widget.borderRadius,
                    child: CustomPaint(
                      painter: SheenPainter(color: color, faint: widget.faint, phase: phase),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the band of a [Sheen]: [color] fading to nothing at both sides,
/// slanted 20 degrees.
class SheenPainter extends CustomPainter {
  const SheenPainter({required this.color, required this.faint, required this.phase}) : super(repaint: phase);

  final Color color;
  final bool faint;
  final ValueListenable<double?> phase;

  static final _slant = math.tan(20 * math.pi / 180);

  @override
  void paint(Canvas canvas, Size size) {
    final at = phase.value;
    if (at == null || at <= Sheen.wait || size.isEmpty) return;
    final width = Sheen.bandWidth(size.width, faint: faint);
    final band = Rect.fromCenter(center: Offset.zero, width: width, height: size.height);
    canvas
      ..save()
      ..translate(Sheen.bandLeft(at, size.width, faint: faint) + width / 2, size.height / 2)
      ..skew(-_slant, 0)
      ..drawRect(
        band,
        Paint()..shader = LinearGradient(colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)]).createShader(band),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(SheenPainter old) => old.color != color || old.faint != faint || old.phase != phase;
}

/// A glow that swells round [child] and fades again once every [period]:
/// round a selected option card, the active tab and an information alert.
/// While it is not [active] nothing is drawn and nothing runs, so a list of
/// options wraps each in one and turns on the selected one's.
///
/// What it marks is always said another way too (an option's filled mark
/// and accent border, a tab's colour and its selected state): the glow
/// only draws the eye. The shadow has a fixed blur of [blur] and only its
/// opacity changes, up to the `glow` token and back, so it is rasterised
/// once. It lies outside the child's shape, [borderRadius], and never under
/// it. Under reduced motion there is no glow.
class Glow extends StatefulWidget {
  const Glow({
    super.key,
    required this.child,
    this.active = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.period = const Duration(milliseconds: 3200),
  });

  final Widget child;
  final bool active;

  /// The child's corners: 18 for an option card, 14 for an alert.
  final BorderRadius borderRadius;
  final Duration period;

  /// The blur of the shadow, as `box-shadow: 0 0 24px`.
  static const blur = 24.0;

  /// How strong the glow is at [phase], from 0 to 1: nothing at the start
  /// and the end of a period, full half way, eased in and out each way
  /// (`k-glow`).
  static double strengthAt(double? phase) {
    if (phase == null) return 0;
    return Curves.easeInOut.transform(phase < 0.5 ? phase * 2 : 2 - phase * 2).clamp(0.0, 1.0);
  }

  @override
  State<Glow> createState() => _GlowState();
}

class _GlowState extends LoopState<Glow> {
  @override
  Duration get period => widget.period;

  @override
  bool get enabled => widget.active;

  @override
  Widget build(BuildContext context) {
    // Room for the blur, so the layer that holds the shadow is as large as what it paints.
    const room = Glow.blur * 2;
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -room,
          top: -room,
          right: -room,
          bottom: -room,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: ValueListenableBuilder<double?>(
                  valueListenable: phase,
                  builder: (context, phase, shadow) => Opacity(opacity: Glow.strengthAt(phase), child: shadow),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: GlowPainter(color: context.bmc.glow, borderRadius: widget.borderRadius, inset: room),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// Paints the shadow of a [Glow] at its fullest: [color], blurred, outside
/// the rounded box that lies [inset] inside the painted area.
class GlowPainter extends CustomPainter {
  const GlowPainter({required this.color, required this.borderRadius, required this.inset, this.blur = Glow.blur});

  final Color color;
  final BorderRadius borderRadius;
  final double inset;
  final double blur;

  @override
  void paint(Canvas canvas, Size size) {
    final box = (Offset.zero & size).deflate(inset);
    if (box.isEmpty) return;
    canvas.drawRRect(
      borderRadius.toRRect(box),
      Paint()
        ..color = color
        // A CSS blur radius is twice the sigma of its Gaussian.
        ..maskFilter = MaskFilter.blur(BlurStyle.outer, blur / 2),
    );
  }

  @override
  bool shouldRepaint(GlowPainter old) => old.color != color || old.borderRadius != borderRadius || old.inset != inset || old.blur != blur;
}

/// A border round a card along which a bright light travels once every
/// [period], with a soft standing glow round the card: the card of a
/// connected security key. The card says in words what the light
/// accompanies; the border is only light.
///
/// The child is padded by [width] on every side, as it would be inside a
/// plain padding of that much, and its corners should be [borderRadius]
/// less [width]. The light is a sweep of the accent that ends in the
/// `neonHot` token, turned round the card's middle. Under reduced motion
/// the border is an even `accentLine` with no bright point, and the glow
/// stays.
class NeonBorder extends StatefulWidget {
  const NeonBorder({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.period = const Duration(milliseconds: 3200),
  });

  final Widget child;

  /// The border's outer corners: 22, round a card whose own are 20.5.
  final BorderRadius borderRadius;
  final Duration period;

  /// How wide the border is.
  static const width = 1.5;

  /// The angle of the bright point at [phase], clockwise from the middle of
  /// the top edge as seen from the card's middle: one turn a period.
  static double hotAngle(double phase) => 2 * math.pi * phase;

  /// Where the bright point is on the edge of a card of [size] at [phase].
  static Offset hotPoint(Size size, double phase) {
    final angle = hotAngle(phase);
    final direction = Offset(math.sin(angle), -math.cos(angle));
    final reach = math.min(
      direction.dx == 0 ? double.infinity : size.width / 2 / direction.dx.abs(),
      direction.dy == 0 ? double.infinity : size.height / 2 / direction.dy.abs(),
    );
    return size.center(Offset.zero) + direction * reach;
  }

  @override
  State<NeonBorder> createState() => _NeonBorderState();
}

class _NeonBorderState extends LoopState<NeonBorder> {
  @override
  Duration get period => widget.period;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: widget.borderRadius, boxShadow: StandingGlow.card(b)),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: NeonBorderPainter(
                      borderRadius: widget.borderRadius,
                      body: p.primary,
                      hot: b.neonHot,
                      rest: b.accentLine,
                      phase: phase,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.all(NeonBorder.width), child: widget.child),
        ],
      ),
    );
  }
}

/// Paints the ring of a [NeonBorder], between its outer rounded box and the
/// one [NeonBorder.width] inside it: an even [rest] line while the phase is
/// null, and otherwise a faint line of [body] with the light on it, a sweep
/// that rises through [body] to [hot] and ends there.
class NeonBorderPainter extends CustomPainter {
  const NeonBorderPainter({required this.borderRadius, required this.body, required this.hot, required this.rest, required this.phase})
    : super(repaint: phase);

  final BorderRadius borderRadius;
  final Color body;
  final Color hot;
  final Color rest;
  final ValueListenable<double?> phase;

  /// Where in the sweep the bright point is: `#D6ECFF 96%` of the mockups' conic gradient.
  static const _hotStop = 0.96;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    final outer = borderRadius.toRRect(bounds);
    final inner = outer.deflate(NeonBorder.width);
    final at = phase.value;
    if (at == null) {
      canvas.drawDRRect(outer, inner, Paint()..color = rest);
      return;
    }
    canvas.drawDRRect(outer, inner, Paint()..color = body.withValues(alpha: 0.18));
    final clear = body.withValues(alpha: 0);
    // A sweep starts at three o'clock; this turns its bright point to twelve, then on by the phase.
    final turn = NeonBorder.hotAngle(at) - math.pi / 2 - 2 * math.pi * _hotStop;
    canvas.drawDRRect(
      outer,
      inner,
      Paint()
        ..shader = SweepGradient(
          colors: [clear, clear, body.withValues(alpha: 0.5), body, hot, hot.withValues(alpha: 0)],
          stops: const [0, 0.62, 0.76, 0.88, _hotStop, 1],
          transform: GradientRotation(turn),
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(NeonBorderPainter old) =>
      old.borderRadius != borderRadius || old.body != body || old.hot != hot || old.rest != rest || old.phase != phase;
}

/// Passes a faint band with a bright lower edge down over [child], such as
/// a key's fingerprint, once every 3.2 seconds (the first after 1): from
/// wholly above it to wholly below, clipped to it. The band is 42
/// hundredths of the child's height and never hides what is under it,
/// which can still be read, selected and tapped.
///
/// Under reduced motion no band is drawn: a still one would lie over part
/// of what the person is comparing.
class ScanLine extends StatefulWidget {
  const ScanLine({super.key, required this.child});

  final Widget child;

  /// How tall the band is over a child [height] tall.
  static double bandHeight(double height) => height * 0.42;

  /// The top of the band over a child [height] tall at [phase]: from 1.1
  /// band heights above the child's top to 2.9 below it, eased in and out
  /// (`k-scan`).
  static double bandTop(double phase, double height) => (-1.1 + 4 * Curves.easeInOut.transform(phase)) * bandHeight(height);

  @override
  State<ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends LoopState<ScanLine> {
  @override
  Duration get period => const Duration(milliseconds: 3200);

  @override
  Duration get delay => const Duration(seconds: 1);

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: ClipRect(
                  child: CustomPaint(
                    painter: ScanLinePainter(color: b.accentSoft, edge: b.accentText.withValues(alpha: 0.55), phase: phase),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints the band of a [ScanLine]: [color] fading to nothing above and
/// below, over a 1px [edge] along its bottom.
class ScanLinePainter extends CustomPainter {
  const ScanLinePainter({required this.color, required this.edge, required this.phase}) : super(repaint: phase);

  final Color color;
  final Color edge;
  final ValueListenable<double?> phase;

  @override
  void paint(Canvas canvas, Size size) {
    final at = phase.value;
    if (at == null || size.isEmpty) return;
    final band = Rect.fromLTWH(0, ScanLine.bandTop(at, size.height), size.width, ScanLine.bandHeight(size.height));
    if (band.bottom <= 0 || band.top >= size.height) return;
    final clear = color.withValues(alpha: 0);
    canvas
      ..drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [clear, color, clear],
          ).createShader(band),
      )
      ..drawRect(Rect.fromLTWH(0, band.bottom - 1, size.width, 1), Paint()..color = edge);
  }

  @override
  bool shouldRepaint(ScanLinePainter old) => old.color != color || old.edge != edge || old.phase != phase;
}

/// Brings [child] in once, as a decrypted message appears: it is uncovered
/// from its start edge to its end while it sharpens from a blur of 6 and
/// its opacity goes from .3 to 1, over 1.4 seconds after .8.
///
/// The child is laid out whole from the first frame, so nothing moves, and
/// a screen reader is given all of it at once. When the reveal ends the
/// clip and the filter leave the tree, and a rebuild does not play it
/// again. Under reduced motion, and under a pinned [EffectsScope], the
/// child is whole and sharp from the first frame.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1400),
    this.delay = const Duration(milliseconds: 800),
    this.curve = Ease.out,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final Curve curve;

  /// The blur at the start, as `filter: blur(6px)`.
  static const blur = 6.0;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  // The child keeps its state when the clip and the filter round it go.
  final _child = GlobalKey();

  @override
  Widget build(BuildContext context) => EffectOnce(
    duration: widget.duration,
    delay: widget.delay,
    builder: (context, progress) {
      final child = KeyedSubtree(key: _child, child: widget.child);
      if (progress >= 1) return child;
      final t = widget.curve.transform(progress).clamp(0.0, 1.0);
      final sigma = Reveal.blur * (1 - t);
      return Opacity(
        opacity: 0.3 + 0.7 * t,
        child: RevealClip(
          revealed: t,
          textDirection: Directionality.of(context),
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Paints only the [revealed] part of its child, from 0 (none) to 1 (all),
/// measured from the start edge for [textDirection]. It clips the painting
/// only: the child keeps its size, its touches and its semantics, so a
/// screen reader has the whole of a text that is still being revealed.
class RevealClip extends SingleChildRenderObjectWidget {
  const RevealClip({super.key, required this.revealed, required this.textDirection, super.child});

  final double revealed;
  final TextDirection textDirection;

  /// The part of a child of [size] that is painted.
  static Rect rectFor(Size size, double revealed, TextDirection textDirection) {
    final width = size.width * revealed.clamp(0.0, 1.0);
    return Rect.fromLTWH(textDirection == TextDirection.ltr ? 0 : size.width - width, 0, width, size.height);
  }

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderRevealClip(revealed, textDirection);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) => (renderObject as _RenderRevealClip)
    ..revealed = revealed
    ..textDirection = textDirection;
}

class _RenderRevealClip extends RenderProxyBox {
  _RenderRevealClip(this._revealed, this._textDirection);

  double _revealed;
  set revealed(double value) {
    if (value == _revealed) return;
    _revealed = value;
    markNeedsPaint();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      RevealClip.rectFor(size, _revealed, _textDirection),
      super.paint,
      oldLayer: layer as ClipRectLayer?,
    );
  }
}
