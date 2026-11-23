import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../platform/unlock_keys.dart';

/// Inactivity timeouts offered in Settings, in minutes.
const autoLockMinuteOptions = [1, 5, 15, 60];

/// The time auto-lock counts idle time by, in milliseconds.
///
/// It runs on the phone's elapsed clock, [elapsed] (Android's
/// `SystemClock.elapsedRealtime`, iOS's `CLOCK_MONOTONIC_RAW`), which keeps
/// counting while the phone sleeps and which setting the date or time
/// doesn't move. On the wall clock, someone holding the unlocked phone could
/// set the date back and find an idle vault still open. Between two reads
/// of the phone's clock a stopwatch counts on; [catchUp] reads it again,
/// which after a sleep moves the time on by the sleep.
///
/// Until the phone's clock first answers, and for good where it never does
/// (the tests, a build without the native side), the time is [now]'s, the
/// wall clock. From the first answer on it carries on from there, so a time
/// read before it can be compared with one read after.
class IdleClock {
  IdleClock({this._now = DateTime.now, this._elapsed});

  final DateTime Function() _now;
  final Future<int?> Function()? _elapsed;
  final _sinceRead = Stopwatch();

  /// The time at the last read of the phone's clock, and what that clock said.
  int? _base;
  int _elapsedAtBase = 0;

  int nowMs() {
    final base = _base;
    return base == null ? _now().millisecondsSinceEpoch : base + _sinceRead.elapsedMilliseconds;
  }

  /// Reads the phone's clock, and moves the time on by what passed on it
  /// since the last read, sleep included. Never back.
  Future<void> catchUp() async {
    final int? elapsed;
    try {
      elapsed = await _elapsed?.call();
    } catch (_) {
      return;
    }
    if (elapsed == null) return;
    final base = _base;
    if (base != null && elapsed <= _elapsedAtBase) return;
    _base = base == null ? nowMs() : math.max(nowMs(), base + elapsed - _elapsedAtBase);
    _elapsedAtBase = elapsed;
    _sinceRead
      ..reset()
      ..start();
  }
}

/// "Lock when hidden" must not fire while the app itself sent the user to a
/// system file picker, share sheet, camera permission or biometric prompt,
/// all of which hide the app. Those flows hold the lock until they're done.
class AutoLockHolds {
  AutoLockHolds({DateTime Function() now = DateTime.now, Future<int?> Function()? elapsed}) : clock = IdleClock(now: now, elapsed: elapsed);

  /// A forgotten hold must not keep the vault open for ever.
  static const maxHold = Duration(minutes: 10);

  /// The time the holds, and the app's auto-lock, count by.
  final IdleClock clock;
  int _holds = 0;
  int _releasedAt = 0;

  /// Suspends auto-lock until the returned function is called. Calling it
  /// again does nothing; after [maxHold] it is called by itself. Its end
  /// counts as activity, since time in a picker isn't idle, unless not
  /// [resetsIdle]: a mail request's grant is no sign of the person.
  VoidCallback hold({bool resetsIdle = true}) {
    _holds++;
    var released = false;
    late final Timer timer;
    void release() {
      if (released) return;
      released = true;
      timer.cancel();
      _holds--;
      if (resetsIdle) _releasedAt = clock.nowMs();
    }

    timer = Timer(maxHold, release);
    return release;
  }

  bool get isHeld => _holds > 0;

  /// When the last hold that [resetsIdle] ended, on [clock], 0 if none has; time spent in a picker doesn't count as idle.
  int get lastReleaseAt => _releasedAt;

  /// Keeps the lock off while [task] runs, e.g. a share sheet or biometric
  /// prompt, and lets go when it ends, whether it succeeded or failed.
  Future<T> withHeld<T>(Future<T> Function() task) async {
    final release = hold();
    try {
      return await task();
    } finally {
      release();
    }
  }
}

/// The holds of the whole app, which the pickers, share sheets and prompts
/// take, on the phone's elapsed clock.
final autoLockHoldsProvider = Provider<AutoLockHolds>(
  (ref) => AutoLockHolds(now: ref.watch(clockProvider), elapsed: ref.watch(phoneElapsedProvider)),
);

/// Locks the vault after some minutes without interaction and, when asked,
/// as soon as the app is hidden, as `useAutoLock` did. It is plain Dart: the
/// app shell creates one, tells it the settings with [update], feeds it the
/// user's activity and the app's lifecycle, and disposes of it.
///
/// Idle time is counted on the holds' [IdleClock], which keeps counting
/// while the phone sleeps and which setting the date doesn't move; each
/// check reads the phone's clock again and looks once more.
///
/// ```dart
/// final autoLock = AutoLock(holds: ref.read(autoLockHoldsProvider), lock: lockVault);
/// autoLock.update(active: unlocked, minutes: prefs.autoLockMinutes, lockOnHide: prefs.lockOnHide);
/// Listener(onPointerDown: (_) => autoLock.activity(), onPointerSignal: (_) => autoLock.activity(), child: app);
/// HardwareKeyboard.instance.addHandler((event) { if (event is KeyDownEvent) autoLock.activity(); return false; });
/// AppLifecycleListener(onStateChange: autoLock.lifecycleChanged);
/// ```
///
/// The web build listened to `visibilitychange` and Capacitor's pause and
/// resume. Here [AppLifecycleState.hidden], [AppLifecycleState.paused] and
/// [AppLifecycleState.detached] count as hidden: the app is out of sight.
/// [AppLifecycleState.inactive] doesn't: it comes with the iOS app switcher,
/// Control Center, a Face ID prompt and Android's notification shade, while
/// the app is still on screen, and comes first on the way to the background.
/// [AppLifecycleState.resumed] checks the idle time at once, as timers may
/// not have run in the background.
///
/// Hidden while a hold is in place, with "lock when hidden" on, it waits
/// for the holds to end, as `AppClosedLock` does for a closed main screen:
/// once none is left for a full look at them, [afterHoldEvery] apart, it
/// locks unless the app is on screen again by then. The look more lets a
/// picker's answer, which can come just before the lifecycle says the app
/// is back, go by without locking.
class AutoLock {
  /// With [now], auto-lock counts on a wall clock of its own instead of the
  /// holds' clock: for tests that drive it apart from the holds.
  AutoLock({required this._holds, required this._lock, DateTime Function()? now, this.extendSession})
    : _clock = now == null ? _holds.clock : IdleClock(now: now);

