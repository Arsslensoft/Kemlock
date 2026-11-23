import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/ids.dart';
import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/secure_note.dart';
import '../../platform/secret_selection.dart';
import '../../platform/security_keys.dart';
import '../../security_key/piv/piv_commands.dart';
import '../../security_key/piv/piv_data.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../security_key/piv/piv_session.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'piv_controller.dart';
import 'piv_key_prompt.dart';

/// Opens the management key sheet: what the key is, where Kemlock finds
/// it, and changing it to a random one kept in the vault (design
/// decisions 9 and 10).
Future<void> showPivManagementKeySheet(BuildContext context, PivController piv) => showAppBottomSheet<void>(
  context,
  label: context.t('piv.managementKey'),
  builder: (_) => PivManagementKeySheet(piv: piv),
);

/// The note that keeps [key], a management key of [type], for the
/// security key named [keyId] whose model is [model], set on [date]: in
/// the app's language at the time, as the person reads it, with the
/// `piv` object Kemlock finds it by.
SecureNote pivManagementKeyNote(
  Messages messages, {
  required String model,
  required String keyId,
  required PivManagementKeyType type,
  required List<int> key,
  required String date,
}) {
  final name = '$model ${keyId.length > 8 ? keyId.substring(0, 8) : keyId}';
  return SecureNote(
    id: newUuid(),
    title: messages.t('piv.note.title', {'name': name}),
    text: messages.t('piv.note.text', {'key': formatPivManagementKey(key), 'kind': pivKindName(type), 'date': date, 'name': name}),
    addedAt: 0,
    piv: NotePivKey(
      key: keyId,
      algorithm: type.noteName,
      managementKey: [for (final byte in key) byte.toRadixString(16).padLeft(2, '0')].join(),
    ),
  );
}

/// A management key's kind as people name it.
String pivKindName(PivManagementKeyType type) => switch (type) {
  PivManagementKeyType.tripleDes => 'Triple DES',
  PivManagementKeyType.aes128 => 'AES-128',
  PivManagementKeyType.aes192 => 'AES-192',
  PivManagementKeyType.aes256 => 'AES-256',
};

/// The vault could not save the note: nothing was changed on the key.
class _NotSaved implements Exception {
  const _NotSaved();
}

/// The key left while its new management key was being set. The note is
/// kept.
class _Dropped implements Exception {
  const _Dropped(this.note);

  final SecureNote? note;
}

/// The key refused the kind it was asked to take.
class _KindRefused implements Exception {
  const _KindRefused();
}

class PivManagementKeySheet extends ConsumerStatefulWidget {
  const PivManagementKeySheet({super.key, required this.piv});

  final PivController piv;

  @override
  ConsumerState<PivManagementKeySheet> createState() => _PivManagementKeySheetState();
}

class _PivManagementKeySheetState extends ConsumerState<PivManagementKeySheet> {
  bool _keep = true;
  bool _working = false;

  /// What the last change came to, said under the button.
  ({AlertSeverity severity, String text})? _outcome;

  PivController get _piv => widget.piv;

  String get _model => _piv.keys.key?.productName ?? context.t('securityKeys.model.unknown');

  String get _date => DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(ref.read(clockProvider)());

  void _say(AlertSeverity severity, String id, {Map<String, Object?> args = const {}, PivKeySource? used}) {
    if (!mounted) return;
    final text = [context.t(id, args), if (used != null) pivUsedText(context, used)].join(' ');
    setState(() => _outcome = (severity: severity, text: text));
  }

  void _sayError(Object error) {
    if (!mounted) return;
    final text = pivErrorText(context, error);
    if (text != null) setState(() => _outcome = (severity: AlertSeverity.error, text: text));
  }

  /// Sets [key] of [type] on the card of [session]: throws [_KindRefused]
  /// when the card does not take the kind, [_Dropped] when it left before
  /// answering, and the card's refusal otherwise.
  Future<void> _set(PivSession session, PivManagementKeyType type, List<int> key, {SecureNote? note}) async {
    try {
      await session.card.setManagementKey(type, key);
    } on PivRefused {
      throw const _KindRefused();
    } on SecurityKeyRemoved {
      throw _Dropped(note);
    } on SecurityKeyTimeout {
      throw _Dropped(note);
    }
  }

