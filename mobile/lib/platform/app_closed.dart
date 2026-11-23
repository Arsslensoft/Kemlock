import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// On Android the app's Flutter engine is the process's and outlives its
/// main screen, so that mail apps can be answered (openspec:
/// add-pgp-mail-provider, decision 1). Closing the main screen for good,
/// with Back or by swiping it from the recent apps, used to end the engine
/// and so lock the vault; now the native side says so instead, over
/// `com.kemlock.app/lifecycle`, and the app locks (decision 2). iOS never
/// sends it.
abstract interface class AppClosedSignal {
  /// Each time the main screen is closed for good.
  Stream<void> get closed;
}

/// [AppClosedSignal] over the app's method channel; a build without the
/// native side sends nothing.
class ChannelAppClosedSignal implements AppClosedSignal {
  ChannelAppClosedSignal() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closed') _closed.add(null);
    });
  }

  static const _channel = MethodChannel('com.kemlock.app/lifecycle');
  final _closed = StreamController<void>.broadcast();

  @override
  Stream<void> get closed => _closed.stream;
}

/// The phone's signal; tests put a fake in its place.
final appClosedSignalProvider = Provider<AppClosedSignal>((ref) => ChannelAppClosedSignal());
