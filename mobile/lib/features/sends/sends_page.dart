/// The owner's Sends, opened from the Vault tab (`docs/plans/add-sends.md`, design 5 and tasks 6.1 and 6.2): each Send's
/// name, kind, status, opens used and deletion date, read again each time the page opens and on a pull down. Nothing
/// about a Send is kept on the phone: a row's link is rebuilt from its sealed key when Copy link is asked for.
///
/// A row opens its sheet, with Copy link, Share link, Show text (which makes no public request, so it spends no open),
/// Edit and Delete. A Send whose meta doesn't open here shows as "Can't be read on this phone", with Delete only.
///
/// The Sends the account made from a Bitwarden app are in a section of their own, "Made in a Bitwarden app". Their key
/// isn't Kemlock's, so nothing of them is opened: a row shows what the server keeps in plain, and its sheet says to open,
/// change or share it there, with Delete only.
///
/// The page says why it lists nothing: offline mode, no Kemlock Server sync, a session the server ended, or a home
/// server that is away. "Open a Send" works whatever the account.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell_page.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/network.dart';
import '../../platform/secret_clipboard.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../settings/offline_alert.dart';
import '../sync/kemlock/km_api.dart';
import '../sync/sync_sheet_frame.dart';
import '../sync/sync_store.dart';
import 'new_send_sheet.dart';
import 'open_send_sheet.dart';
import 'send_edit_sheet.dart';
import 'sends_providers.dart';
import 'sends_service.dart';
import 'sends_support.dart';

/// The Sends page.
class SendsPage extends ConsumerStatefulWidget {
  const SendsPage({super.key});

  @override
  ConsumerState<SendsPage> createState() => _SendsPageState();
}

