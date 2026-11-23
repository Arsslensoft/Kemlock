import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// The time now in whole Unix seconds, ticking once a second, as
/// `useNowSeconds` did: one timer for the whole app, aligned to the clock's
/// second boundaries, so every countdown and code on screen flips at the
/// same instant. It stops when nothing on screen watches it.
class NowSeconds extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    ref.onDispose(() => _timer?.cancel());
    _schedule();
    return _read();
  }

  int _read() => ref.read(clockProvider)().millisecondsSinceEpoch ~/ 1000;

  void _schedule() {
    final ms = ref.read(clockProvider)().millisecondsSinceEpoch;
    _timer = Timer(Duration(milliseconds: 1000 - ms % 1000 + 5), () {
      state = _read();
      _schedule();
    });
  }
}

final nowSecondsProvider = NotifierProvider.autoDispose<NowSeconds, int>(NowSeconds.new);

/// Seconds left in the current TOTP window (1…period). A period that is no
/// period (zero or less, as a file from elsewhere can give) has 1 left, where
/// the division would throw while the list builds.
int remainingIn(int nowSec, int period) => period < 1 ? 1 : period - nowSec % period;

/// A flag that turns on when triggered and off by itself after [duration],
/// as `useFlash` did; triggering again while on starts the time over. For
/// "Copied" and the like.
class Flash extends ValueNotifier<bool> {
  Flash(this.duration) : super(false);

  final Duration duration;
  Timer? _timer;

  void trigger() {
    _timer?.cancel();
    value = true;
    _timer = Timer(duration, () => value = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
