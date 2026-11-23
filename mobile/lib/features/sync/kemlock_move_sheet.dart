/// The screens of the move to Kemlock Server (move-off-vaultwarden-sync, tasks 7.1 and 7.2): the one before
/// anything is written, which says what moves and what stays; the progress by step with counts; and the result,
/// which says what moved, what happened to the old store and, for a sealed home, offers "Go back to
/// Vaultwarden" for 30 days.
///
/// The sheet is a view of [kemlockMoveProvider]: closing it never stops the move, which the provider holds, and
/// opening it again shows where the move stands. Nothing is written by the first screen; Not now closes it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/account/encoding.dart' show Owner;
import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import 'kemlock/km_models.dart';
import 'kemlock/km_move_back.dart';
import 'kemlock/km_move_devices.dart';
import 'kemlock/km_move_end.dart';
import 'kemlock/km_move_plan.dart';
import 'kemlock/km_move_record.dart';
import 'kemlock/km_move_server.dart';
import 'kemlock_copy.dart';
import 'kemlock_move.dart';
import 'removal_guard.dart';
import 'sync.dart';
import 'sync_merge.dart';
import 'sync_messages.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';
import 'vaultwarden/vw_sync.dart' show VwSyncError, VwSyncIssue;

/// What the first screen counts: the vault's own entries by kind, and the files its notes name. The owner only
/// decides the items' ids, so counting needs none of the account.
({Map<String, int> byKind, int files}) kmMovePreview(Lists own) {
  final plan = planKmMove(own, Owner.user('00000000-0000-4000-8000-000000000000'));
  return (byKind: plan.byKind, files: plan.files.length);
}

/// "3 notes", "40 codes": [count] entries of [kind], with the word in the app's language.
String moveKindText(BuildContext context, String kind, int count) =>
    context.t('kemlock.move.kind.$kind', {'n': count == 1 ? 'one' : 'other', 'count': count});

String _filesText(BuildContext context, int count) => context.t('kemlock.move.files', {'n': count == 1 ? 'one' : 'other', 'count': count});

/// What a move that stopped says: a move's own refusal, or the old store's or the server's problem.
String kmMoveProblemText(BuildContext context, Object error) => switch (error) {
  KmMoveError(:final issue, :final detail) => context.t('kemlock.move.problem.${issue.name}', {'note': detail == null ? '' : ' ($detail)'}),
  _ => problemText(context, problemOf(error)),
};

/// Opens the move's sheet for [target], the Kemlock Server the person just signed in to.
Future<void> showKemlockMoveSheet(BuildContext context, KemlockTarget target) => showAppBottomSheet<void>(
  context,
  label: context.t('kemlock.move.title'),
  builder: (context) => KemlockMoveSheet(target: target),
);

const _steps = [KmMoveStep.sync, KmMoveStep.copy, KmMoveStep.files, KmMoveStep.check, KmMoveStep.oldStore];

class KemlockMoveSheet extends ConsumerStatefulWidget {
  const KemlockMoveSheet({super.key, required this.target});

  final KemlockTarget target;

  @override
  ConsumerState<KemlockMoveSheet> createState() => _KemlockMoveSheetState();
}

class _KemlockMoveSheetState extends ConsumerState<KemlockMoveSheet> {
  var _confirmed = false;
  List<String>? _devices;

  @override
  void initState() {
    super.initState();
    unawaited(_readDevices());
  }

  /// The devices of the account that still use the Bitwarden API, by name. Not reaching the server says nothing.
  Future<void> _readDevices() async {
    try {
      final devices = await ref.read(kemlockDeviceListProvider)(widget.target);
      if (mounted) {
        setState(() => _devices = [for (final device in kmBitwardenDevices(devices, ref.read(clockProvider)())) device.name]);
      }
    } on Object {
      // The screen says what moves and what stays without them
    }
  }

  void _start() {
    setState(() => _confirmed = true);
    unawaited(ref.read(kemlockMoveProvider.notifier).start(widget.target));
  }

  @override
  Widget build(BuildContext context) {
    final move = ref.watch(kemlockMoveProvider);
    if (!_confirmed && !move.running && !move.unfinished) {
      return _before(context);
    }
    if (move.running || move.unfinished) {
      return _progress(context, move);
    }
    return SyncSheetFrame(
      icon: const Icon(Icons.check_circle_outline_rounded),
      title: context.t('kemlock.move.result.title'),
      actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.close')))],
      children: const [KemlockMoveResult()],
    );
  }

