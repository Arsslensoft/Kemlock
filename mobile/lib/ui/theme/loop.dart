import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion.dart';

/// What the app's loops and effects share, put round the app's navigator:
/// the moment of the last touch, after which decorative loops rest; a
/// [pinned] phase, which tests set to hold every loop at one moment; and
/// the count of decorative loops live on each route, kept to [maxLoops].
///
/// A loop with no scope above it runs unpinned, never rests and is not
/// counted.
class EffectsScope extends StatefulWidget {
  const EffectsScope({super.key, required this.child, this.pinned, this.loopLimit = maxLoops});

  final Widget child;

  /// When set, every loop draws this phase (0 to 1) with no ticker, and
  /// every one-shot effect draws its end.
  final double? pinned;

  /// The most loops one route may run at once.
  static const maxLoops = 6;

  /// The most loops a route under this scope may run: [maxLoops], but for a
  /// board of specimens that shows every effect at once.
  final int loopLimit;

  /// How long after the last touch a decorative loop comes to rest.
  static const idleAfter = Duration(seconds: 30);

  /// The scope above [context], if any. The caller is rebuilt when the pin changes.
  static EffectsScopeState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_EffectsInherited>()?.state;

  /// The pinned phase above [context], or null when effects run.
  static double? pinnedOf(BuildContext context) => maybeOf(context)?.pinned;

  @override
  State<EffectsScope> createState() => EffectsScopeState();
}

class EffectsScopeState extends State<EffectsScope> {
  final Map<Object?, Set<Object>> _live = {};

  /// The frame time of the last touch, or null when a touch came since the last frame a loop drew.
  Duration? _lastTouch;

  /// The pin of this scope or, when it has none, of the scope round it:
  /// the app has its own scope, and a test that pins the whole app does it
  /// from outside.
  double? get pinned => _pinned;
  double? _pinned;

  /// How many loops are live on [route].
  @visibleForTesting
  int liveOn(Object? route) => _live[route]?.length ?? 0;

  /// Counts [loop] among the live loops of [route], and in debug and test
  /// builds reports an error when the route then has more than
  /// [EffectsScope.maxLoops].
  void enter(Object loop, Object? route) {
    final loops = _live.putIfAbsent(route, () => {});
    if (!loops.add(loop)) return;
    assert(() {
      if (loops.length > widget.loopLimit) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FlutterError(
              'A screen runs more than ${widget.loopLimit} loops at once.\n'
              'The route $route has ${loops.length} live loops; the last to start was $loop. '
              'A screen may run at most ${widget.loopLimit} repeating effects (openspec: visual-effects).',
            ),
            library: 'kemlock effects',
          ),
        );
      }
      return true;
    }());
  }

  /// Takes [loop] out of the count.
  void leave(Object loop) {
    _live.removeWhere((_, loops) => (loops..remove(loop)).isEmpty);
  }

  /// Forgets [loop], which is leaving the tree.
  void forget(Object loop) {
    leave(loop);
    _resting.remove(loop);
  }

  /// Whether the screen has gone untouched for [EffectsScope.idleAfter] at
  /// the frame time [now]. The first frame after a touch, or after the scope
  /// was built, counts as the touch.
  bool idleAt(Duration now) => now - (_lastTouch ??= now) >= EffectsScope.idleAfter;

  /// The loops that came to rest, to start again at the next touch.
  final Set<LoopState> _resting = {};

  void _touched() {
    _lastTouch = null;
    if (_resting.isEmpty) return;
    final woken = _resting.toList();
    _resting.clear();
    for (final loop in woken) {
      loop._wake();
    }
  }

  @override
  Widget build(BuildContext context) {
    _pinned = widget.pinned ?? EffectsScope.pinnedOf(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touched(),
      onPointerMove: (_) => _touched(),
      onPointerSignal: (_) => _touched(),
      child: _EffectsInherited(state: this, pinned: _pinned, child: widget.child),
    );
  }
}

class _EffectsInherited extends InheritedWidget {
  const _EffectsInherited({required this.state, required this.pinned, required super.child});

  final EffectsScopeState state;
  final double? pinned;

  @override
  bool updateShouldNotify(_EffectsInherited old) => old.pinned != pinned || old.state != state;
}

/// Holds the loops under it still while it is shut. With no [open] given it
/// is open while the route it is on is the current one, which a page that
/// holds a navigator of its own puts round that navigator: the pages inside
/// are each the current one of the inner navigator, and would not see a
/// sheet opened over the outer one.
class LoopGate extends StatelessWidget {
  const LoopGate({super.key, this.open, required this.child});