  /// How often the idle time is checked while the app runs.
  static const checkEvery = Duration(seconds: 5);

  /// How often activity pushes the session's expiry back: doing it on every
  /// touch would be wasteful.
  static const extendEvery = Duration(seconds: 10);

  /// How often the holds are looked at while the app is hidden under one.
  static const afterHoldEvery = Duration(seconds: 1);

  final AutoLockHolds _holds;
  final VoidCallback _lock;
  final IdleClock _clock;

  /// Pushes back the expiry of a session kept to survive a restart, by the
  /// timeout, when there's been activity. Called at most every [extendEvery].
  final void Function(Duration timeout)? extendSession;

  ({bool active, int minutes, bool lockOnHide})? _settings;
  Timer? _timer;
  int _lastActivity = 0;
  int? _extendedAt;

  /// Watching the holds of an app hidden under one, and whether the last
  /// look found none.
  Timer? _hiddenUnderHold;
  var _sawNoHold = false;

  bool get _running => _timer != null;

  /// Starts watching while [active] (the vault is unlocked) and stops when
  /// not. A change of [minutes] or [lockOnHide] starts it over, counting
  /// from now. Calls with the same settings change nothing.
  ///
  /// Once it has locked, it stays stopped until it gets other settings:
  /// `active: false` as the vault locks, then `active: true` when it is
  /// unlocked again.
  void update({required bool active, required int minutes, required bool lockOnHide}) {
    final settings = (active: active, minutes: minutes, lockOnHide: lockOnHide);
    if (settings == _settings) return;
    _stop();
    _settings = settings;
    if (!active) return;
    _extendedAt = null;
    _timer = Timer.periodic(checkEvery, (_) => _checkAndCatchUp());
    activity();
    unawaited(_clock.catchUp());
  }

  /// The user touched, scrolled or typed.
  void activity() {
    if (!_running) return;
    _lastActivity = _nowMs();
    // A restart within the timeout restores the session; after it, asks for the password.
    final extendedAt = _extendedAt;
    if (extendedAt == null || _lastActivity - extendedAt >= extendEvery.inMilliseconds) {
      _extendedAt = _lastActivity;
      extendSession?.call(_timeout);
    }
  }

  /// The app was shown or hidden.
  void lifecycleChanged(AppLifecycleState state) {
    if (!_running) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        // Hidden under a hold already, the watch decides: also on the hidden the lifecycle passes on its way back
        if (!_settings!.lockOnHide || _hiddenUnderHold != null) return;
        if (!_holds.isHeld) return _fire();
        // A picker, share sheet or prompt the app opened hides it: it locks once that is over, if the app is still hidden
        _hiddenUnderHold = Timer.periodic(afterHoldEvery, (_) => _lookAtHolds());
      case AppLifecycleState.resumed:
        _stopWatchingHolds();
        _checkAndCatchUp();
      case AppLifecycleState.inactive:
        // On screen again, under a system sheet or the app switcher, or on the way out, before hidden
        _stopWatchingHolds();
    }
  }

  /// Stops for good.
  void dispose() => _stop();

  void _lookAtHolds() {
    if (_holds.isHeld) {
      _sawNoHold = false;
    } else if (!_sawNoHold) {
      _sawNoHold = true;
    } else {
      _fire();
    }
  }

  void _stopWatchingHolds() {
    _hiddenUnderHold?.cancel();
    _hiddenUnderHold = null;
    _sawNoHold = false;
  }

  Duration get _timeout => Duration(minutes: _settings!.minutes);

  int _nowMs() => _clock.nowMs();

  void _check() {
    if (_holds.isHeld) return;
    final idleSince = math.max(_lastActivity, _holds.lastReleaseAt);
    if (_nowMs() - idleSince >= _timeout.inMilliseconds) _fire();
  }

  /// Checks at once, then again once the phone's clock has been read: after
  /// a sleep the stopwatch in between is behind it.
  void _checkAndCatchUp() {
    _check();
    if (!_running) return;
    unawaited(
      _clock.catchUp().then((_) {
        if (_running) _check();
      }),
    );
  }

  /// Locks once, then waits to be started again, as the hook's effect ended
  /// when the vault locked.
  void _fire() {
    _stop();
    _lock();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _stopWatchingHolds();
  }
}
