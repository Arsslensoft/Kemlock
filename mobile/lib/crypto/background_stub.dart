import 'dart:async';

/// Runs [computation] on the calling thread, where there are no isolates (dart2wasm).
Future<T> runInBackground<T>(FutureOr<T> Function() computation, {String? debugName}) => Future<T>.sync(computation);