  final bool? open;
  final Widget child;

  /// Whether every gate above [context] is open.
  static bool isOpen(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_LoopGateScope>()?.open ?? true;

  @override
  Widget build(BuildContext context) =>
      _LoopGateScope(open: (open ?? ModalRoute.of(context)?.isCurrent ?? true) && isOpen(context), child: child);
}

class _LoopGateScope extends InheritedWidget {
  const _LoopGateScope({required this.open, required super.child});

  final bool open;

  @override
  bool updateShouldNotify(_LoopGateScope old) => old.open != open;
}

/// Drives a looping animation off a ticker: the phase runs from 0 to 1 over
/// each [period], after [delay]. Under reduced motion, or while it is not
/// [enabled], the ticker never starts and the phase stays null: the child
/// is shown as it is, through the same widgets so its state survives the
/// switch. Under a pinned [EffectsScope] the phase is the pinned one, with
/// no ticker.
///
/// The ticker runs only while the loop can be seen: its route is the
/// current one (a sheet or a dialog over its page stops it, which
/// `TickerMode` does not), every [LoopGate] above it is open, the app is in
/// front, and it is inside the viewport of the scroll views it is in. That
/// last is checked after a frame in which one of them scrolled, not on
/// every frame.
///
/// The phase depends only on how long the loop has run, so a picture of it
/// can be repeated. The loops of `motion.dart` (`Spin`, `Breathe`, `Halo`)
/// and the effects of `effects.dart` are built on it.
abstract class LoopState<T extends StatefulWidget> extends State<T> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double?> _phase = ValueNotifier(null);

  EffectsScopeState? _scope;
  ModalRoute<Object?>? _route;

  /// Whether the route is the current one and the gates above are open.
  bool _onTop = true;
  bool _resumed = true;

  /// The scroll views the loop is in, innermost first, and whether it is inside their viewports.
  List<ScrollableState> _scrollables = const [];
  List<ScrollPosition> _positions = const [];
  bool _inView = true;
  bool _viewCheckQueued = false;

  /// How long the loop ran before its ticker last started, and since.
  Duration _ran = Duration.zero;
  Duration _elapsed = Duration.zero;

  Duration get period;

  /// The wait before the first period, once.
  Duration get delay => Duration.zero;

  /// Whether the phase runs there and back (0 to 1, then 1 to 0), as a CSS
  /// animation with `alternate`, instead of starting again at 0.
  bool get alternate => false;

  /// Whether the loop is on at all; a loop that is off has a null phase.
  bool get enabled => true;

  /// Whether the loop is only decoration. A decorative loop comes to rest
  /// when the screen has not been touched for [EffectsScope.idleAfter]: it
  /// finishes its period, stops its ticker at phase 0 and starts again at
  /// the next touch. A loop that says the app is working, as a spinner
  /// does, is not decorative and never rests.
  bool get decorative => true;

  /// The run time at which the loop, heading for its rest, gets there.
  Duration? _restAt;
  bool _rested = false;

  /// Where the loop is in its period, from 0 to 1, or null while it holds still.
  ValueListenable<double?> get phase => _phase;

  double _phaseAt(Duration run) {
    if (run.isNegative) return 0;
    final micros = math.max(1, period.inMicroseconds);
    final part = (run.inMicroseconds % micros) / micros;
    return alternate && (run.inMicroseconds ~/ micros).isOdd ? 1 - part : part;
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    final scope = _scope;
    if (decorative && scope != null && scope.idleAt(SchedulerBinding.instance.currentFrameTimeStamp)) {
      final restAt = _restAt ??= _nextRest(_ran + elapsed - delay);
      if (_ran + elapsed - delay >= restAt) {
        // At rest: the phase is back at 0, and the loop goes on from there at the next touch.
        _ticker.stop();
        _ran = restAt + delay;
        _elapsed = Duration.zero;
        _restAt = null;
        _rested = true;
        scope._resting.add(this);
        _phase.value = 0;
        return;
      }
    } else {
      _restAt = null;
    }
    _phase.value = _phaseAt(_ran + elapsed - delay);
  }

  /// When a loop that has run for [run] is next back at phase 0, which is
  /// where it rests: at the end of its period, or for a loop that goes
  /// there and back, at the end of its way back. Such a loop on its way out
  /// turns round where it is, so that it too is at rest within one period.
  Duration _nextRest(Duration run) {
    if (run.isNegative) return run;
    final micros = math.max(1, period.inMicroseconds);
    final cycle = run.inMicroseconds ~/ micros;
    final into = run.inMicroseconds % micros;
    if (into == 0 && (!alternate || cycle.isEven)) return run;
    if (!alternate || cycle.isOdd) return Duration(microseconds: (cycle + 1) * micros);
    _ran += Duration(microseconds: 2 * (micros - into));
    return Duration(microseconds: (cycle + 2) * micros);
  }

