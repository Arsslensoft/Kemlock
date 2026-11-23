import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/accounts/add_account_sheet.dart';
import '../features/backup/add_backup_service_sheet.dart';
import '../features/breaches/breach_providers.dart';
import '../features/export/android_export.dart';
import '../features/export/credential_export_sheet.dart';
import '../features/import/credential_exchange.dart';
import '../features/import/import_sheet.dart';
import '../features/lock/enable_biometric_sheet.dart';
import '../features/lock/replace_key_sheet.dart';
import '../features/sends/received_send_sheet.dart';
import '../features/settings/prefs.dart';
import '../features/share/share_flow.dart';
import '../features/vault/add_to_vault_sheet.dart';
import '../i18n/messages.dart';
import '../platform/credential_exchange.dart';
import '../platform/network.dart';
import '../platform/send_links.dart';
import '../platform/setup_links.dart';
import '../platform/shared_items.dart';
import '../ui/ui.dart';
import '../vault/vault_controller.dart';
import 'sync_host.dart';
import 'tab_bar.dart';

/// The open vault's frame, as `routes/_layout.tsx` drew it: the page, the
/// floating tab bar and its Add button, which adds an account, a backup
/// service on the Backup tab, or opens "Add to vault" on the Vault tab. It
/// also offers biometric unlock after an
/// unlock, when the vault controller says the phone can.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // Asks Have I Been Pwned for newer breaches, at most once a day, when the vault
    // just opened has that turned on, and when it is turned on (openspec: breach-alerts).
    ref.listenManual(prefsProvider.select((prefs) => prefs.breachRefresh), (_, on) {
      if (on) unawaited(updateBreachList(ref));
    }, fireImmediately: true);
    // The check that offline mode held back runs when offline mode is turned off, if it is on and due
    ref.listenManual(offlineProvider, (_, offline) {
      if (!offline && ref.read(prefsProvider).breachRefresh) unawaited(updateBreachList(ref));
    });
    ref.listenManual(vaultControllerProvider.select((s) => s.offerBiometric), (_, offer) {
      if (!offer) return;
      // After the frame: the listener can fire while the shell is first built, when no provider may change.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !ref.read(vaultControllerProvider).offerBiometric) return;
        ref.read(vaultControllerProvider.notifier).biometricOffered();
        unawaited(showEnableBiometricSheet(context));
      });
    }, fireImmediately: true);
    // A vault whose key was in an old biometric entry is offered a new one, once, after it opens
    // (openspec: replace-vault-key-pair, decision 8).
    ref.listenManual(vaultControllerProvider.select((s) => s.offerKeyReplacement), (_, offer) {
      if (!offer) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !ref.read(vaultControllerProvider).offerKeyReplacement) return;
        unawaited(ref.read(vaultControllerProvider.notifier).keyReplacementOffered());
        unawaited(showReplaceKeySheet(context, exposed: true));
      });
    }, fireImmediately: true);
    // A set-up link another app handed over, which waited while the vault was locked.
    ref.listenManual(pendingSetupLinkProvider, (_, link) {
      if (link == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final pending = mounted ? ref.read(pendingSetupLinkProvider.notifier).take() : null;
        if (pending != null) unawaited(showAddAccountSheet(context, link: pending));
      });
    }, fireImmediately: true);
    // A Send link another app shared: it opens the Send, with no account (plan add-sends, design 9).
    ref.listenManual(pendingSendLinkProvider, (_, link) {
      if (link == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final pending = mounted ? ref.read(pendingSendLinkProvider.notifier).take() : null;
        if (pending != null) unawaited(openSendLinkText(context, ref, pending));
      });
    }, fireImmediately: true);
    // Another app's export on iOS 26, whose token waited while the vault was locked: the Import sheet takes
    // it and reads the export now that a vault is open (plan add-credential-exchange, design decision 7).
    ref.listenManual(pendingCredentialExchangeProvider, (_, token) {
      if (token == null) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final taken = mounted ? ref.read(pendingCredentialExchangeProvider.notifier).take() : null;
        if (taken != null) {
          unawaited(showImportSheet(context, transfer: IosTransfer(taken)));
        }
      });
    }, fireImmediately: true);
    // Another app's request for an export on Android, which waited while the vault was locked: the export
    // sheet takes it, names the app, and asks the owner before anything is read (plan task 8.4).
    ref.listenManual(pendingExportRequestProvider, (_, request) {
      if (request == null) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final requests = ref.read(pendingExportRequestProvider.notifier);
        final taken = requests.take();
        if (taken != null) {
          // The request's five minutes run on while the sheet has it, and stop when the sheet sends or cancels
          final target = AndroidExportTarget(ref.read(credentialExportProvider), taken, onSettled: requests.settled);
          unawaited(showCredentialExportSheet(context, target: target));
        }
      });
    }, fireImmediately: true);
    // An item another app shared, which waited while the vault was locked (openspec: add-share-extension).
    ref.listenManual(pendingShareProvider, (_, item) {
      if (item == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(offerSharedItem(context, ref));
      });
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final tab = AppTab.of(widget.location);
    final safe = MediaQuery.paddingOf(context);
    return SyncHost(
      child: Scaffold(
        backgroundColor: context.palette.background,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            // The lights lie under the page and stay put while it scrolls. The gate stops the loops of the tab pages,
            // which live in a navigator of their own, while a sheet covers the shell.
            const Positioned.fill(child: AmbientLight(lights: 2)),
            Positioned.fill(child: LoopGate(child: widget.child)),
            Positioned(
              left: 16,
              right: 16,
              bottom: safe.bottom + 22,
              child: Center(
                child: AppTabBar(
                  active: tab,
                  onSelect: (next) => context.go(next.path),
                  addLabel: context.t(switch (tab) {
                    AppTab.backup => 'nav.addBackup',
                    AppTab.vault => 'nav.addToVault',
                    AppTab.codes || AppTab.settings => 'nav.addAccount',
                  }),
                  onAdd: () => unawaited(switch (tab) {
                    AppTab.backup => showAddBackupServiceSheet(context),
                    AppTab.vault => showAddToVaultSheet(context),
                    AppTab.codes || AppTab.settings => showAddAccountSheet(context),
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
