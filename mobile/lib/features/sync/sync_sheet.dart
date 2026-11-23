import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/bytes.dart';
import '../../i18n/messages.dart';
import '../../platform/network.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../settings/offline_alert.dart';
import 'dav_fields.dart';
import 'kemlock_setup.dart';
import 'kemlock_sheet.dart';
import 'sync.dart';
import 'sync_crypto.dart';
import 'sync_kdf.dart';
import 'sync_messages.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';
import 'vaultwarden/vaultwarden_sheet.dart';
import 'webdav.dart';

/// Sets up, runs and turns off syncing the open vault's own entries,
/// ported from `SyncDialog.tsx`.
Future<void> showSyncSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('sync.title'), builder: (context) => const SyncSheet());

/// The sync sheet: with sync off, the folder, its login and the sync
/// passphrase; with it on, the server, how the last sync went, "Sync now"
/// and "Turn off".
///
/// Turning sync on reads the folder first. A folder that already has a
/// vault's sync file is joined: its salt gives every device the same key,
/// and the file has to open with the passphrase typed. An empty folder gets
/// a new salt. Either way the key is kept with the settings, encrypted with
/// the vault, so the passphrase is never stored.
class SyncSheet extends ConsumerStatefulWidget {
  const SyncSheet({super.key});

  @override
  ConsumerState<SyncSheet> createState() => _SyncSheetState();
}

/// Where the vault's own entries sync, as the off sheet asks.
enum _Where { webdav, vaultwarden, kemlock }

class _SyncSheetState extends ConsumerState<SyncSheet> {
  var _where = _Where.webdav;
  DavAccount _dav = emptyDav;
  final _passphrase = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The button turns on once there's a passphrase.
    _passphrase.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _close() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  // Nothing connects while offline mode is on (openspec: add-offline-mode, "Setting up a server waits")
  bool get _canConnect =>
      !ref.read(offlineProvider) && !_busy && _dav.url.trim().isNotEmpty && _dav.username.trim().isNotEmpty && _passphrase.text.isNotEmpty;

