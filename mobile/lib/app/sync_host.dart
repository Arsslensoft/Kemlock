import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/public_suffixes.dart';
import '../features/backup/two_factor_directory.dart';
import '../features/duplicates/duplicate_sites.dart';
import '../features/spaces/hidden_passwords.dart';
import '../features/spaces/remembered_export_policies.dart' show spaceAnchorStoreProvider;
import '../features/spaces/space_policies_provider.dart';
import '../features/sync/attachment_downloads.dart';
import '../features/sync/attachment_sync.dart';
import '../features/sync/kemlock_copy.dart';
import '../features/sync/kemlock_host_factory.dart';
import '../features/sync/kemlock_matching.dart';
import '../features/sync/kemlock_move.dart';
import '../features/sync/kemlock_push.dart';
import '../features/sync/kemlock_server_spaces.dart';
import '../features/sync/sync_scheduler.dart';
import '../features/sync/sync_store.dart';
import '../features/sync/vaultwarden/vw_backend.dart';
import '../features/sync/vaultwarden/vw_file_sync.dart';
import '../platform/device_keys.dart';
import '../platform/network.dart';
import '../vault/attachment_store.dart';
import '../vault/vault_controller.dart';
import '../vault/vault_providers.dart';
import '../vault/vault_store.dart';
import 'kemlock_approvals_host.dart';
import 'kemlock_live_host.dart';

/// Keeps the open vault in sync while it is open, as `SyncController.tsx`
/// sat inside the unlocked app: one [SyncScheduler] per vault session,
/// told about each change the user makes and about the app coming to the
/// front or going to the back, and stopped on lock and while
/// the vault's key pair is replaced. While offline mode is on there is no
/// scheduler: the settings are loaded for the screens to show, and nothing
/// syncs until it is turned off.
class SyncHost extends ConsumerStatefulWidget {
  const SyncHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SyncHost> createState() => _SyncHostState();
}

class _SyncHostState extends ConsumerState<SyncHost> {
  SyncScheduler? _scheduler;

