import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// What a toast reports; it sets the dot's colour and glyph.
enum ToastSeverity { success, error, info }

/// A button inside a toast, such as Undo.
class ToastAction {
  const ToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// How long a toast stays: longer when it offers an action, so there is
/// time to take it.
Duration toastDuration({required bool hasAction}) => hasAction ? const Duration(seconds: 5) : const Duration(seconds: 3);

/// Shows [message] in the app's toast, floating above the tab bar: a pill
/// with a coloured dot for its [severity] and, with [action], a button
/// (Undo, say) that runs the action and closes the toast. It goes after
/// three seconds, five with an action, or when the next one replaces it.
/// Taps elsewhere leave it be.
///
/// Needs a [ToastHost] above the app's navigator (in `MaterialApp.builder`).
void showToast(BuildContext context, String message, {ToastSeverity severity = ToastSeverity.success, ToastAction? action}) =>
    ToastHost.of(context).show(message, severity: severity, action: action);

/// Holds the one toast on screen and draws it above everything below it,
/// dialogs and sheets included. Put it round the app's navigator:
///
/// ```dart
/// MaterialApp.router(builder: (context, child) => ToastHost(child: child!), ...)
/// ```
class ToastHost extends StatefulWidget {
  const ToastHost({super.key, required this.child, this.bottomOffset = 98});

  final Widget child;

  /// How far above the home bar the toast floats: clear of the tab bar.
  final double bottomOffset;

  /// The host above [context], to show or hide toasts with.
  static ToastController of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ToastScope>();
    assert(scope != null, 'No ToastHost above this context: put one in MaterialApp.builder.');
    return scope!.controller;
  }

  @override
  State<ToastHost> createState() => _ToastHostState();
}

/// Shows and hides the toast of a [ToastHost].
abstract interface class ToastController {
  void show(String message, {ToastSeverity severity = ToastSeverity.success, ToastAction? action});

  /// Takes the toast away now.
  void hide();
}

class _Toast {
  _Toast(this.message, this.severity, this.action);

  final String message;
  final ToastSeverity severity;
  final ToastAction? action;

  /// Set once it starts leaving.
  bool leaving = false;
}

class _ToastHostState extends State<ToastHost> implements ToastController {
  _Toast? _toast;
  Timer? _timer;

  @override
  void show(String message, {ToastSeverity severity = ToastSeverity.success, ToastAction? action}) {
    _timer?.cancel();
    setState(() => _toast = _Toast(message, severity, action));
    _timer = Timer(toastDuration(hasAction: action != null), hide);
  }

  @override
  void hide() {
    _timer?.cancel();
    _timer = null;
    final toast = _toast;
    if (toast == null || toast.leaving || !mounted) return;
    // Under reduced motion it goes at once; otherwise the pill plays its exit and calls back.
    setState(() {
      if (Motion.reduced(context)) {
        _toast = null;
      } else {
        toast.leaving = true;
      }
    });
  }

  void _gone(_Toast toast) {
    if (mounted && identical(_toast, toast)) setState(() => _toast = null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toast = _toast;
    final media = MediaQuery.of(context);
    return _ToastScope(
      controller: this,
      child: Stack(
        children: [
          widget.child,
          if (toast != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: media.padding.bottom + media.viewInsets.bottom + widget.bottomOffset,
              child: Center(
                child: _ToastPill(
                  key: ObjectKey(toast),
                  toast: toast,
                  onAction: () {
                    toast.action?.onPressed();
                    hide();
                  },
                  onGone: () => _gone(toast),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToastScope extends InheritedWidget {
  const _ToastScope({required this.controller, required super.child});

  final ToastController controller;

  @override
  bool updateShouldNotify(_ToastScope old) => old.controller != controller;
}

/// The toast: it comes in with [ToastIn] and, once leaving, shrinks and
/// fades out over .195s before [onGone].
class _ToastPill extends StatefulWidget {
  const _ToastPill({super.key, required this.toast, required this.onAction, required this.onGone});

  final _Toast toast;
  final VoidCallback onAction;
  final VoidCallback onGone;

  @override
  State<_ToastPill> createState() => _ToastPillState();
}

class _ToastPillState extends State<_ToastPill> with SingleTickerProviderStateMixin {
  late final AnimationController _exit = AnimationController(vsync: this, duration: Motion.dialogOut);

  @override
  void didUpdateWidget(_ToastPill old) {
    super.didUpdateWidget(old);
    if (widget.toast.leaving && !_exit.isAnimating && _exit.value == 0) {
      _exit.forward().whenComplete(() {
        if (mounted) widget.onGone();
      });
    }
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final toast = widget.toast;
    final action = toast.action;
    final (dot, onDot, glyph) = switch (toast.severity) {
      ToastSeverity.error => (p.error, p.onError, Icons.priority_high_rounded),
      ToastSeverity.success => (p.primary, p.onPrimary, Icons.check_rounded),
      ToastSeverity.info => (b.line2, p.text, Icons.lock_rounded),
    };
    final pill = Container(
      constraints: BoxConstraints(minHeight: 46, maxWidth: MediaQuery.sizeOf(context).width - 32),
      padding: EdgeInsets.fromLTRB(10, 6, action != null ? 6 : 16, 6),
      decoration: BoxDecoration(
        color: b.raised,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: b.line2),
        boxShadow: b.shadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(11)),
              child: Icon(glyph, size: 14, color: onDot),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              toast.message,
              style: TextStyle(fontFamily: fontSans, fontSize: 14, fontWeight: FontWeight.w500, height: 1.4, color: p.text),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 10),
            Semantics(
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onAction,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: p.paper, borderRadius: BorderRadius.circular(17)),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      action.label,
                      style: TextStyle(fontFamily: fontSans, fontSize: 13.5, fontWeight: FontWeight.w600, color: b.accentText),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _exit,
          child: ToastIn(child: pill),
          builder: (context, child) {
            final t = Ease.inOut.transform(_exit.value);
            // MUI's Grow on the way out: down to 75% wide and 56% tall, fading.
            return Opacity(
              opacity: 1 - t,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(1 - 0.25 * t, 1 - 0.4375 * t, 1),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}
