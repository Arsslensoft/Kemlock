import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app/app_shell.dart';
import 'app/autofill_host.dart';
import 'features/accounts/accounts_page.dart';
import 'features/backup/backup_page.dart';
import 'features/lock/lock_screen.dart';
import 'features/lock/setup_screen.dart';
import 'features/notes/note_page.dart';
import 'features/security_keys/spike_page.dart';
import 'features/sends/sends_page.dart';
import 'features/settings/about_page.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/terms_page.dart';
import 'features/vault/vault_page.dart';
import 'ui/ui.dart';
import 'vault/vault_controller.dart';

/// The routes of `router.tsx`, behind the vault gate `App.tsx` kept: setup
/// until a vault exists, the lock screen while it is locked, and the tabs,
/// About and Terms while it is open. Unlocking goes back to the page the
/// vault was locked on.
final routerProvider = Provider<GoRouter>((ref) {
  final phase = ValueNotifier(ref.read(vaultControllerProvider).phase);
  ref.listen(vaultControllerProvider.select((s) => s.phase), (_, next) => phase.value = next);
  ref.onDispose(phase.dispose);
  var lastOpen = '/accounts';
  // A note opens over the tab bar, on the root navigator, with the shell kept below it
  final root = GlobalKey<NavigatorState>();

  final router = GoRouter(
    navigatorKey: root,
    initialLocation: '/accounts',
    refreshListenable: phase,
    redirect: (context, state) {
      final location = state.matchedLocation;
      switch (phase.value) {
        case VaultPhase.setup:
          // A vault made here starts on the Codes tab, not on a page of the one it replaces
          lastOpen = '/accounts';
          return location == '/setup' ? null : '/setup';
        case VaultPhase.locked:
          return location == '/lock' ? null : '/lock';
        case VaultPhase.unlocked:
          if (location == '/setup' || location == '/lock') return lastOpen;
          // The old path for backup codes, kept so links still land somewhere useful
          if (location == '/codes') return '/backup';
          if (location == '/') return '/accounts';
          lastOpen = state.uri.toString();
          return null;
      }
    },
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/accounts'),
      GoRoute(path: '/codes', redirect: (_, _) => '/backup'),
      GoRoute(path: '/setup', pageBuilder: (_, state) => _fade(state, const SetupScreen())),
      GoRoute(path: '/lock', pageBuilder: (_, state) => _fade(state, const LockScreen())),
      ...keySpikeRoutes(),
      ShellRoute(
        builder: (context, state, child) => AutofillHost(
          child: AppShell(location: state.matchedLocation, child: child),
        ),
        routes: [
          GoRoute(path: '/accounts', pageBuilder: (_, state) => _rise(state, const AccountsPage())),
          GoRoute(
            path: '/backup',
            // `?open=<id>` opens that service's card, as a link to backup codes does; `at` tells one such request from the last
            pageBuilder: (_, state) =>
                _rise(state, BackupPage(openId: state.uri.queryParameters['open'], request: state.uri.queryParameters['at'])),
          ),
          GoRoute(
            path: '/vault',
            pageBuilder: (_, state) => _rise(state, const VaultPage()),
            routes: [
              GoRoute(path: 'sends', parentNavigatorKey: root, pageBuilder: (_, state) => _rise(state, const SendsPage())),
              GoRoute(
                path: 'notes/:id',
                parentNavigatorKey: root,
                pageBuilder: (_, state) {
                  final id = state.pathParameters['id']!;
                  // A page of its own for each note, so going from one note to another shows the other
                  return _rise(state, NotePage(key: ValueKey(id), noteId: id));
                },
              ),
            ],
          ),
          GoRoute(path: '/settings', pageBuilder: (_, state) => _rise(state, const SettingsPage())),
          GoRoute(path: '/about', pageBuilder: (_, state) => _rise(state, const AboutPage())),
          GoRoute(path: '/terms', pageBuilder: (_, state) => _rise(state, const TermsPage())),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

/// A page that rises into place, as the layout animated each new page.
CustomTransitionPage<void> _rise(GoRouterState state, Widget child) => CustomTransitionPage(
  key: state.pageKey,
  child: child,
  transitionDuration: const Duration(milliseconds: 450),
  reverseTransitionDuration: Duration.zero,
  transitionsBuilder: (context, animation, _, child) {
    final curved = CurvedAnimation(parent: animation, curve: Ease.out);
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (_, child) => Transform.translate(offset: Offset(0, 12 * (1 - curved.value)), child: child),
        child: child,
      ),
    );
  },
);

/// The setup and lock screens fade out, as the vault gate swapped them, but
/// come in whole: fading in, the lock screen let the page it locked and the
/// sheets over it, a shown password or a Recovery Kit's code, show through
/// for its first 300 ms. Its own content still eases in.
CustomTransitionPage<void> _fade(GoRouterState state, Widget child) => CustomTransitionPage(
  key: state.pageKey,
  child: child,
  transitionDuration: Duration.zero,
  reverseTransitionDuration: const Duration(milliseconds: 300),
  transitionsBuilder: (_, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Ease.out),
    child: child,
  ),
);
