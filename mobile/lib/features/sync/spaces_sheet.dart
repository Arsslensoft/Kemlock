import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/providers.dart';
import '../../crypto/bytes.dart';
import '../../i18n/messages.dart';
import '../../platform/network.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_registry.dart';
import '../scan/qr_viewfinder.dart';
import '../settings/offline_alert.dart';
import '../spaces/server_spaces_list.dart';
import '../spaces/space_bridge.dart';
import '../spaces/space_move.dart';
import '../spaces/space_scope.dart' show serverSpaceUuidOrNull;
import 'dav_fields.dart';
import 'sync.dart';
import 'sync_crypto.dart';
import 'sync_kdf.dart';
import 'sync_merge.dart';
import 'sync_messages.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';
import 'webdav.dart';

/// Creates, joins, shares and leaves shared spaces, ported from
/// `SpacesDialog.tsx`.
Future<void> showSpacesSheet(BuildContext context) =>
    showAppBottomSheet<void>(context, label: context.t('spaces.title'), builder: (context) => const SpacesSheet());

enum _Mode { list, create, join, invite }

/// A space's invite on screen, with the one-time code that opens it.
typedef _Invite = ({Space space, String code, String text});

/// Shared spaces: accounts and backup codes that sync to everyone
/// in the space through one shared WebDAV folder, such as a shared
/// Nextcloud folder.
///
/// The list shows each space with how many entries are in it, its server
/// and how its last sync went, and offers to invite someone or leave.
/// Creating a space writes its empty, encrypted file to the folder and
/// shows its invite: a line of text and its QR code, sealed with a
/// one-time code shown apart, to be told rather than sent. Joining takes
/// the invite, pasted or scanned, and the code, and checks the space's
/// file opens in the folder given. Leaving takes the space's entries off
/// this device; everyone else keeps them.
class SpacesSheet extends ConsumerStatefulWidget {
  const SpacesSheet({super.key});

  @override
  ConsumerState<SpacesSheet> createState() => _SpacesSheetState();
}

class _SpacesSheetState extends ConsumerState<SpacesSheet> {
  _Mode _mode = _Mode.list;
  _Invite? _invite;
  final _name = TextEditingController();
  final _inviteText = TextEditingController();
  final _code = TextEditingController();
  DavAccount _dav = emptyDav;
  bool _scanning = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The buttons turn on as the fields fill.
    for (final controller in [_name, _inviteText, _code]) {
      controller.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _inviteText.dispose();
    _code.dispose();
    super.dispose();
  }

  SyncNotifier get _store => ref.read(syncProvider.notifier);

  void _toList() => setState(() {
    _mode = _Mode.list;
    _invite = null;
    _name.clear();
    _inviteText.clear();
    _code.clear();
    _scanning = false;
    _error = null;
  });

  void _close() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  // Most people put the shared folder on the server they already sync with
  void _startWith(_Mode mode) {
    final personal = ref.read(syncProvider).settings?.personal;
    setState(() {
      _dav = personal != null ? personal.dav.copyWith(url: '') : emptyDav;
      _error = null;
      _mode = mode;
    });
  }

  Future<void> _showInvite(Space space) async {
    final code = newInviteCode();
    final text = await sealInvite(
      SpaceInvite(id: space.id, name: space.name, file: space.target.file, key: unb64(space.target.key)),
      code,
      derive: ref.read(syncDeriveKeyProvider),
    );
    if (!mounted) return;
    setState(() {
      _invite = (space: space, code: code, text: text);
      _mode = _Mode.invite;
    });
  }

  /// Seals a new invite for a space in the list.
  Future<void> _inviteTo(Space space) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _showInvite(space);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _offline => ref.read(offlineProvider);

  bool get _canCreate => !_offline && !_busy && _name.text.trim().isNotEmpty && _dav.url.trim().isNotEmpty;

