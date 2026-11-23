import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/shared_items.dart';

/// Stands in for what other apps share to Kemlock: the item it was opened
/// with, those [send] delivers while it runs, and how often the app asked
/// the native side to [clear] what it keeps.
class FakeSharedItems implements SharedItems {
  FakeSharedItems({this.opening});

  /// What the app was opened with, handed over once.
  SharedArrival? opening;

  /// How many times [clear] was called.
  var clears = 0;

  final _incoming = StreamController<SharedArrival>.broadcast();

  Override get asOverride => sharedItemsProvider.overrideWithValue(this);

  /// Another app shares [arrival] while the app runs.
  void send(SharedArrival arrival) => _incoming.add(arrival);

  @override
  Future<SharedArrival?> initial() async {
    final arrival = opening;
    opening = null;
    return arrival;
  }

  @override
  Stream<SharedArrival> get incoming => _incoming.stream;

  @override
  Future<void> clear() async => clears++;
}
