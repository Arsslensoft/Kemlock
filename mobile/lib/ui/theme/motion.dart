import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'loop.dart';

/// The easing curves every animated element shares, `ease` in `theme.ts`.
abstract final class Ease {
  /// Press feedback, toggles, colour changes.
  static const standard = Cubic(.2, 0, 0, 1);

  /// Sheets, the tab pill, accordions, segmented thumbs.
  static const sheet = Cubic(.32, .72, 0, 1);

  /// Code digits rolling.
  static const roll = Cubic(.2, .9, .1, 1);

  /// Entrances.
  static const out = Cubic(.2, .8, .2, 1);

  /// Leaving: starts slow and speeds away, as a sheet closes.
  static const exit = Cubic(.4, 0, 1, 1);

  /// MUI's `easeInOut`, which its fades run on (dialogs, the backdrop).
  static const inOut = Cubic(.4, 0, .2, 1);

  /// CSS's `ease`, for transitions that name no curve.
  static const css = Curves.ease;
}

/// The timings shared by the components, and the switch for reduced motion.
abstract final class Motion {
  /// A pressed control shrinking or springing back.
  static const press = Duration(milliseconds: 160);

  /// Background and text colours following a state change.
  static const colour = Duration(milliseconds: 250);

  /// A bottom sheet sliding up, and down again.
  static const sheetIn = Duration(milliseconds: 560);
  static const sheetOut = Duration(milliseconds: 280);

  /// A dialog fading in, and out again (MUI's entering and leaving screen).
  static const dialogIn = Duration(milliseconds: 225);
  static const dialogOut = Duration(milliseconds: 195);

  /// A segmented control's thumb sliding to the chosen option.
  static const thumb = Duration(milliseconds: 450);

  /// Whether the phone asks for less motion. As the web app's
  /// `prefers-reduced-motion` rule does, entrances then jump to their end
  /// and loops hold still.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Shrinks its child while a finger is down and lets it go back, the
/// `&:active { transform: scale(.97) }` press feedback of the web app's
/// buttons (.94 for icon buttons). It only listens, so the child keeps its
/// own taps.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.scale = 0.97, this.enabled = true});

  final Widget child;

  /// The size while pressed, as a fraction.
  final double scale;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: widget.enabled ? (_) => _set(true) : null,
    onPointerUp: (_) => _set(false),
    onPointerCancel: (_) => _set(false),
    child: AnimatedScale(
      scale: _down ? widget.scale : 1,
      duration: Motion.reduced(context) ? Duration.zero : Motion.press,
      curve: Ease.standard,
      child: widget.child,
    ),
  );
}

/// How an [_Entrance] moves its child, at progress 0 (start) to 1 (rest).
typedef _Frame = Widget Function(double t, Widget child);

/// A one-shot entrance played once when the widget is first built, after
/// [delay], like a CSS animation with `both` fill: before it starts the
/// child waits in its first frame. [frame] gets the linear progress and
/// applies its own curve, so stepped keyframes can curve each step.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.child, required this.duration, required this.delay, required this.frame});

  final Widget child;
  final Duration duration;
  final Duration delay;
  final _Frame frame;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final Duration _total = widget.delay + widget.duration;

  // The wait is part of the animation, not a timer, so tests can settle it.
  late final AnimationController _controller = AnimationController(vsync: this, duration: _total);
  CurvedAnimation? _curved;
  late final Animation<double> _progress = _total == Duration.zero
      ? kAlwaysCompleteAnimation
      : _curved = CurvedAnimation(parent: _controller, curve: Interval(widget.delay.inMicroseconds / _total.inMicroseconds, 1));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context) || _total == Duration.zero) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _curved?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _progress,
    child: widget.child,
    // The same widgets wrap the child at rest (an identity frame), so its state survives the end of the entrance.
    builder: (context, child) => widget.frame(_progress.value, child!),
  );
}

/// Fades the child in while it rises 12px into place: `motion.rise`, the
/// entrance of cards, empty states and list items. Give list items a
/// growing [delay] to stagger them.
class Rise extends StatelessWidget {
  const Rise({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 500),
    this.delay = Duration.zero,
    this.curve = Ease.out,
    this.offset = 12,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final Curve curve;

  /// How far below its place the child starts, in logical pixels.
  final double offset;

  @override
  Widget build(BuildContext context) => _Entrance(
    duration: duration,
    delay: delay,
    frame: (t, child) {
      final v = curve.transform(t);
      return Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, offset * (1 - v)), child: child),
      );
    },
    child: child,
  );
}

/// Fades the child in: `motion.fade`.
class FadeIn extends StatelessWidget {
  const FadeIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 500),
    this.delay = Duration.zero,
    this.curve = Ease.out,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final Curve curve;

  @override
  Widget build(BuildContext context) => _Entrance(
    duration: duration,
    delay: delay,
    frame: (t, child) => Opacity(opacity: curve.transform(t).clamp(0.0, 1.0), child: child),
    child: child,
  );
}