  Future<void> _create() async {
    final session = ref.read(vaultControllerProvider).session;
    if (ref.read(syncProvider).settings == null || session == null || !_canCreate) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = VaultRegistry.newVaultId();
      final key = randomBytes(32);
      final space = Space(
        id: id,
        name: _name.text.trim(),
        target: SyncTarget(dav: _dav, file: spaceFile(id), key: b64(key)),
        joinedAt: ref.read(clockProvider)().millisecondsSinceEpoch,
      );
      final empty = await encryptSyncFile(const SyncDoc(), key);
      await ref.read(webDavProvider).writeFile(space.target.dav, space.target.file, empty, mustNotExist: true);
      final settings = _store.snapshot.settings ?? noSync;
      await _store.saveSettings(settings.copyWith(spaces: [...settings.spaces, space]), session);
      await _showInvite(space);
    } catch (e) {
      if (mounted) setState(() => _error = problemText(context, problemOf(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canJoin =>
      !_offline && !_busy && _inviteText.text.trim().isNotEmpty && _code.text.trim().isNotEmpty && _dav.url.trim().isNotEmpty;

  Future<void> _join() async {
    final session = ref.read(vaultControllerProvider).session;
    if (ref.read(syncProvider).settings == null || session == null || !_canJoin) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final dav = _dav;
    String? error;
    try {
      final invite = await openInvite(_inviteText.text, _code.text, derive: ref.read(syncDeriveKeyProvider));
      final settings = _store.snapshot.settings ?? noSync;
      if (settings.spaces.any((space) => space.id == invite.id)) {
        if (mounted) error = context.t('spaces.error.joined', {'name': invite.name});
        return;
      }
      final file = await ref.read(webDavProvider).readFile(dav, invite.file);
      if (file == null) {
        if (mounted) error = context.t('spaces.error.noFile');
        return;
      }
      await decryptSyncFile(file.text, invite.key);
      final space = Space(
        id: invite.id,
        name: invite.name,
        target: SyncTarget(dav: dav, file: invite.file, key: b64(invite.key)),
        joinedAt: ref.read(clockProvider)().millisecondsSinceEpoch,
      );
      final latest = _store.snapshot.settings ?? settings;
      await _store.saveSettings(latest.copyWith(spaces: [...latest.spaces, space]), session);
      if (!mounted) return;
      showToast(context, context.t('spaces.joined', {'name': space.name}));
      _toList();
    } on InviteError catch (e) {
      if (mounted) error = context.t('spaces.error.invite.${e.problem.name}');
    } catch (e) {
      if (mounted) error = problemText(context, problemOf(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _leave(Space space) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('spaces.leave.title', {'name': space.name}),
      body: Text(context.t('spaces.leave.body')),
      confirmLabel: context.t('spaces.leave.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    final session = ref.read(vaultControllerProvider).session;
    if (!mounted || !confirmed || session == null || _store.snapshot.settings == null) return;
    // The space's entries of every kind go; the vault's own and other spaces' stay
    final lists = ref.read(vaultControllerProvider).lists;
    await ref.read(vaultControllerProvider.notifier).applySynced(applyScope(lists, space.id, const Lists()));
    final settings = _store.snapshot.settings ?? noSync;
    await _store.saveSettings(
      settings.copyWith(
        spaces: [
          for (final s in settings.spaces)
            if (s.id != space.id) s,
        ],
      ),
      session,
    );
    await _store.forgetScope(space.id, session);
  }

  // ─── A WebDAV space that moves to Kemlock Server (docs/plans/add-server-spaces.md, design 7) ───

  int get _now => ref.read(clockProvider)().millisecondsSinceEpoch;

  /// Stores [next] in place of the settings' space with its id, from the latest settings.
  Future<void> _saveSpace(Space next) async {
    final session = ref.read(vaultControllerProvider).session;
    final settings = _store.snapshot.settings;
    if (session == null || settings == null) {
      return;
    }
    await _store.saveSettings(
      settings.copyWith(
        spaces: [
          for (final space in settings.spaces)
            if (space.id == next.id) next else space,
        ],
      ),
      session,
    );
  }

  /// Moves a WebDAV space to Kemlock Server. The space is marked `moving` first, so a phone that stops midway still syncs the
  /// file alone and the move runs again from the button; it is marked `bridged` only once the server's copy read back the same.
  Future<void> _move(Space space) async {
    final mover = ref.read(spaceMoverProvider);
    final uuid = serverSpaceUuidOrNull(space.id);
    if (mover == null || uuid == null || _busy || _offline) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('spaces.move.title', {'name': space.name}),
      body: Text(context.t('spaces.move.body')),
      confirmLabel: context.t('spaces.move.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    if (!mounted || !confirmed) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    // The scheduler leaves the space alone while its entries are being copied (`SyncNotifier.isMoving`); held before the first await,
    // since the sheet may be gone when the move ends
    final store = _store..setMoving(space.id, moving: true);
    try {
      // Marked moving first and bridged once the server's copy read back the same: see [moveWebDavSpace]
      await moveWebDavSpace(
        space: space,
        mover: mover,
        lists: ref.read(vaultControllerProvider).lists,
        save: _saveSpace,
        now: () => _now,
        // The merge of the file with what the space already held, which the read-back checked: this phone takes it
        applyMerged: (merged) async {
          final current = ref.read(vaultControllerProvider).lists;
          await ref.read(vaultControllerProvider.notifier).applySynced(applyScope(current, space.id, merged));
        },
      );
      if (mounted) {
        showToast(context, context.t('spaces.move.done', {'name': space.name}));
      }
    } on SpaceMoveError catch (e) {
      if (mounted) {
        error = context.t('spaces.move.failed', {'problem': e.problem.name});
      }
    } catch (_) {
      if (mounted) {
        error = context.t('spaces.move.failed', {'problem': 'other'});
      }
    } finally {
      // The scheduler syncs the space again, as a WebDAV space or as the bridge the move made
      store.setMoving(space.id, moving: false);
      store.requestSync();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error;
        });
      }
    }
  }

  /// The Owner closes the WebDAV copy of a moved space: no moved phone reads or writes the file afterwards.
  Future<void> _closeCopy(Space space) async {
    final mover = ref.read(spaceMoverProvider);
    final note = space.onServer;
    if (mover == null || note == null || _busy || _offline) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('spaces.copy.close.title', {'name': space.name}),
      body: Text(context.t('spaces.copy.close.body')),
      confirmLabel: context.t('spaces.copy.close.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    if (!mounted || !confirmed) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await mover.closeCopy(space.id);
      await _saveSpace(space.withOnServer(note.to(SpaceCopy.closed, _now, reason: SpaceCopyClosed.owner)));
    } on SpaceMoveError catch (e) {
      if (mounted) {
        error = context.t('spaces.copy.closeFailed', {'problem': e.problem.name});
      }
    } catch (_) {
      if (mounted) {
        error = context.t('spaces.copy.closeFailed', {'problem': 'other'});
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error;
        });
      }
    }
  }

  /// Deletes the closed copy's file from the folder, which the app offers and never does by itself.
  Future<void> _deleteFile(Space space) async {
    final note = space.onServer;
    if (note == null || _busy || _offline) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('spaces.copy.delete.title'),
      body: Text(context.t('spaces.copy.delete.body')),
      confirmLabel: context.t('spaces.copy.delete.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    if (!mounted || !confirmed) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await ref.read(webDavProvider).deleteFile(space.target.dav, space.target.file);
      await _saveSpace(space.withOnServer(note.withFileDeleted()));
      if (mounted) {
        showToast(context, context.t('spaces.copy.deleted'));
      }
    } catch (_) {
      if (mounted) {
        error = context.t('spaces.copy.deleteFailed');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error;
        });
      }
    }
  }

  /// The person agrees to merge this WebDAV space into the server space found for it, whose Owner is named: the space is marked
  /// `joining`, which makes its entries a server space's, and the next sync merges the file in once and stops writing it.
  Future<void> _mergeInto(Space space) async {
    final note = space.onServer;
    if (note == null || note.state != SpaceCopy.offered || _busy) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: context.t('spaces.merge.title', {'name': space.name}),
      body: Text(context.t('spaces.merge.body', {'name': space.name, 'owner': note.owner ?? ''})),
      confirmLabel: context.t('spaces.merge.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    if (!mounted || !confirmed) {
      return;
    }
    await _saveSpace(space.withOnServer(note.to(SpaceCopy.joining, _now)));
  }

  /// The server space of a moved space, in its own sheet.
  Future<void> _openOnServer(Space space) async {
    final source = ref.read(serverSpacesSourceProvider);
    final uuid = space.onServer?.uuid;
    if (source == null || uuid == null) {
      return;
    }
    await showAppBottomSheet<void>(
      context,
      label: space.name,
      builder: (context) => source.sheetFor((id: uuid, name: space.name, status: 'confirmed')),
    );
  }

  Future<void> _copyInvite(String text) async {
    final ok = await ref.read(secretClipboardProvider).copy(text);
    if (!mounted) return;
    showToast(
      context,
      context.t(ok ? 'spaces.invite.copied' : 'spaces.invite.copyFailed'),
      severity: ok ? ToastSeverity.success : ToastSeverity.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Creating and joining a space contact its server, so both wait while offline mode is on
    ref.watch(offlineProvider);
    final title = switch (_mode) {
      _Mode.list => context.t('spaces.title'),
      _Mode.create => context.t('spaces.create.title'),
      _Mode.join => context.t('spaces.join.title'),
      _Mode.invite => context.t('spaces.invite.title', {'name': _invite?.space.name ?? ''}),
    };
    final cancel = TextButton(
      style: inheritButtonStyle(context),
      onPressed: _busy ? null : _toList,
      child: Text(context.t('changePw.cancel')),
    );
    final (List<Widget> children, List<Widget> actions) = switch (_mode) {
      _Mode.list => (
        _list(context),
        [TextButton(style: inheritButtonStyle(context), onPressed: _close, child: Text(context.t('export.close')))],
      ),
      _Mode.create => (
        _createForm(context),
        [cancel, FilledButton(onPressed: _canCreate ? _create : null, child: Text(context.t('spaces.create.button')))],
      ),
      _Mode.join => (
        _joinForm(context),
        [cancel, FilledButton(onPressed: _canJoin ? _join : null, child: Text(context.t('spaces.join.button')))],
      ),
      _Mode.invite => (_inviteView(context, _invite!), [FilledButton(onPressed: _toList, child: Text(context.t('enableBiometric.done')))]),
    };
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(icon: const Icon(Icons.groups_outlined), title: title, actions: actions, children: children),
    );
  }

  Widget? _errorAlert() => _error == null ? null : AppAlert(severity: AlertSeverity.error, child: Text(_error!));

  List<Widget> _list(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final sync = ref.watch(syncProvider);
    final vault = ref.watch(vaultControllerProvider);
    final spaces = sync.settings?.spaces ?? const <Space>[];
    // A vault signed in to Kemlock Server lists its server spaces apart from the WebDAV ones
    final hasServerSpaces = ref.watch(serverSpacesSourceProvider) != null;
    final canMove = ref.watch(spaceMoverProvider) != null;
    ButtonStyle tinted(Color background, Color foreground) => FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      disabledBackgroundColor: background,
      disabledForegroundColor: p.disabled,
    );
    return [
      SheetText(context.t('spaces.body')),
      if (_offline) OfflineAlert(context.t('sync.offline')),
      ?_errorAlert(),
      if (hasServerSpaces)
        Text(
          context.t('spaces.webdav.title'),
          style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w700),
        ),
      if (spaces.isEmpty)
        Text(context.t('spaces.empty'), style: AppType.body2.copyWith(color: b.faint))
      else
        for (final space in spaces)
          _SpaceCard(
            space: space,
            count: scopeLists(vault.lists, space.id).ids.length,
            status: sync.status[space.id],
            onInvite: _busy ? null : () => _inviteTo(space),
            onLeave: _busy ? null : () => _leave(space),
            // Only a vault signed in to Kemlock Server can move a space; a moved one opens its server space instead
            showMove: canMove && !(space.onServer?.onServer ?? false) && space.onServer?.state != SpaceCopy.offered,
            onMove: _busy || _offline ? null : () => _move(space),
            showOpen: hasServerSpaces && (space.onServer?.onServer ?? false),
            onOpenServer: _busy ? null : () => _openOnServer(space),
            // The Owner closes a bridged copy; a closed one offers to delete the file
            showClose: canMove && space.onServer?.state == SpaceCopy.bridged,
            onClose: _busy || _offline ? null : () => _closeCopy(space),
            onDeleteFile: _busy || _offline ? null : () => _deleteFile(space),
            onJoin: _busy || _offline ? null : () => _mergeInto(space),
          ),
      if (_busy) const LinearProgressIndicator(),
      if (hasServerSpaces) ServerSpacesList(canMake: !_offline),
      Row(
        spacing: 8,
        children: [
          Expanded(
            child: FilledButton.icon(
              style: tinted(b.accentSoft, b.accentText),
              onPressed: _busy || _offline ? null : () => _startWith(_Mode.create),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(context.t('spaces.create')),
            ),
          ),
          Expanded(
            child: FilledButton.icon(
              style: tinted(b.raised, p.text),
              onPressed: _busy || _offline ? null : () => _startWith(_Mode.join),
              icon: const Icon(Icons.login_rounded, size: 20),
              label: Text(context.t('spaces.join')),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _createForm(BuildContext context) => [
    SheetText(context.t('spaces.create.body')),
    if (_offline) OfflineAlert(context.t('sync.offline.setup')),
    ?_errorAlert(),
    TextField(
      enableIMEPersonalizedLearning: false,
      controller: _name,
      enabled: !_busy,
      autofocus: true,
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: context.t('spaces.field.name'), hintText: context.t('spaces.field.namePlaceholder')),
    ),
    DavFields(
      key: const ValueKey(_Mode.create),
      value: _dav,
      enabled: !_busy,
      urlHelper: context.t('spaces.field.urlHelper'),
      onChanged: (dav) => setState(() => _dav = dav),
    ),
    if (_busy) const LinearProgressIndicator(),
  ];

  List<Widget> _joinForm(BuildContext context) {
    final b = context.bmc;
    final scan = context.t('recovery.collect.scan');
    return [
      SheetText(context.t('spaces.join.body')),
      if (_offline) OfflineAlert(context.t('sync.offline.setup')),
      ?_errorAlert(),
      if (_scanning)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            QrViewfinder(
              onScan: (data) => setState(() {
                _scanning = false;
                if (_offline) {
                  // Nothing of the invite is kept: joining would contact its server
                  _inviteText.clear();
                  _error = context.t('sync.offline.invite');
                } else {
                  _inviteText.text = data;
                }
              }),
            ),
            TextButton(
              style: inheritButtonStyle(context),
              onPressed: () => setState(() => _scanning = false),
              child: Text(context.t('recovery.collect.stopScan')),
            ),
          ],
        )
      else
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: _inviteText,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.t('spaces.field.invite'), hintText: 'bmc-space:…'),
              ),
            ),
            Tooltip(
              message: scan,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: b.accentSoft,
                  foregroundColor: b.accentText,
                  minimumSize: const Size(56, 56),
                  maximumSize: const Size(56, 56),
                  padding: EdgeInsets.zero,
                ),
                onPressed: _busy ? null : () => setState(() => _scanning = true),
                child: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ),
          ],
        ),
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: _code,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.next,
        style: AppType.mono(fontSize: 15),
        decoration: InputDecoration(labelText: context.t('spaces.field.code'), hintText: 'XXXX-XXXX-XXXX'),
      ),
      DavFields(
        key: const ValueKey(_Mode.join),
        value: _dav,
        enabled: !_busy,
        urlHelper: context.t('spaces.field.urlHelper'),
        onChanged: (dav) => setState(() => _dav = dav),
      ),
      if (_busy) const LinearProgressIndicator(),
    ];
  }

  List<Widget> _inviteView(BuildContext context, _Invite invite) {
    final p = context.palette;
    final b = context.bmc;
    return [
      SheetText(context.t('spaces.invite.body')),
      Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(18)),
          child: QrImageView(
            data: invite.text,
            size: 196,
            padding: EdgeInsets.zero,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            backgroundColor: const Color(0xFFFFFFFF),
            semanticsLabel: context.t('spaces.field.invite'),
          ),
        ),
      ),
      TextButton.icon(
        onPressed: () => _copyInvite(invite.text),
        icon: const Icon(Icons.content_copy_rounded, size: 20),
        label: Text(context.t('spaces.invite.copy')),
      ),
      Column(
        children: [
          Text(context.t('spaces.invite.code').toUpperCase(), style: AppType.overline.copyWith(color: b.faint)),
          const SizedBox(height: 4),
          Text(
            invite.code,
            style: AppType.mono(fontSize: 24, color: p.text).copyWith(letterSpacing: 24 * 0.08),
          ),
        ],
      ),
      AppAlert(severity: AlertSeverity.warning, child: Text(context.t('spaces.invite.warning'))),
    ];
  }
}