  Future<void> _connect() async {
    final session = ref.read(vaultControllerProvider).session;
    if (ref.read(syncProvider).settings == null || session == null || !_canConnect) return;
    final passphrase = _passphrase.text;
    if (passphrase.length < 8) {
      setState(() => _error = context.t('sync.error.shortPassphrase'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final dav = _dav;
    final store = ref.read(syncProvider.notifier);
    try {
      final existing = await ref.read(webDavProvider).readFile(dav, syncFile);
      // Joining an existing sync: its salt gives the same key, and the file proves the passphrase
      final kdf = existing != null ? readKdf(existing.text) : newKdf();
      // A space's file has no passphrase salt; it isn't this folder's vault sync
      if (kdf == null) throw const SyncFileError(SyncFileProblem.format);
      final key = await deriveSyncKey(passphrase, kdf, derive: ref.read(syncDeriveKeyProvider));
      if (existing != null) await decryptSyncFile(existing.text, key);
      await store.forgetScope(personalScope, session);
      // Read again, so spaces joined meanwhile are kept
      final settings = store.snapshot.settings ?? noSync;
      await store.saveSettings(
        settings.copyWith(
          personal: SyncTarget(dav: dav, file: syncFile, key: b64(key), kdf: kdf),
        ),
        session,
      );
      if (mounted) _passphrase.clear();
    } catch (e) {
      if (mounted) setState(() => _error = problemText(context, problemOf(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    final settings = ref.read(syncProvider).settings;
    final session = ref.read(vaultControllerProvider).session;
    if (settings == null || session == null) return;
    final store = ref.read(syncProvider.notifier);
    await store.saveSettings(settings.copyWith(personal: null), session);
    await store.forgetScope(personalScope, session);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt when offline mode is turned on or off, as it decides what each view offers
    ref.watch(offlineProvider);
    final sync = ref.watch(syncProvider);
    final personal = sync.settings?.personal;
    if (sync.settings?.kemlock case final target? when !sync.settings!.ownEntriesClash) {
      return KemlockOn(target: target, onClose: () => Navigator.of(context).pop());
    }
    if (sync.settings?.vaultwarden case final target?) {
      return VaultwardenOn(target: target, onClose: () => Navigator.of(context).pop());
    }
    if (personal == null && _where == _Where.vaultwarden) {
      return VaultwardenSetup(top: _whereChoice(context), onClose: () => Navigator.of(context).pop());
    }
    if (personal == null && _where == _Where.kemlock) {
      return KemlockSetup(top: _whereChoice(context), onClose: () => Navigator.of(context).pop());
    }
    return PopScope(canPop: !_busy, child: personal != null ? _on(context, sync, personal) : _off(context));
  }

  /// WebDAV folder or Vaultwarden, at the top of the off sheet.
  Widget _whereChoice(BuildContext context) => SegmentedControl<_Where>(
    semanticLabel: context.t('sync.where'),
    value: _where,
    onChanged: (where) => setState(() {
      _where = where;
      _error = null;
    }),
    options: [
      SegmentOption(value: _Where.webdav, label: context.t('sync.where.webdav')),
      SegmentOption(value: _Where.vaultwarden, label: context.t('sync.where.vaultwarden')),
      SegmentOption(value: _Where.kemlock, label: context.t('sync.where.kemlock')),
    ],
  );

  Widget _on(BuildContext context, SyncSnapshot sync, SyncTarget personal) {
    final p = context.palette;
    final status = sync.status[personalScope];
    final offline = ref.watch(offlineProvider);
    return SyncSheetFrame(
      icon: const Icon(Icons.cloud_sync_outlined),
      title: context.t('sync.title'),
      leading: TextButton(
        style: TextButton.styleFrom(foregroundColor: p.error),
        onPressed: _turnOff,
        child: Text(context.t('sync.off')),
      ),
      actions: [
        TextButton.icon(
          onPressed: sync.running || offline ? null : ref.read(syncProvider.notifier).requestSync,
          icon: const Icon(Icons.sync_rounded, size: 20),
          label: Text(context.t('sync.now')),
        ),
        FilledButton(onPressed: _close, child: Text(context.t('export.close'))),
      ],
      children: [
        SheetText(context.t('sync.on.body', {'host': davHost(personal.dav)})),
        // Paused, not failed: the last sync's time and result stay shown under it
        if (offline) OfflineAlert(context.t('sync.offline')),
        Semantics(
          liveRegion: true,
          child: AppAlert(
            severity: status?.problem != null ? AlertSeverity.error : AlertSeverity.success,
            child: Text(statusText(context, status)),
          ),
        ),
        if (sync.running) LinearProgressIndicator(semanticsLabel: context.t('sync.running')),
        Text(context.t('sync.on.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
      ],
    );
  }

  Widget _off(BuildContext context) => SyncSheetFrame(
    icon: const Icon(Icons.cloud_sync_outlined),
    title: context.t('sync.title'),
    actions: [
      TextButton(style: inheritButtonStyle(context), onPressed: _busy ? null : _close, child: Text(context.t('changePw.cancel'))),
      FilledButton(onPressed: _canConnect ? _connect : null, child: Text(context.t('sync.connect'))),
    ],
    children: [
      _whereChoice(context),
      SheetText(context.t('sync.body')),
      if (ref.watch(offlineProvider)) OfflineAlert(context.t('sync.offline.setup')),
      if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
      DavFields(value: _dav, enabled: !_busy, onChanged: (dav) => setState(() => _dav = dav)),
      TextField(
        controller: _passphrase,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        // Null, not the empty default: the phone's password manager neither fills nor saves it, and it
        // stays out of the WebDAV fields' autofill group above, which offers to save their sign-in
        autofillHints: null,
        enableIMEPersonalizedLearning: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _connect(),
        decoration: InputDecoration(
          labelText: context.t('sync.field.passphrase'),
          helperText: context.t('sync.field.passphraseHelper'),
          helperMaxLines: 3,
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
    ],
  );
}
