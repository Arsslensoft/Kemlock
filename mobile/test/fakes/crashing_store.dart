import 'package:flutter/foundation.dart';
import 'package:kemlock/core/storage/key_value_store.dart';

/// Thrown by every write of a [CrashingStore] from the one it dies at.
class StoreDied implements Exception {
  const StoreDied(this.write);

  /// The write it died at, counting from 1.
  final int write;

  @override
  String toString() => 'The app died at write $write.';
}

/// A key-value store that dies at its [diesAt]th write, as an app killed
/// in the middle of a run of writes does: the writes before it are kept,
/// that one and every one after it throw [StoreDied] and change nothing.
/// [reopen] gives what the next start of the app would find.
///
/// A write is a `setItem`, or a `removeItem` of a key that is there, as
/// for [KeyValueStore], which writes nothing to remove a key it doesn't
/// hold; so the kill can land on a delete too.
///
/// ```dart
/// final store = CrashingStore(diesAt: 3);
/// store.setItem('a', '1'); store.setItem('b', '2');
/// store.setItem('c', '3');            // throws StoreDied
/// store.reopen().getItem('c');        // null
/// ```
class CrashingStore implements KeyValueStore {
  CrashingStore({this.diesAt, Map<String, String> values = const {}}) : _values = {...values};

  /// The write that throws, counting from 1; null never dies.
  int? diesAt;

  final Map<String, String> _values;
  final Map<String, List<VoidCallback>> _listeners = {};

  /// The writes tried so far, the one that died included.
  int writes = 0;

  /// Whether a write has died.
  bool get dead => diesAt != null && writes >= diesAt!;

  /// What the next start of the app finds: every write before the one that died.
  KeyValueStore reopen() => KeyValueStore.memory(_values);

  void _write() {
    writes++;
    if (dead) throw StoreDied(writes);
  }

  @override
  String? getItem(String key) => _values[key];

  @override
  void setItem(String key, String value) {
    _write();
    _values[key] = value;
    _notify(key);
  }

  @override
  void removeItem(String key) {
    if (!_values.containsKey(key)) return;
    _write();
    _values.remove(key);
    _notify(key);
  }

  @override
  List<String> storedKeys() => _values.keys.toList();

  @override
  Future<void> flush() async {}

  @override
  VoidCallback listen(String key, VoidCallback onChange) {
    final list = _listeners.putIfAbsent(key, () => []);
    list.add(onChange);
    return () => list.remove(onChange);
  }

  void _notify(String key) {
    for (final listener in [...?_listeners[key]]) {
      listener();
    }
  }
}
