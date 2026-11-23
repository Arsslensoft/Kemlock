import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/widgets/toast.dart' show ToastSeverity;

export '../ui/widgets/toast.dart' show ToastSeverity;

/// A short message at the bottom of the screen, with an optional action
/// such as Undo, as `SnackState` was.
@immutable
class ToastMessage {
  const ToastMessage(this.message, {this.severity = ToastSeverity.success, this.actionLabel, this.onAction, required this.serial});

  final String message;
  final ToastSeverity severity;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Tells two toasts with the same text apart, so the second one shows again.
  final int serial;
}

/// The toast on screen, or null. Anything can show one; the shell draws it.
class Toasts extends Notifier<ToastMessage?> {
  var _serial = 0;

  @override
  ToastMessage? build() => null;

  void show(String message, {ToastSeverity severity = ToastSeverity.success, String? actionLabel, VoidCallback? onAction}) =>
      state = ToastMessage(message, severity: severity, actionLabel: actionLabel, onAction: onAction, serial: ++_serial);

  void dismiss() => state = null;
}

final toastsProvider = NotifierProvider<Toasts, ToastMessage?>(Toasts.new);