  Widget _before(BuildContext context) {
    final settings = ref.watch(syncProvider).settings;
    final source = settings == null ? null : kmMoveSourceOf(settings, widget.target);
    final preview = kmMovePreview(scopeLists(ref.watch(vaultControllerProvider.select((s) => s.lists)), null));
    final fate = switch ((source?.name, source?.mode)) {
      (vaultwardenSource, 'sealed') => 'kemlock.move.fate.sealed',
      (vaultwardenSource, _) => 'kemlock.move.fate.plain',
      (webdavSource, _) => 'kemlock.move.fate.webdav',
      _ => null,
    };
    final devices = _devices;
    return SyncSheetFrame(
      icon: const Icon(Icons.drive_file_move_outline),
      title: context.t('kemlock.move.title'),
      actions: [
        TextButton(
          style: inheritButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('kemlock.move.later')),
        ),
        FilledButton(onPressed: source == null ? null : _start, child: Text(context.t('kemlock.move.start'))),
      ],
      children: [
        SheetText(context.t('kemlock.move.body')),
        Text(context.t('kemlock.move.moves'), style: AppType.h6),
        if (preview.byKind.isEmpty && preview.files == 0)
          SheetText(context.t('kemlock.move.nothing'))
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              for (final MapEntry(:key, :value) in preview.byKind.entries) Text(moveKindText(context, key, value)),
              if (preview.files > 0) Text(_filesText(context, preview.files)),
            ],
          ),
        if (fate != null) SheetText(context.t(fate)),
        if (devices != null && devices.isNotEmpty)
          AppAlert(
            severity: AlertSeverity.warning,
            child: Text(
              [
                context.t('kemlock.move.devices', {'names': devices.join(', ')}),
                if (source?.mode == 'sealed' && source?.name == vaultwardenSource) context.t('kemlock.move.devices.stop'),
              ].join(' '),
            ),
          ),
      ],
    );
  }

  Widget _progress(BuildContext context, KmMoveState move) {
    final current = move.step ?? move.record?.step ?? KmMoveStep.sync;
    final index = _steps.indexOf(current);
    final error = move.error;
    return SyncSheetFrame(
      icon: const Icon(Icons.drive_file_move_outline),
      title: context.t('kemlock.move.progress.title'),
      actions: [
        if (error != null && !move.running)
          FilledButton(
            onPressed: () => unawaited(ref.read(kemlockMoveProvider.notifier).resume()),
            child: Text(context.t('kemlock.move.retry')),
          ),
        TextButton(
          style: inheritButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('export.close')),
        ),
      ],
      children: [
        for (var i = 0; i < _steps.length; i++)
          Row(
            spacing: 8,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: i < index
                    ? const Icon(Icons.check_rounded, size: 20)
                    : i == index && move.running
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: Text(
                  context.t('kemlock.move.step.${_steps[i].name}'),
                  style: AppType.body1.copyWith(fontWeight: i == index ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
              if (i == index && move.running && move.total > 1)
                Text(context.t('kemlock.move.step.count', {'done': move.done, 'total': move.total})),
            ],
          ),
        if (error != null) _error(context, error),
        SheetText(context.t('kemlock.move.progress.hint')),
      ],
    );
  }

  /// What stopped the move, and, for the removal guard's question, its two answers.
  Widget _error(BuildContext context, Object error) {
    final move = ref.read(kemlockMoveProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        AppAlert(severity: AlertSeverity.error, child: Text(kmMoveProblemText(context, error))),
        if (error is VwSyncError && error.issue == VwSyncIssue.removals) ...[
          SheetText(context.t('vaultwarden.removals.body', {'count': error.count})),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () => unawaited(move.resume(choice: RemovalChoice.keep)),
                child: Text(context.t('vaultwarden.removals.keep')),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: context.palette.error),
                onPressed: () => unawaited(move.resume(choice: RemovalChoice.remove)),
                child: Text(context.t('vaultwarden.removals.remove')),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// What a finished move left, in words: what moved by kind and files, what happened to the old store, what was
/// left, and, for a sealed home closed less than 30 days ago, "Go back to Vaultwarden". Shown by the sheet and
/// by Settings.
class KemlockMoveResult extends ConsumerStatefulWidget {
  const KemlockMoveResult({super.key});

  @override
  ConsumerState<KemlockMoveResult> createState() => _KemlockMoveResultState();
}

class _KemlockMoveResultState extends ConsumerState<KemlockMoveResult> {
  var _busy = false;
  var _failed = false;

  Future<void> _goBack() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await ref.read(kemlockMoveProvider.notifier).goBack();
    } on Object {
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(kemlockMoveProvider.select((s) => s.record));
    final result = record?.result;
    if (record == null || !record.isDone || result == null) {
      return const SizedBox.shrink();
    }
    final moved = result['moved'];
    final parts = [
      if (moved is Map<String, Object?>)
        for (final MapEntry(:key, :value) in moved.entries)
          if (value is int) moveKindText(context, key, value),
      if (result['files'] case final int files when files > 0) _filesText(context, files),
    ];
    final oldStore = result['oldStore'];
    final skipped = result['skipped'];
    final goBack = kmGoBackOffered(record, ref.read(clockProvider)());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (parts.isNotEmpty) Text(context.t('kemlock.move.result.moved', {'list': parts.join(', ')})),
        if (oldStore is String) SheetText(context.t('kemlock.move.result.$oldStore')),
        if (skipped is int && skipped > 0)
          SheetText(context.t('kemlock.move.result.skipped', {'n': skipped == 1 ? 'one' : 'other', 'count': skipped})),
        if (goBack) ...[
          SheetText(context.t('kemlock.move.back.body')),
          if (_failed) AppAlert(severity: AlertSeverity.error, child: Text(context.t('kemlock.move.back.failed'))),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(onPressed: _busy ? null : _goBack, child: Text(context.t('kemlock.move.back'))),
          ),
        ],
      ],
    );
  }
}