class _SendsPageState extends ConsumerState<SendsPage> {
  SendsListing? _sends;
  Object? _error;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    // The list is read again when the sync's host comes up, or the phone leaves offline mode
    ref.listenManual(sendsServiceProvider, (_, service) {
      if (service != null) unawaited(_load());
    });
    ref.listenManual(offlineProvider, (_, offline) {
      if (!offline) unawaited(_load());
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = ref.read(sendsServiceProvider);
    if (service == null || ref.read(offlineProvider) || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sends = await service.listing();
      if (mounted) setState(() => _sends = sends);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _sends = null;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _new() async {
    await showNewSendSheet(context);
    if (mounted) unawaited(_load());
  }

  Future<void> _openRow(OwnedSend owned) async {
    final changed = await showSendDetailSheet(context, owned);
    if (changed == true && mounted) unawaited(_load());
  }

  Future<void> _openForeign(ForeignSend foreign) async {
    final changed = await showForeignSendSheet(context, foreign);
    if (changed == true && mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final offline = ref.watch(offlineProvider);
    final service = ref.watch(sendsServiceProvider);
    final away = ref.watch(kemlockAwayProvider);
    final sends = _sends;
    final error = _error;
    final sessionEnded = error is KmError && error.problem == KmProblem.sessionEnded;
    return Scaffold(
      backgroundColor: p.background,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: ShellPage.padding(context),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => context.go('/vault'),
              ),
            ),
            PageTitle(title: context.t('sends.title'), subtitle: context.t('sends.subtitle')),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: offline || service == null || away != null ? null : () => unawaited(_new()),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(context.t('sends.new')),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(showOpenSendSheet(context)),
                  icon: const Icon(Icons.link_rounded),
                  label: Text(context.t('sends.open')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (offline)
              OfflineAlert(context.t('sends.offline'))
            else if (service == null)
              AppAlert(
                severity: AlertSeverity.info,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.t('sends.noSync')),
                    TextButton(onPressed: () => context.go('/settings'), child: Text(context.t('sends.noSync.action'))),
                  ],
                ),
              )
            else ...[
              if (away != null)
                AppAlert(severity: AlertSeverity.warning, child: Text(context.t('sends.away', {'time': sendsTime(context, away.since)}))),
              if (error != null && away == null)
                AppAlert(
                  severity: AlertSeverity.error,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sessionEnded ? context.t('sends.sessionEnded') : context.t('sends.loadFailed')),
                      if (!sessionEnded) TextButton(onPressed: () => unawaited(_load()), child: Text(context.t('sends.retry'))),
                    ],
                  ),
                ),
              if (_loading && sends == null) const LinearProgressIndicator(),
              if (sends != null && sends.isEmpty)
                EmptyState(
                  icon: const Icon(Icons.send_rounded),
                  title: context.t('sends.empty.title'),
                  body: context.t('sends.empty.body'),
                ),
              if (sends != null && sends.owned.isNotEmpty)
                Group(
                  children: [
                    for (final (i, owned) in sends.owned.indexed)
                      _SendRow(
                        key: ValueKey('send:${owned.send.id}'),
                        owned: owned,
                        first: i == 0,
                        onTap: () => unawaited(_openRow(owned)),
                      ),
                  ],
                ),
              if (sends != null && sends.foreign.isNotEmpty) ...[
                SectionLabel(context.t('sends.foreign.title')),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                  child: Text(context.t('sends.foreign.note'), style: AppType.caption.copyWith(color: p.textSecondary)),
                ),
                Group(
                  children: [
                    for (final (i, foreign) in sends.foreign.indexed)
                      _ForeignRow(
                        key: ValueKey('foreign:${foreign.send.id}'),
                        foreign: foreign,
                        first: i == 0,
                        onTap: () => unawaited(_openForeign(foreign)),
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _statusId(OwnedSend owned) {
  if (!owned.readable) return 'sends.status.unreadable';
  return _statusOf(owned.status);
}

String _statusOf(SendStatus status) => switch (status) {
  SendStatus.active => 'sends.status.active',
  SendStatus.expired => 'sends.status.expired',
  SendStatus.usedUp => 'sends.status.usedUp',
  SendStatus.off => 'sends.status.off',
  SendStatus.waitingForFile => 'sends.status.waiting',
};

String _foreignName(BuildContext context, ForeignSend foreign) =>
    context.t('sends.foreign.name', {'kind': foreign.isFile ? 'file' : 'text'});

class _SendRow extends StatelessWidget {
  const _SendRow({super.key, required this.owned, required this.first, required this.onTap});

  final OwnedSend owned;
  final bool first;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final send = owned.send;
    final limit = send.maxAccess;
    final problem = !owned.readable;
    final status = problem ? null : owned.status;
    final tone = status == null || status == SendStatus.active ? null : StatusTone.warning;
    return GroupRow(
      first: first,
      icon: Icon(owned.isFile ? Icons.attach_file_rounded : Icons.notes_rounded),
      primary: owned.meta?.name ?? context.t('sends.status.unreadable'),
      secondary: [
        context.t(owned.isFile ? 'sends.kind.file' : 'sends.kind.text'),
        context.t('sends.row.opens', {'count': send.accessCount, 'limit': limit ?? 'none'}),
        context.t('sends.row.deletes', {'date': sendsDate(context, send.deletionAt)}),
      ].join(' · '),
      tag: problem
          ? StatusTag(label: context.t(_statusId(owned)), tone: StatusTone.danger)
          : StatusTag(label: context.t(_statusId(owned)), tone: tone ?? StatusTone.accent),
      onTap: onTap,
    );
  }
}

/// A Send a Bitwarden app made: its kind and what the server keeps in plain, and a tap that opens its sheet.
class _ForeignRow extends StatelessWidget {
  const _ForeignRow({super.key, required this.foreign, required this.first, required this.onTap});

  final ForeignSend foreign;
  final bool first;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final send = foreign.send;
    final tone = foreign.status == SendStatus.active ? StatusTone.accent : StatusTone.warning;
    return GroupRow(
      first: first,
      icon: Icon(foreign.isFile ? Icons.attach_file_rounded : Icons.notes_rounded),
      primary: _foreignName(context, foreign),
      secondary: [
        context.t('sends.row.opens', {'count': send.accessCount, 'limit': send.maxAccess ?? 'none'}),
        context.t('sends.row.deletes', {'date': sendsDate(context, send.deletionAt)}),
      ].join(' · '),
      tag: StatusTag(label: context.t(_statusOf(foreign.status)), tone: tone),
      onTap: onTap,
    );
  }
}

/// Opens the sheet of [foreign]; true when the Send was deleted, so the list is read again.
Future<bool?> showForeignSendSheet(BuildContext context, ForeignSend foreign) => showAppBottomSheet<bool>(
  context,
  label: _foreignName(context, foreign),
  builder: (_) => ForeignSendSheet(foreign: foreign),
);

/// What a Send made in a Bitwarden app offers: the line that says to use that app, and Delete. It has no Copy link,
/// Share, Show text or Edit, and opens no edit sheet: its key isn't Kemlock's, so nothing of it is decrypted here.
class ForeignSendSheet extends ConsumerStatefulWidget {
  const ForeignSendSheet({super.key, required this.foreign});

  final ForeignSend foreign;

  @override
  ConsumerState<ForeignSendSheet> createState() => _ForeignSendSheetState();
}

class _ForeignSendSheetState extends ConsumerState<ForeignSendSheet> {
  var _busy = false;
  String? _error;

  Future<void> _delete() async {
    final service = ref.read(sendsServiceProvider);
    if (service == null || _busy) return;
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('sends.delete.title'),
      body: Text(context.t('sends.foreign.delete.body')),
      confirmLabel: context.t('sends.delete.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.deleteForeign(widget.foreign);
      if (!mounted) return;
      ref.read(toastsProvider.notifier).show(context.t('sends.deleted'));
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = sendsErrorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final foreign = widget.foreign;
    final send = foreign.send;
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: Icon(foreign.isFile ? Icons.attach_file_rounded : Icons.notes_rounded),
        title: _foreignName(context, foreign),
        actions: [
          FilledButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(context.t('sends.detail.close'))),
        ],
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusTag(
                label: context.t(_statusOf(foreign.status)),
                tone: foreign.status == SendStatus.active ? StatusTone.accent : StatusTone.warning,
              ),
              Text(
                context.t('sends.row.opens', {'count': send.accessCount, 'limit': send.maxAccess ?? 'none'}),
                style: AppType.caption.copyWith(color: p.textSecondary),
              ),
            ],
          ),
          SheetText(context.t('sends.row.deletes', {'date': sendsDate(context, send.deletionAt)})),
          SheetText(context.t('sends.foreign.note')),
          if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
          if (_busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: p.error),
                onPressed: _busy ? null : () => unawaited(_delete()),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: Text(context.t('sends.detail.delete')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens the sheet of [owned]; true when the Send was changed or deleted, so the list is read again.
Future<bool?> showSendDetailSheet(BuildContext context, OwnedSend owned) => showAppBottomSheet<bool>(
  context,
  label: owned.meta?.name ?? context.t('sends.status.unreadable'),
  builder: (_) => SendDetailSheet(owned: owned),
);

/// What one Send offers.
class SendDetailSheet extends ConsumerStatefulWidget {
  const SendDetailSheet({super.key, required this.owned});

  final OwnedSend owned;

  @override
  ConsumerState<SendDetailSheet> createState() => _SendDetailSheetState();
}

class _SendDetailSheetState extends ConsumerState<SendDetailSheet> {
  String? _text;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _text = null;
    super.dispose();
  }

  Future<T?> _guard<T>(Future<T> Function(SendsService service) action) async {
    final service = ref.read(sendsServiceProvider);
    if (service == null || _busy) return null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      return await action(service);
    } on Object catch (e) {
      if (mounted) setState(() => _error = sendsErrorText(context, e));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final link = await _guard((service) => service.linkOf(widget.owned));
    if (link == null || !mounted) return;
    final copied = await ref.read(secretClipboardProvider).copy(link);
    if (!mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show(context.t(copied ? 'sends.copied' : 'sends.copyFailed'), severity: copied ? ToastSeverity.success : ToastSeverity.error);
  }

  Future<void> _share() async {
    final link = await _guard((service) => service.linkOf(widget.owned));
    if (link == null || !mounted) return;
    await ref.read(fileServiceProvider).shareText(link);
  }

  Future<void> _toggleText() async {
    if (_text != null) {
      setState(() => _text = null);
      return;
    }
    final payload = await _guard((service) => service.view(widget.owned));
    if (payload != null && mounted) setState(() => _text = payload.text);
  }

  Future<void> _edit() async {
    final saved = await showSendEditSheet(context, widget.owned);
    if (saved == true && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final name = widget.owned.meta?.name ?? context.t('sends.status.unreadable');
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('sends.delete.title'),
      body: Text(context.t('sends.delete.body', {'name': name})),
      confirmLabel: context.t('sends.delete.confirm'),
      cancelLabel: context.t('changePw.cancel'),
    );
    if (!confirmed || !mounted) return;
    final done = await _guard((service) async {
      await service.delete(widget.owned);
      return true;
    });
    if (done == true && mounted) {
      ref.read(toastsProvider.notifier).show(context.t('sends.deleted'));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final owned = widget.owned;
    final send = owned.send;
    final meta = owned.meta;
    final text = _text;
    final usable = owned.readable && !_busy;
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: Icon(owned.isFile ? Icons.attach_file_rounded : Icons.notes_rounded),
        title: meta?.name ?? context.t('sends.status.unreadable'),
        actions: [
          FilledButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(context.t('sends.detail.close'))),
        ],
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusTag(label: context.t(_statusId(owned)), tone: !owned.readable ? StatusTone.danger : StatusTone.accent),
              Text(
                '${context.t(owned.isFile ? 'sends.kind.file' : 'sends.kind.text')} · ${context.t('sends.row.opens', {'count': send.accessCount, 'limit': send.maxAccess ?? 'none'})}',
                style: AppType.caption.copyWith(color: p.textSecondary),
              ),
            ],
          ),
          SheetText(context.t('sends.row.deletes', {'date': sendsDate(context, send.deletionAt)})),
          if (send.hasPassword) SheetText(context.t('sends.detail.password')),
          if (meta != null && meta.notes.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(context.t('sends.detail.notes'), style: AppType.caption.copyWith(color: p.textSecondary)),
                Text(meta.notes),
              ],
            ),
          if (text != null)
            SecretSelection(
              child: SelectableText(
                text,
                contextMenuBuilder: secretTextMenu,
                style: AppType.mono(fontSize: 14, color: p.text),
              ),
            ),
          if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
          if (_busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (usable)
                TextButton.icon(
                  onPressed: () => unawaited(_copy()),
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  label: Text(context.t('sends.detail.copy')),
                ),
              if (usable)
                TextButton.icon(
                  onPressed: () => unawaited(_share()),
                  icon: const Icon(Icons.ios_share_rounded, size: 20),
                  label: Text(context.t('sends.detail.share')),
                ),
              if (usable && !owned.isFile)
                TextButton.icon(
                  onPressed: () => unawaited(_toggleText()),
                  icon: Icon(text == null ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 20),
                  label: Text(context.t('sends.detail.view')),
                ),
              if (usable)
                TextButton.icon(
                  onPressed: () => unawaited(_edit()),
                  icon: const Icon(Icons.edit_rounded, size: 20),
                  label: Text(context.t('sends.detail.edit')),
                ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: p.error),
                onPressed: _busy ? null : () => unawaited(_delete()),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                label: Text(context.t('sends.detail.delete')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