  /// Whether the sync settings are loaded with no scheduler, because offline mode is on.
  bool _paused = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onShow: () => _scheduler?.setVisible(true), onHide: () => _scheduler?.setVisible(false));
    ref.listenManual(vaultControllerProvider.select((s) => s.session), (_, session) => _restart(session), fireImmediately: true);
    ref.listenManual(vaultControllerProvider.select((s) => s.revision), (previous, revision) {
      if (revision > (previous ?? 0)) _scheduler?.userChanged();
    });
    // The Bitwarden copy reads the device list at most once a day, after a sync run (task 6.1)
    ref.listenManual(syncProvider.select((s) => s.running), (previous, running) {
      if (previous == true && !running) {
        unawaited(ref.read(kemlockCopyProvider.notifier).check());
        // A member of a space is told at the next sync when an admin turned server matching on for it
        unawaited(ref.read(kemlockMatchingNoticesProvider.notifier).refresh());
      }
    });
    // A move that stopped resumes when the vault opens, once its sync settings are loaded (move-off-vaultwarden-sync,
    // task 3.5)
    ref.listenManual(syncProvider.select((s) => s.settings != null), (_, loaded) {
      if (loaded) unawaited(ref.read(kemlockMoveProvider.notifier).resume());
    }, fireImmediately: true);
    // Sync stops while the vault's key pair is replaced, and runs once after, with whichever key pair
    // the vault then has (openspec: replace-vault-key-pair, decision 6)
    ref.listenManual(vaultControllerProvider.select((s) => s.replacingKey), (_, replacing) {
      if (replacing) {
        _scheduler?.dispose();
        _scheduler = null;
      } else if (_scheduler == null) {
        _restart(ref.read(vaultControllerProvider).session);
      }
    });
    // Offline mode stops the scheduler without forgetting the settings, and turning it off starts one,
    // which syncs once as after an unlock (openspec: add-offline-mode, decision 4)
    ref.listenManual(offlineProvider, (_, offline) {
      final session = ref.read(vaultControllerProvider).session;
      if (offline) {
        if (_scheduler == null) return;
        _scheduler?.dispose(unload: false);
        _scheduler = null;
        _paused = session != null;
      } else if (_scheduler == null) {
        _restart(session);
      }
    });
  }

  void _restart(VaultSession? session) {
    _scheduler?.dispose();
    _scheduler = null;
    if (_paused) {
      // No scheduler held the settings that were loaded while paused, so none forgot them
      _paused = false;
      ref.read(syncProvider.notifier).unload();
    }
    if (session == null || ref.read(vaultControllerProvider).replacingKey) return;
    if (ref.read(offlineProvider)) {
      _paused = true;
      unawaited(_loadPaused(session));
      return;
    }
    final controller = ref.read(vaultControllerProvider.notifier);
    // Loads the 2FA directory, for the websites of new plain Vaultwarden logins
    ref.read(twoFactorDirectoryProvider);
    final vaultId = ref.read(vaultControllerProvider).vault.id;
    final vaultwarden = VaultwardenBackend(
      vault: ref.read(vaultStoreProvider),
      session: session,
      clientFor: ref.read(vwClientFactoryProvider),
      info: ref.read(vwClientInfoProvider),
      websiteFor: _website,
      files: VwFiles(store: ref.read(attachmentStoreProvider), vaultId: vaultId),
      clock: ref.read(clockProvider),
    );
    // The anchors of the account's server spaces ride the vault's own sync: its WebDAV file, or an item on Kemlock Server
    final anchors = ref.read(spaceAnchorStoreProvider);
    final kemlock = makeKmHost(
      vault: ref.read(vaultStoreProvider),
      session: session,
      clientFor: ref.read(kemlockClientFactoryProvider),
      deviceKeys: ref.read(deviceKeysProvider),
      files: VaultKmFiles(ref.read(attachmentStoreProvider), vaultId),
      anchors: kmAnchorsOf(anchors, session),
      clock: ref.read(clockProvider),
      pushToken: ref.read(kemlockPushTokenProvider),
      onList: (next) {
        // The home gave a new server list that passed the checks: the settings keep it, so a restart still has it
        final settings = ref.read(syncProvider).settings;
        final current = settings?.kemlock;
        if (!mounted || settings == null || current == null || current.accountId != next.accountId) {
          return;
        }
        final kept = current.copyWith(servers: next.servers, homeEpoch: next.homeEpoch);
        unawaited(ref.read(syncProvider.notifier).saveSettings(settings.copyWith(kemlock: kept), session));
      },
      onAway: (away) {
        if (mounted) ref.read(kemlockAwayProvider.notifier).set(away);
      },
      dedupSites: () async => siteResolver(suffixes: await ref.read(publicSuffixListProvider.future)),
      onHints: (hints) {
        if (mounted) ref.read(kemlockHintsProvider.notifier).set(hints);
      },
      onMatching: (enabled) {
        // The home says server matching is off for the vault, as it is when it was turned off on another device: the
        // phone sends no tag from now on, and the cleaner forgets the server's groups
        final settings = ref.read(syncProvider).settings;
        final current = settings?.kemlock;
        if (!mounted || enabled || settings == null || current == null || !current.matching) {
          return;
        }
        ref.read(kemlockHintsProvider.notifier).set(null);
        unawaited(ref.read(syncProvider.notifier).saveSettings(settings.copyWith(kemlock: current.copyWith(matching: false)), session));
      },
    );
    // The providers are set after this build, as they may not be changed while the tree builds
    scheduleMicrotask(() {
      if (mounted && _scheduler != null) ref.read(kemlockHostProvider.notifier).set(kemlock);
    });
    final scheduler = SyncScheduler(
      store: ref.read(syncProvider.notifier),
      webDav: ref.read(webDavProvider),
      session: session,
      getLists: () => ref.read(vaultControllerProvider).lists,
      applySynced: controller.applySynced,
      vaultwarden: vaultwarden,
      kemlock: kemlock,
      serverSpaces: KmSpacesBackend(
        host: kemlock,
        chainCrypto: ref.read(spaceChainCryptoProvider),
        // Each chain a run of a space verified says which logins hide their password
        onChain: (space, account, chain, {collections}) {
          if (mounted) {
            ref.read(hiddenPasswordsProvider.notifier).report(space, account, chain, collections: collections);
          }
        },
        // Only a chain whose fingerprint this device compared says which policies apply
        onComparedChain: (space, account, chain, {collections}) {
          if (mounted) {
            ref
                .read(spacePoliciesProvider.notifier)
                .reportCompared(space, account, chain, email: ref.read(syncProvider).settings?.kemlock?.email, vault: vaultId);
          }
        },
      ),
      anchors: anchors,
      ownEntriesPaused: () => ref.read(kemlockMoveProvider).pausesSync,
      files: AttachmentSync(webDav: ref.read(webDavProvider), store: ref.read(attachmentStoreProvider), vaultId: vaultId),
      fetchFiles: (dav, files) => ref.read(attachmentDownloadsProvider.notifier).want(vaultId, dav, files),
      clock: ref.read(clockProvider),
    );
    _scheduler = scheduler;
    unawaited(scheduler.start());
  }

  /// Reads the vault's sync settings while offline mode is on, so the
  /// screens show what is paused; nothing is sent.
  Future<void> _loadPaused(VaultSession session) async {
    final store = ref.read(syncProvider.notifier);
    try {
      await store.load(session);
    } catch (_) {
      if (mounted && _paused) store.unload();
    }
  }

  /// A new plain Vaultwarden login's website: the 2FA directory's domain
  /// for the issuer, once the directory has loaded.
  String? _website(String issuer) {
    final domain = ref.read(twoFactorDirectoryProvider).value?.findService(issuer)?.domain;
    return domain == null || domain.isEmpty ? null : 'https://$domain';
  }

  @override
  void dispose() {
    _scheduler?.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KemlockApprovalsHost(child: KemlockLiveHost(child: widget.child));
}
