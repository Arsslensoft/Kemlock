import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app/share_host.dart';
import 'app/theme_choice.dart';
import 'core/toasts.dart';
import 'features/export/android_export.dart';
import 'features/import/credential_exchange.dart';
import 'features/mail/request_route.dart';
import 'features/settings/auto_lock.dart';
import 'features/settings/prefs.dart';
import 'i18n/messages.dart';
import 'platform/setup_links.dart';
import 'router.dart';
import 'ui/ui.dart';
import 'vault/vault_controller.dart';

/// The app: the router behind the vault gate, in the chosen look and
/// language, with the toast above every page and auto-lock watching for
/// activity and for the app being hidden.
class KemlockApp extends ConsumerWidget {
  const KemlockApp({super.key, this.router});

  /// The router to use; the app's own when not given. Tests pass their own.
  final GoRouter? router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Set-up links are caught from the start, even while the vault is locked; the shell shows them.
    ref.listen(pendingSetupLinkProvider, (_, _) {});
    // So is another app's export on iOS 26: its token waits for a vault, and nothing of it is read before.
    ref.listen(pendingCredentialExchangeProvider, (_, _) {});
    // Android's export requests wait the same way, and Kemlock is listed as an export source once export is on.
    ref.listen(pendingExportRequestProvider, (_, _) {});
    ref.listen(credentialExportRegistrationProvider, (_, _) {});
    final catalog = ref.watch(messageCatalogProvider);
    return MaterialApp.router(
      title: 'Kemlock',
      debugShowCheckedModeBanner: false,
      routerConfig: router ?? ref.watch(routerProvider),
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ref.watch(themeChoiceProvider).mode,
      locale: ref.watch(localeProvider).locale,
      supportedLocales: supportedLocales,
      localizationsDelegates: localizationsDelegates(catalog),
      builder: (context, child) => _SystemBars(
        child: ToastHost(
          child: _ToastBridge(
            child: _AutoLockScope(
              child: ShareHost(
                child: EffectsScope(child: MailRequestHost(child: child!)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Status and navigation bars that match the scheme, over the edge-to-edge app,
/// as `NativeChrome` kept the Capacitor status bar in step.
class _SystemBars extends StatelessWidget {
  const _SystemBars({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: child,
    );
  }
}

/// Shows the toasts anything in the app asks for through [toastsProvider].
class _ToastBridge extends ConsumerWidget {
  const _ToastBridge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(toastsProvider, (_, toast) {
      if (toast == null) return;
      final onAction = toast.onAction;
      final label = toast.actionLabel;
      ToastHost.of(context).show(
        toast.message,
        severity: toast.severity,
        action: label == null || onAction == null ? null : ToastAction(label: label, onPressed: onAction),
      );
    });
    return child;
  }
}

/// Locks the open vault after the minutes chosen in Settings without a
/// touch or key press, and when the app is hidden if Settings says so, as
/// `useAutoLock` did.
class _AutoLockScope extends ConsumerStatefulWidget {
  const _AutoLockScope({required this.child});

  final Widget child;

  @override
  ConsumerState<_AutoLockScope> createState() => _AutoLockScopeState();
}

class _AutoLockScopeState extends ConsumerState<_AutoLockScope> {
  late final AutoLock _autoLock;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // On the holds' clock, which setting the date doesn't move
    _autoLock = AutoLock(holds: ref.read(autoLockHoldsProvider), lock: () => ref.read(vaultControllerProvider.notifier).lock());
    _lifecycle = AppLifecycleListener(onStateChange: _autoLock.lifecycleChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    _sync();
    ref.listenManual(vaultControllerProvider.select((s) => s.isUnlocked), (_, _) => _sync());
    ref.listenManual(prefsProvider, (_, _) => _sync());
  }

  void _sync() {
    final prefs = ref.read(prefsProvider);
    _autoLock.update(active: ref.read(vaultControllerProvider).isUnlocked, minutes: prefs.autoLockMinutes, lockOnHide: prefs.lockOnHide);
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _autoLock.activity();
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lifecycle.dispose();
    _autoLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _autoLock.activity(),
    onPointerSignal: (_) => _autoLock.activity(),
    child: widget.child,
  );
}
