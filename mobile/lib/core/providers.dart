import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage/key_value_store.dart';

/// The app's storage, opened in `main` and passed in with an override.
final keyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => throw UnimplementedError('keyValueStoreProvider is overridden in main and in tests.'),
);

/// The time now. Tests override it to fix the clock.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Rebuilds the calling provider whenever any of [keys] is written.
void watchKeys(Ref ref, Iterable<String> keys) {
  final store = ref.watch(keyValueStoreProvider);
  for (final key in keys) {
    final VoidCallback stop = store.listen(key, ref.invalidateSelf);
    ref.onDispose(stop);
  }
}