  /// Starts a loop that came to rest again, at a touch.
  void _wake() {
    _rested = false;
    if (mounted) _sync();
  }

  void _stop() {
    if (!_ticker.isActive) return;
    _ticker.stop();
    _ran += _elapsed;
    _elapsed = Duration.zero;
  }

  /// Whether the loop can be seen.
  bool get _visible => _onTop && _resumed && _inView;

  /// Starts or stops the loop to match what is round it.
  void _sync() {
    final live = enabled && !Motion.reduced(context);
    // Only decoration is counted: a spinner says the app is working, and the lock screen's dial has five of them.
    if (live && _visible && decorative) {
      _scope?.enter(this, _route);
    } else {
      _scope?.leave(this);
    }
    if (!live) {
      _stop();
      _phase.value = null;
      return;
    }
    final pinned = _scope?.pinned;
    if (pinned != null) {
      _stop();
      _phase.value = pinned;
      return;
    }
    if (!_visible) {
      _stop();
      return;
    }
    if (_ticker.isActive || _rested) return;
    _phase.value = _phaseAt(_ran - delay);
    _ticker.start();
  }

  /// Finds the scroll views the loop is in and listens to them.
  void _watchScrolling() {
    final found = <ScrollableState>[];
    for (
      var at = context.findAncestorStateOfType<ScrollableState>();
      at != null;
      at = at.context.findAncestorStateOfType<ScrollableState>()
    ) {
      found.add(at);
    }
    final positions = [for (final scrollable in found) scrollable.position];
    if (!listEquals(positions, _positions)) {
      for (final position in _positions) {
        position.removeListener(_queueViewCheck);
      }
      for (final position in positions) {
        position.addListener(_queueViewCheck);
      }
    }
    _scrollables = found;
    _positions = positions;
    if (found.isEmpty) {
      _inView = true;
    } else {
      _queueViewCheck();
    }
  }

  /// Looks, once the frame is laid out, whether the loop is still inside its scroll views.
  void _queueViewCheck() {
    if (_viewCheckQueued) return;
    _viewCheckQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _viewCheckQueued = false;
      if (!mounted) return;
      final inView = _isInView();
      if (inView == _inView) return;
      _inView = inView;
      _sync();
    });
  }

  bool _isInView() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return true;
    final mine = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    for (final scrollable in _scrollables) {
      final viewport = scrollable.mounted ? scrollable.context.findRenderObject() : null;
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) continue;
      if (!MatrixUtils.transformRect(viewport.getTransformTo(null), Offset.zero & viewport.size).overlaps(mine)) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _resumed = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _resumed) return;
    _resumed = resumed;
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EffectsScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (scope != _scope) {
      _scope?.forget(this);
      _rested = false;
    } else if (route != _route) {
      _scope?.leave(this);
    }
    _scope = scope;
    _route = route;
    _onTop = (route?.isCurrent ?? true) && LoopGate.isOpen(context);
    _watchScrolling();
    _sync();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final position in _positions) {
      position.removeListener(_queueViewCheck);
    }
    _scope?.forget(this);
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }
}

/// Plays a one-shot effect once when it is first built: [builder] gets the
/// progress, from 0 to 1 over [duration] after [delay], and applies its own
/// curve. Under reduced motion, and under a pinned [EffectsScope], it is at
/// its end from the first frame, and it goes there if either comes while
/// it plays. A rebuild does not play it again.
class EffectOnce extends StatefulWidget {
  const EffectOnce({super.key, required this.duration, this.delay = Duration.zero, required this.builder});

  final Duration duration;
  final Duration delay;
  final Widget Function(BuildContext context, double progress) builder;

  @override
  State<EffectOnce> createState() => _EffectOnceState();
}

class _EffectOnceState extends State<EffectOnce> with SingleTickerProviderStateMixin {
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
    if (Motion.reduced(context) || EffectsScope.pinnedOf(context) != null || _total == Duration.zero) {
      _controller.value = 1;
    } else if (!_started) {
      _controller.forward();
    }
    _started = true;
  }

  @override
  void dispose() {
    _curved?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _progress, builder: (context, _) => widget.builder(context, _progress.value));
}
