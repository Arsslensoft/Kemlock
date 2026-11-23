import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/secret_clipboard.dart';

/// Answers the sensitive copy's channel, `com.kemlock.app/clipboard`, as a
/// phone with Kemlock's native side does, until the test ends: each copy
/// goes to [write], and a clear of the last copy writes an empty string.
/// Tests that watch Flutter's own clipboard channel call it too, so the
/// codes the app copies reach what they watch.
void answerSensitiveCopies(void Function(String text) write) {
  const channel = MethodChannel('com.kemlock.app/clipboard');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var copies = 0;
  messenger.setMockMethodCallHandler(channel, (call) async {
    final arguments = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'copy':
        write(arguments['text']! as String);
        return '${++copies}';
      case 'clearIfOurs':
        if (arguments['token'] == '$copies') write('');
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

/// Stands in for the phone's sensitive copy: keeps each copy and each clear
/// it was asked for, and can be told to fail as a phone without the native
/// side does.
///
/// ```dart
/// final clipboard = FakeSensitiveClipboard();
/// expect(clipboard.copies.single, (text: '123456', seconds: 30));
/// ```
class FakeSensitiveClipboard implements SensitiveClipboard {
  /// Each copy, with the expiry it asked for.
  final List<({String text, int? seconds})> copies = [];

  /// The token of every [clearIfOurs], in order.
  final List<String> clears = [];

  /// Thrown by every call while set.
  Object? error;

  Override get asOverride => sensitiveClipboardProvider.overrideWithValue(this);

  @override
  Future<String> copy(String text, int? seconds) async {
    if (error case final error?) throw error;
    copies.add((text: text, seconds: seconds));
    return 'copy-${copies.length}';
  }

  @override
  Future<void> clearIfOurs(String token) async {
    if (error case final error?) throw error;
    clears.add(token);
  }
}
