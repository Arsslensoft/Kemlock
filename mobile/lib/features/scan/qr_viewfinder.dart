import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/scanner_source.dart';
import '../../ui/ui.dart';
import '../settings/auto_lock.dart';

/// The ink of what floats over the camera, which is dark in either scheme.
const _onCamera = Color(0xFFF3F4F6);

/// A live camera viewfinder that reports the QR codes it sees:
/// `QRScanner.tsx`.
///
/// Corners frame the middle of the picture and breathe while the camera
/// looks; once it is live a line sweeps through them, a chip below says
/// what is happening (starting, scanning, or that the camera was refused)
/// and glass buttons flip the camera and switch the torch.
///
/// [onScan] gets each code the camera reads, once: the same code held in
/// front of the camera counts once until the camera starts again (it was
/// [found], flipped, or the app came back from the background). Set [found]
/// when a code was accepted: the camera stops and the viewfinder freezes,
/// locked on, with a check in the middle, until [found] is cleared.
///
/// The camera runs only while the viewfinder is on screen: it starts once
/// it is shown, stops while a page covers it or the app is in the
/// background, and goes with it. It comes from [scannerSourceProvider];
/// tests swap in `FakeScanner` (`test/fakes/fake_scanner.dart`).
class QrViewfinder extends ConsumerStatefulWidget {
  const QrViewfinder({super.key, required this.onScan, this.found = false});

  final ValueChanged<String> onScan;

  /// A code was accepted: freeze the viewfinder in its "locked on" state.
  final bool found;

  @override
  ConsumerState<QrViewfinder> createState() => _QrViewfinderState();
}

