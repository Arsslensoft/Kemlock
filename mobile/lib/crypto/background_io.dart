import 'dart:async';
import 'dart:isolate';

/// Runs [computation] in a short-lived isolate and gives its result. It and
/// everything it captures must be sendable to another isolate.
Future<T> runInBackground<T>(FutureOr<T> Function() computation, {String? debugName}) => Isolate.run<T>(computation, debugName: debugName);