/// One space in the list: its name, how many entries are in it and where,
/// how its last sync went, and Invite and Leave. A WebDAV space of a vault signed in to Kemlock Server can also move; one that
/// moved says where its copies stand, and opens its server space.
class _SpaceCard extends StatelessWidget {
  const _SpaceCard({
    required this.space,
    required this.count,
    required this.status,
    required this.onInvite,
    required this.onLeave,
    required this.showMove,
    required this.onMove,
    required this.showOpen,
    required this.onOpenServer,
    required this.showClose,
    required this.onClose,
    required this.onDeleteFile,
    required this.onJoin,
  });

  final Space space;
  final int count;
  final ScopeStatus? status;
  final VoidCallback? onInvite;
  final VoidCallback? onLeave;
  final bool showMove;
  final VoidCallback? onMove;
  final bool showOpen;
  final VoidCallback? onOpenServer;
  final bool showClose;
  final VoidCallback? onClose;
  final VoidCallback? onDeleteFile;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final problem = status?.problem != null;
    final note = space.onServer;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: space.name,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              space.name,
              style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
            ),
            Text(
              context.t('spaces.row', {'count': count, 'host': davHost(space.target.dav)}),
              style: AppType.caption.copyWith(color: p.textSecondary),
            ),
            if (note != null)
              Text(
                context.t('spaces.copy.row', {'state': note.state.name}),
                key: ValueKey('space-copy-${space.id}'),
                style: AppType.caption.copyWith(color: p.textSecondary),
              ),
            Text(statusText(context, status), style: AppType.caption.copyWith(color: problem ? p.error : p.textSecondary)),
            if (note != null && note.state == SpaceCopy.closed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${context.t('spaces.copy.closed', {'reason': note.reason?.name ?? 'owner'})} '
                  '${context.t(note.fileDeleted ? 'spaces.copy.closed.gone' : 'spaces.copy.closed.kept')}',
                  key: ValueKey('space-closed-${space.id}'),
                  style: AppType.caption.copyWith(color: p.textSecondary),
                ),
              ),
            if (note != null && note.state == SpaceCopy.offered)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  context.t('spaces.merge.found', {'owner': note.owner ?? ''}),
                  key: ValueKey('space-offered-${space.id}'),
                  style: AppType.caption.copyWith(color: p.textSecondary),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                // A space on Kemlock Server is invited to by email there: a bmc-space: invite would hand out the WebDAV file's key
                if (note == null || note.state == SpaceCopy.moving || note.state == SpaceCopy.offered)
                  TextButton(style: smallButtonStyle, onPressed: onInvite, child: Text(context.t('spaces.invite'))),
                if (note != null && note.state == SpaceCopy.offered)
                  TextButton(
                    key: ValueKey('space-merge-${space.id}'),
                    style: smallButtonStyle,
                    onPressed: onJoin,
                    child: Text(context.t('spaces.merge')),
                  ),
                if (showMove)
                  TextButton(
                    key: ValueKey('space-move-${space.id}'),
                    style: smallButtonStyle,
                    onPressed: onMove,
                    child: Text(context.t('spaces.move')),
                  ),
                if (showOpen)
                  TextButton(
                    key: ValueKey('space-open-${space.id}'),
                    style: smallButtonStyle,
                    onPressed: onOpenServer,
                    child: Text(context.t('spaces.copy.open')),
                  ),
                if (showClose)
                  TextButton(
                    key: ValueKey('space-close-${space.id}'),
                    style: smallButtonStyle,
                    onPressed: onClose,
                    child: Text(context.t('spaces.copy.close')),
                  ),
                if (note != null && note.state == SpaceCopy.closed && !note.fileDeleted)
                  TextButton(
                    key: ValueKey('space-delete-file-${space.id}'),
                    style: smallButtonStyle,
                    onPressed: onDeleteFile,
                    child: Text(context.t('spaces.copy.delete')),
                  ),
                TextButton(
                  style: smallButtonStyle.merge(TextButton.styleFrom(foregroundColor: p.error)),
                  onPressed: onLeave,
                  child: Text(context.t('spaces.leave')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