class _QrViewfinderState extends ConsumerState<QrViewfinder> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final ScannerSource _source;
  late final AutoLockHolds _holds;
  StreamSubscription<String>? _codes;

  /// The corners swelling in and out, and the line sweeping up and down.
  late final AnimationController _breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 2100));
  late final CurvedAnimation _sweepCurve = CurvedAnimation(parent: _sweep, curve: Curves.easeInOut);

  /// Whether the first frame is up: the preview has to be on screen before the camera starts.
  bool _ready = false;

  /// Whether the camera was asked to run.
  bool _on = false;

  /// The app is in the foreground (or only behind a system prompt).
  bool _foreground = true;

  /// No page covers the viewfinder.
  bool _visible = true;

  /// The code reported last since the camera started, which isn't reported again.
  String? _last;

  bool get _wanted => _ready && !widget.found && _foreground && _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _holds = ref.read(autoLockHoldsProvider);
    _source = ref.read(scannerSourceProvider)();
    _source.state.addListener(_onState);
    _codes = _source.codes.listen(_onCode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ready = true;
      _syncCamera();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A page pushed over this one turns its tickers off: the viewfinder is out of sight.
    _visible = TickerMode.valuesOf(context).enabled;
    _syncCamera();
    _syncAnimations();
  }

  @override
  void didUpdateWidget(QrViewfinder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.found != widget.found) {
      _syncCamera();
      _syncAnimations();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive comes with the camera permission prompt and the app switcher, while the app is still
    // on screen: stopping then would cancel the start that asked for permission.
    final foreground = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _syncCamera();
  }

  /// Starts or stops the camera to match [_wanted].
  void _syncCamera() {
    final wanted = _wanted;
    if (wanted == _on) return;
    _on = wanted;
    if (wanted) {
      _last = null;
      // The first start shows the system's permission prompt, which mustn't lock the vault.
      unawaited(_holds.withHeld(_source.start));
    } else {
      unawaited(_source.stop());
    }
  }

  /// The corners breathe until a code is found, and the line sweeps while the camera is live;
  /// both hold still under reduced motion and for a source that says not to animate.
  void _syncAnimations() {
    final moving = _source.animated && !Motion.reduced(context) && !widget.found;
    if (moving) {
      if (!_breathe.isAnimating) unawaited(_breathe.repeat());
    } else {
      _breathe.stop();
      if (_breathe.value != 0) _breathe.value = 0;
    }
    if (moving && _source.state.value.isLive) {
      if (!_sweep.isAnimating) unawaited(_sweep.repeat(reverse: true));
    } else {
      _sweep.stop();
    }
  }

  void _onState() {
    if (!mounted) return;
    _syncAnimations();
    setState(() {});
  }

  void _onCode(String value) {
    if (!mounted || !_on || widget.found || value.isEmpty || value == _last) return;
    _last = value;
    widget.onScan(value);
  }

  void _flip() {
    _last = null;
    unawaited(_source.switchCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _source.state.removeListener(_onState);
    unawaited(_codes?.cancel());
    unawaited(_source.dispose());
    _sweepCurve.dispose();
    _breathe.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _source.state.value;
    final found = widget.found;
    final live = state.isLive && !found;
    final reduced = Motion.reduced(context);
    final primary = context.palette.primary;
    final hint = switch (state.phase) {
      ScannerPhase.failed => context.t('qrScanner.error.denied'),
      ScannerPhase.live => context.t('qrScanner.scanning'),
      _ => context.t('qrScanner.starting'),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        // As wide as it is given, 1.08 times as tall, and no taller than 420.
        final width = constraints.maxWidth;
        var height = math.min(width * 1.08, 420.0);
        if (constraints.hasBoundedHeight) height = math.min(height, constraints.maxHeight);
        // Kept high enough that the hint chip never covers the bottom corners.
        final frame = found
            ? EdgeInsets.fromLTRB(width * .27, height * .22, width * .27, height * .32)
            : EdgeInsets.fromLTRB(width * .16, height * .11, width * .16, height * .25);

        return SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                // radial-gradient(120% 90% at 50% 38%, #1A1C21 0%, #050506 72%)
                gradient: RadialGradient(
                  center: Alignment(0, -.24),
                  radius: 1.1,
                  colors: [Color(0xFF1A1C21), Color(0xFF050506)],
                  stops: [0, .72],
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedOpacity(
                    opacity: live
                        ? 1
                        : found
                        ? .35
                        : 0,
                    duration: reduced ? Duration.zero : const Duration(milliseconds: 400),
                    curve: Ease.css,
                    child: ExcludeSemantics(child: _source.buildPreview(context)),
                  ),
                  AnimatedPositioned(
                    left: frame.left,
                    top: frame.top,
                    right: frame.right,
                    bottom: frame.bottom,
                    duration: reduced ? Duration.zero : const Duration(milliseconds: 600),
                    curve: Ease.sheet,
                    child: ExcludeSemantics(
                      child: _Frame(
                        breathe: _breathe,
                        sweep: _sweepCurve,
                        sweeping: live,
                        found: found,
                        color: found ? primary : _onCamera,
                        primary: primary,
                        reduced: reduced,
                      ),
                    ),
                  ),
                  if (!found)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 18,
                      child: IgnorePointer(child: Center(child: _HintChip(hint))),
                    ),
                  if (live && state.cameraCount > 1)
                    Positioned(
                      top: 16,
                      left: 16,
                      child: _GlassButton(icon: Icons.flip_camera_ios_rounded, label: context.t('qrScanner.flip'), onPressed: _flip),
                    ),
                  if (live && state.torchAvailable)
                    Positioned(
                      top: 16,
                      right: 16,
                      child: _GlassButton(
                        icon: state.torchOn ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
                        label: context.t('qrScanner.torch'),
                        toggled: state.torchOn,
                        onPressed: () => unawaited(_source.setTorch(!state.torchOn)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The corners, the sweeping line and, once a code is found, the ring and the check.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.breathe,
    required this.sweep,
    required this.sweeping,
    required this.found,
    required this.color,
    required this.primary,
    required this.reduced,
  });

  final Animation<double> breathe;
  final Animation<double> sweep;
  final bool sweeping;
  final bool found;
  final Color color;
  final Color primary;
  final bool reduced;

  /// `breatheIn`: down to .965 at half way and back, easing in and out each half.
  static double _breatheScale(double phase) {
    final v = phase < .5 ? Curves.easeInOut.transform(phase * 2) : 1 - Curves.easeInOut.transform((phase - .5) * 2);
    return 1 - .035 * v;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.maxHeight;
      return Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: breathe,
            builder: (context, child) => Transform.scale(scale: _breatheScale(breathe.value), child: child),
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: reduced ? Duration.zero : const Duration(milliseconds: 400),
              curve: Ease.css,
              builder: (context, color, _) => CustomPaint(painter: _CornersPainter(color ?? this.color)),
            ),
          ),
          if (sweeping)
            AnimatedBuilder(
              animation: sweep,
              builder: (context, child) => Positioned(left: 14, right: 14, top: height * (.03 + .92 * sweep.value), child: child!),
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  color: primary,
                  borderRadius: BorderRadius.circular(1),
                  boxShadow: [BoxShadow(color: context.bmc.accentLine, blurRadius: 18, spreadRadius: 3)],
                ),
              ),
            ),
          if (found) ...[
            Positioned.fill(
              left: -6,
              top: -6,
              right: -6,
              bottom: -6,
              child: _Ping(color: primary, reduced: reduced),
            ),
            Center(
              child: PopIn(
                duration: const Duration(milliseconds: 500),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
                  child: Icon(Icons.check_rounded, size: 30, color: context.palette.onPrimary),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// The ring that spreads from the frame and fades as a code is found: `ping`.
class _Ping extends StatelessWidget {
  const _Ping({required this.color, required this.reduced});

  final Color color;
  final bool reduced;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: reduced ? Duration.zero : const Duration(milliseconds: 900),
    curve: Ease.out,
    builder: (context, t, child) => Opacity(
      opacity: (.9 * (1 - t)).clamp(0.0, 1.0),
      child: Transform.scale(scale: .9 + .4 * t, child: child),
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color, width: 2),
      ),
    ),
  );
}

/// Four 42px corners drawn in 3px strokes, each rounded to 16px.
class _CornersPainter extends CustomPainter {
  const _CornersPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const arm = 42.0;
    const stroke = 3.0;
    const half = stroke / 2;
    // The stroke runs along the middle of a 3px border whose outer edge is rounded to 16px.
    const radius = Radius.circular(16 - half);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final w = size.width;
    final h = size.height;
    final r = radius.x;
    canvas
      ..drawPath(
        Path()
          ..moveTo(half, arm)
          ..lineTo(half, half + r)
          ..arcToPoint(Offset(half + r, half), radius: radius)
          ..lineTo(arm, half),
        paint,
      )
      ..drawPath(
        Path()
          ..moveTo(w - arm, half)
          ..lineTo(w - half - r, half)
          ..arcToPoint(Offset(w - half, half + r), radius: radius)
          ..lineTo(w - half, arm),
        paint,
      )
      ..drawPath(
        Path()
          ..moveTo(w - half, h - arm)
          ..lineTo(w - half, h - half - r)
          ..arcToPoint(Offset(w - half - r, h - half), radius: radius)
          ..lineTo(w - arm, h - half),
        paint,
      )
      ..drawPath(
        Path()
          ..moveTo(arm, h - half)
          ..lineTo(half + r, h - half)
          ..arcToPoint(Offset(half, h - half - r), radius: radius)
          ..lineTo(half, h - arm),
        paint,
      );
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.color != color;
}

/// The frosted chip at the bottom saying what the camera is doing; read out as it changes.
class _HintChip extends StatelessWidget {
  const _HintChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: ColoredBox(
          color: const Color.fromRGBO(0, 0, 0, .55),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w500, height: 1.45, color: _onCamera),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A round frosted button over the camera: flip, and the torch.
class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.label, required this.onPressed, this.toggled});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// For a switch, whether it is on.
  final bool? toggled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: toggled,
    label: label,
    excludeSemantics: true,
    child: PressScale(
      scale: .94,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Material(
            color: const Color.fromRGBO(255, 255, 255, .12),
            child: InkWell(
              onTap: onPressed,
              splashFactory: NoSplash.splashFactory,
              highlightColor: const Color.fromRGBO(255, 255, 255, .08),
              child: SizedBox.square(dimension: 40, child: Icon(icon, size: 19, color: _onCamera)),
            ),
          ),
        ),
      ),
    ),
  );
}