/// Pops the child in from a third of its size, past full size and back:
/// `motion.pop`, for check marks and badges that appear. As in CSS, the
/// [curve] runs on each step (0 to 60% and 60 to 100%) on its own.
class PopIn extends StatelessWidget {
  const PopIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 450),
    this.delay = Duration.zero,
    this.curve = Ease.roll,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final Curve curve;

  /// The scale and opacity of `motion.pop` at progress [t].
  static ({double scale, double opacity}) frameAt(double t, Curve curve) {
    if (t < 0.6) {
      final v = curve.transform(t / 0.6);
      return (scale: 0.3 + (1.18 - 0.3) * v, opacity: v);
    }
    final v = curve.transform((t - 0.6) / 0.4);
    return (scale: 1.18 + (1 - 1.18) * v, opacity: 1);
  }

  @override
  Widget build(BuildContext context) => _Entrance(
    duration: duration,
    delay: delay,
    frame: (t, child) {
      final f = frameAt(t, curve);
      return Opacity(
        opacity: f.opacity.clamp(0.0, 1.0),
        child: Transform.scale(scale: f.scale, child: child),
      );
    },
    child: child,
  );
}

/// Brings a toast in: up 18px from 96% of its size, fading in, over .45s
/// on [Ease.roll] (`motion.toastIn`).
class ToastIn extends StatelessWidget {
  const ToastIn({super.key, required this.child, this.duration = const Duration(milliseconds: 450), this.curve = Ease.roll});

  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) => _Entrance(
    duration: duration,
    delay: Duration.zero,
    frame: (t, child) {
      final v = curve.transform(t);
      return Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - v)),
          child: Transform.scale(scale: 0.96 + 0.04 * v, child: child),
        ),
      );
    },
    child: child,
  );
}

/// A loop that redraws its child each frame: [frame] wraps the [child] for
/// the phase, through the same widgets whether the loop runs or holds
/// still, so the child keeps its state.
abstract class _FramedLoopState<T extends StatefulWidget> extends LoopState<T> {
  /// The child at [phase], or as it is when [phase] is null.
  Widget frame(double? phase, Widget child);

  Widget get child;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<double?>(valueListenable: phase, child: child, builder: (context, phase, child) => frame(phase, child!));
}

/// Turns the child round once every [period], clockwise or, with
/// [reverse], back: `motion.spin` and `motion.spinReverse`.
class Spin extends StatefulWidget {
  const Spin({super.key, required this.child, this.period = const Duration(milliseconds: 900), this.reverse = false});

  final Widget child;
  final Duration period;
  final bool reverse;

  @override
  State<Spin> createState() => _SpinState();
}

class _SpinState extends _FramedLoopState<Spin> {
  @override
  Duration get period => widget.period;

  // A spinner says the app is working, so it turns for as long as it is shown.
  @override
  bool get decorative => false;

  @override
  Widget get child => widget.child;

  @override
  Widget frame(double? phase, Widget child) =>
      Transform.rotate(angle: (widget.reverse ? -1 : 1) * (phase ?? 0) * 2 * math.pi, child: child);
}

/// Swells the child to [scale] and back once every [period]: `motion.breathe`,
/// the slow pulse of the vault emblem and the splash mark. The [curve] runs
/// on each half on its own, as CSS does between keyframes.
class Breathe extends StatefulWidget {
  const Breathe({
    super.key,
    required this.child,
    this.period = const Duration(seconds: 4),
    this.curve = Curves.easeInOut,
    this.scale = 1.035,
  });

  final Widget child;
  final Duration period;
  final Curve curve;
  final double scale;

  @override
  State<Breathe> createState() => _BreatheState();
}

class _BreatheState extends _FramedLoopState<Breathe> {
  @override
  Duration get period => widget.period;

  @override
  Widget get child => widget.child;

  @override
  Widget frame(double? phase, Widget child) {
    final v = phase == null
        ? 0.0
        : phase < 0.5
        ? widget.curve.transform(phase * 2)
        : 1 - widget.curve.transform((phase - 0.5) * 2);
    return Transform.scale(scale: 1 + (widget.scale - 1) * v, child: child);
  }
}

/// Grows the child to 1.9 times its size while it fades out, over and over:
/// `motion.halo`, the rings that spread from the lock screen's unlock
/// button. Give each ring a different [delay] to stagger them.
class Halo extends StatefulWidget {
  const Halo({
    super.key,
    required this.child,
    this.period = const Duration(milliseconds: 2800),
    this.delay = Duration.zero,
    this.curve = const Cubic(.2, .6, .2, 1),
  });

  final Widget child;
  final Duration period;
  final Duration delay;
  final Curve curve;

  @override
  State<Halo> createState() => _HaloState();
}

class _HaloState extends _FramedLoopState<Halo> {
  @override
  Duration get period => widget.period;

  @override
  Duration get delay => widget.delay;

  @override
  Widget get child => widget.child;

  @override
  Widget frame(double? phase, Widget child) {
    final v = phase == null ? 0.0 : widget.curve.transform(phase);
    return Opacity(
      opacity: phase == null ? 1 : (0.9 * (1 - v)).clamp(0.0, 1.0),
      child: Transform.scale(scale: 1 + 0.9 * v, child: child),
    );
  }
}