  /// Keeps the new key in the vault first, then sets it (design decision 10).
  Future<void> _changeKept() async {
    final notes = ref.read(pivNotesProvider);
    final messages = context.messages;
    final model = _model;
    final date = _date;
    setState(() {
      _working = true;
      _outcome = null;
    });
    try {
      final done = await runWithManagementKey(context, _piv, (session) async {
        final keyId = session.state.keyId ?? await pivEnsureCardId(session);
        SecureNote note(PivManagementKeyType type, List<int> key) =>
            pivManagementKeyNote(messages, model: model, keyId: keyId, type: type, key: key, date: date);

        var type = PivManagementKeyType.aes256;
        var key = newPivManagementKey(type);
        var kept = note(type, key);
        if (!await notes.add(kept)) throw const _NotSaved();
        try {
          await _set(session, type, key, note: kept);
        } on _KindRefused {
          // The strongest kind it takes: triple DES, with the note brought up to date first.
          type = PivManagementKeyType.tripleDes;
          key = newPivManagementKey(type);
          final updated = note(type, key).copyWith(id: kept.id);
          if (!await notes.update(updated)) {
            await notes.delete(kept);
            throw const _NotSaved();
          }
          kept = updated;
          try {
            await _set(session, type, key, note: kept);
          } on _KindRefused {
            await notes.delete(kept);
            throw const PivRefused(0x6a80);
          }
        } on PivError {
          await notes.delete(kept);
          rethrow;
        }
        return (type: type, note: kept);
      });
      if (done == null) return;
      _say(
        AlertSeverity.success,
        'piv.managementKey.changed.kept',
        args: {'kind': pivKindName(done.result.type), 'title': done.result.note.title},
        used: done.used,
      );
    } on _NotSaved {
      _say(AlertSeverity.error, 'piv.managementKey.notSaved');
    } on _Dropped {
      _say(AlertSeverity.warning, 'piv.managementKey.dropped');
    } on PivNotSupported {
      _say(AlertSeverity.error, 'piv.managementKey.cannot');
    } on SecurityKeyCancelled {
      // Nothing to say.
    } on PivError {
      _say(AlertSeverity.error, 'piv.managementKey.refused');
    } catch (error) {
      _sayError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Shows the new key to be written down, and sets it only once the
  /// person says they did. Nothing is stored.
  Future<void> _changeShown() async {
    setState(() => _outcome = null);
    var type = PivManagementKeyType.aes256;
    for (var again = false; ; again = true) {
      final key = newPivManagementKey(type);
      final wrote = await _showToWriteDown(type, key, again: again);
      if (wrote != true || !mounted) return;
      setState(() => _working = true);
      try {
        final done = await runWithManagementKey(context, _piv, (session) => _set(session, type, key));
        if (done == null) return;
        _say(AlertSeverity.success, 'piv.managementKey.changed.shown', args: {'kind': pivKindName(type)}, used: done.used);
        return;
      } on _KindRefused {
        if (type == PivManagementKeyType.tripleDes) {
          _say(AlertSeverity.error, 'piv.managementKey.refused');
          return;
        }
        type = PivManagementKeyType.tripleDes;
      } on _Dropped {
        _say(AlertSeverity.warning, 'piv.managementKey.dropped.shown');
        return;
      } on PivNotSupported {
        _say(AlertSeverity.error, 'piv.managementKey.cannot');
        return;
      } on SecurityKeyCancelled {
        return;
      } catch (error) {
        _sayError(error);
        return;
      } finally {
        if (mounted) setState(() => _working = false);
      }
    }
  }

  Future<bool?> _showToWriteDown(PivManagementKeyType type, List<int> key, {required bool again}) => showAppDialog<bool>(
    context,
    barrierDismissible: false,
    builder: (context) => AppDialog(
      semanticLabel: context.t('piv.managementKey.show.title'),
      heading: DialogHeading(
        icon: const Icon(Icons.edit_note_rounded),
        title: context.t('piv.managementKey.show.title'),
        tone: DialogTone.danger,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (again) ...[Text(context.t('piv.managementKey.show.tripleDes')), const SizedBox(height: 10)],
          // Selected and copied, the management key goes through the secret clipboard
          SecretSelection(
            child: SelectableText(
              formatPivManagementKey(key),
              style: AppType.mono(fontSize: 16, fontWeight: FontWeight.w500, color: context.palette.text),
              contextMenuBuilder: secretTextMenu,
            ),
          ),
          const SizedBox(height: 6),
          Text(pivKindName(type), style: AppType.caption.copyWith(color: context.palette.textSecondary)),
          const SizedBox(height: 12),
          Text(context.t('piv.managementKey.show.warning'), style: AppType.body2.copyWith(color: context.palette.textSecondary)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('export.cancel'))),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.t('piv.managementKey.show.wrote'))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _piv, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final p = context.palette;
    final state = _piv.state;
    final notes = ref.read(pivNotesProvider).notes;
    final note = state == null ? null : pivNoteFor(notes, state.keyId);
    final factory = state?.factoryManagementKey ?? false;
    final canChange = state?.makerCommands ?? false;
    final busy = _working || _piv.busy;
    final outcome = _outcome;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('piv.managementKey')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: _piv.keys),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(context.t('piv.managementKey.about'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                const SizedBox(height: 14),
                Group(
                  children: [
                    GroupRow(
                      first: true,
                      primary: context.t('piv.managementKey.now'),
                      secondary: note == null || factory ? null : note.title,
                      value: factory ? null : Text(context.t(note != null ? 'piv.managementKey.inVault' : 'piv.managementKey.changed')),
                      tag: factory ? StatusTag(label: context.t('piv.factoryDefault'), tone: StatusTone.danger) : null,
                    ),
                  ],
                ),
                if (factory) ...[
                  const SizedBox(height: 14),
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('piv.defaultWarning'))),
                ],
                if (!canChange) ...[
                  const SizedBox(height: 14),
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('piv.managementKey.cannot'))),
                ] else ...[
                  Group(
                    label: context.t('piv.managementKey.new'),
                    children: [
                      GroupRow(
                        first: true,
                        primary: context.t('piv.managementKey.keep'),
                        secondary: context.t(_keep ? 'piv.managementKey.keep.on' : 'piv.managementKey.keep.off'),
                        control: AppSwitch(value: _keep, onChanged: busy ? null : (value) => setState(() => _keep = value)),
                      ),
                    ],
                  ),
                  if (outcome != null) ...[const SizedBox(height: 14), AppAlert(severity: outcome.severity, child: Text(outcome.text))],
                  const SizedBox(height: 18),
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: busy ? null : () => unawaited(_keep ? _changeKept() : _changeShown()),
                    child: Text(context.t(_keep ? 'piv.changeManagementKey' : 'piv.managementKey.showInstead')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
