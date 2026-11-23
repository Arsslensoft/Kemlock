import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/app_closed.dart';

/// Stands in for Android saying the main screen was closed for good. On
/// iOS nothing ever calls [close].
class FakeAppClosedSignal implements AppClosedSignal {
  final _closed = StreamController<void>.broadcast();

  Override get asOverride => appClosedSignalProvider.overrideWithValue(this);

  /// The main screen is closed for good.
  void close() => _closed.add(null);

  @override
  Stream<void> get closed => _closed.stream;
}
