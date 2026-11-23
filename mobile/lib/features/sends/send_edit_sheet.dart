/// Editing a Send of the owner's list (`docs/plans/add-sends.md`, design 5 and task 6.2): the name, notes and text of a
/// text Send, when it is deleted, when the link stops, the open limit (never below the opens used), the password (kept,
/// changed or removed), "Hide my email" and an on/off switch. The server replaces every option, so [SendsService.update]
/// sends them all again; the key, the file and the open count never change, so the link stays the same.
///
/// A file Send's file and name can't change, and the sheet says to make a new Send.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../lock/gate_widgets.dart';
import '../sync/sync_sheet_frame.dart';
import 'sends_providers.dart';
import 'sends_service.dart';
import 'sends_support.dart';

/// Opens the edit sheet of [owned]; true once it was saved.
Future<bool?> showSendEditSheet(BuildContext context, OwnedSend owned) => showAppBottomSheet<bool>(
  context,
  label: context.t('sends.edit.title'),
  builder: (_) => SendEditSheet(owned: owned),
);

enum _Password { keep, change, remove }

enum _Expiry { never, keep, days }

/// The edit sheet.
class SendEditSheet extends ConsumerStatefulWidget {
  const SendEditSheet({super.key, required this.owned});

  final OwnedSend owned;

  @override
  ConsumerState<SendEditSheet> createState() => _SendEditSheetState();
}

class _SendEditSheetState extends ConsumerState<SendEditSheet> {
  late final _name = TextEditingController(text: widget.owned.meta?.name ?? '');
  late final _notes = TextEditingController(text: widget.owned.meta?.notes ?? '');
  final _text = TextEditingController();
  final _password = TextEditingController();
  late final _opens = TextEditingController(text: '${widget.owned.send.maxAccess ?? _floor}');

  /// The least the open limit may be: the opens used, and 1.
  late final int _floor = widget.owned.send.accessCount < 1 ? 1 : widget.owned.send.accessCount;

  /// The text of a text Send, read from the Send; null until it is.
  String? _loadedText;
  var _loading = false;
  var _keepDeletion = true;
  int _deleteDays = 7;
  late var _expiry = widget.owned.send.expiresAt == null ? _Expiry.never : _Expiry.keep;
  int _expiryDays = 1;
  late var _limitOpens = widget.owned.send.maxAccess != null;
  late var _hideEmail = widget.owned.send.hideEmail;
  late var _on = !widget.owned.send.disabled;
  late var _passwordMode = _Password.keep;
  var _showPassword = false;
  var _busy = false;
  String? _error;

  List<TextEditingController> get _fields => [_name, _notes, _text, _password, _opens];

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      field.addListener(_changed);
    }
    if (!widget.owned.isFile) unawaited(_load());
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    // The listeners go first, so emptying a field runs no setState on an element that is going away
    for (final field in _fields) {
      field.removeListener(_changed);
      field.clear();
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final service = ref.read(sendsServiceProvider);
    if (service == null) return;
    setState(() => _loading = true);
    try {
      final payload = await service.view(widget.owned);
      if (!mounted) return;
      _loadedText = payload.text;
      _text.text = payload.text ?? '';
    } on Object catch (e) {
      if (mounted) setState(() => _error = sendsErrorText(context, e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DateTime get _now => ref.read(clockProvider)();

  DateTime get _deletionAt => _keepDeletion ? widget.owned.send.deletionAt : _now.add(Duration(days: _deleteDays));

  /// The days the link may stop working after: those before the deletion.
  List<int> get _expiryChoices => [
    for (final days in sendDeleteDayChoices)
      if (_now.add(Duration(days: days)).isBefore(_deletionAt)) days,
  ];

  DateTime? get _expiresAt => switch (_expiry) {
    _Expiry.never => null,
    _Expiry.keep => widget.owned.send.expiresAt,
    _Expiry.days => _now.add(Duration(days: _expiryDays)),
  };

  int? get _opensNumber => int.tryParse(_opens.text.trim());

  bool get _opensOk => !_limitOpens || (_opensNumber != null && _opensNumber! >= _floor);

  bool get _passwordOk => _passwordMode != _Password.change || _password.text.isNotEmpty;

  bool get _valid {
    final text = widget.owned.isFile ? true : _loadedText != null && _text.text.isNotEmpty;
    return (widget.owned.isFile || _name.text.trim().isNotEmpty) && text && _opensOk && _passwordOk && !_loading;
  }

  Future<void> _save() async {
    final service = ref.read(sendsServiceProvider);
    if (service == null || _busy) return;
    final expiresAt = _expiresAt;
    final deletionAt = _deletionAt;
    // A kept expiry that is after a new deletion isn't offered; a stale one stops here rather than at the server
    final edit = SendEdit(
      name: widget.owned.isFile ? (widget.owned.meta?.name ?? '') : _name.text.trim(),
      notes: _notes.text,
      text: widget.owned.isFile ? null : _text.text,
      deletionAt: deletionAt,
      expiresAt: expiresAt,
      maxAccess: _limitOpens ? _opensNumber : null,
      hideEmail: _hideEmail,
      disabled: !_on,
      newPassword: _passwordMode == _Password.change || (!widget.owned.send.hasPassword && _password.text.isNotEmpty)
          ? _password.text
          : null,
      removePassword: _passwordMode == _Password.remove,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.update(widget.owned, edit);
      if (!mounted) return;
      ref.read(toastsProvider.notifier).show(context.t('sends.edit.saved'));
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = sendsErrorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _chips(String label, List<Widget> chips) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 6,
    children: [
      Text(
        label,
        style: AppType.body2.copyWith(color: context.palette.textSecondary, fontWeight: FontWeight.w600),
      ),
      Wrap(spacing: 8, runSpacing: 4, children: chips),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final send = widget.owned.send;
    final readable = widget.owned.readable;
    final service = ref.watch(sendsServiceProvider);
    final editing = !_busy && readable;
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: const Icon(Icons.edit_rounded),
        title: context.t('sends.edit.title'),
        actions: [
          TextButton(
            style: inheritButtonStyle(context),
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: Text(context.t('changePw.cancel')),
          ),
          FilledButton(
            onPressed: service != null && editing && _valid ? () => unawaited(_save()) : null,
            child: Text(context.t('sends.edit.save')),
          ),
        ],
        children: [
          if (widget.owned.isFile) SheetText(context.t('sends.edit.fileNote')),
          if (!widget.owned.isFile) ...[
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _name,
              enabled: editing,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: context.t('sends.field.name'), helperText: context.t('sends.field.name.hint')),
            ),
            SecretSelection(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: _text,
                enabled: editing && !_loading,
                minLines: 3,
                maxLines: 8,
                autocorrect: false,
                enableSuggestions: false,
                contextMenuBuilder: secretTextMenu,
                decoration: InputDecoration(labelText: context.t('sends.field.text'), alignLabelWithHint: true),
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
          ],
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _notes,
            enabled: editing,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: context.t('sends.field.notes'), helperText: context.t('sends.field.notes.hint')),
          ),
          _chips(context.t('sends.deletes'), [
            ChoiceChip(
              label: Text(context.t('sends.edit.keepDate', {'date': sendsDate(context, send.deletionAt)})),
              selected: _keepDeletion,
              onSelected: editing ? (_) => setState(() => _keepDeletion = true) : null,
            ),
            for (final days in sendDeleteDayChoices)
              ChoiceChip(
                label: Text(sendsDays(context, days)),
                selected: !_keepDeletion && _deleteDays == days,
                onSelected: editing
                    ? (_) => setState(() {
                        _keepDeletion = false;
                        _deleteDays = days;
                        // An expiry after the deletion isn't offered
                        final expiry = _expiresAt;
                        if (expiry != null && expiry.isAfter(_deletionAt)) _expiry = _Expiry.never;
                      })
                    : null,
              ),
          ]),
          _chips(context.t('sends.expires'), [
            ChoiceChip(
              label: Text(context.t('sends.expires.never')),
              selected: _expiry == _Expiry.never,
              onSelected: editing ? (_) => setState(() => _expiry = _Expiry.never) : null,
            ),
            if (send.expiresAt case final kept? when !kept.isAfter(_deletionAt))
              ChoiceChip(
                label: Text(context.t('sends.edit.keepDate', {'date': sendsDate(context, kept)})),
                selected: _expiry == _Expiry.keep,
                onSelected: editing ? (_) => setState(() => _expiry = _Expiry.keep) : null,
              ),
            for (final days in _expiryChoices)
              ChoiceChip(
                label: Text(sendsDays(context, days)),
                selected: _expiry == _Expiry.days && _expiryDays == days,
                onSelected: editing
                    ? (_) => setState(() {
                        _expiry = _Expiry.days;
                        _expiryDays = days;
                      })
                    : null,
              ),
          ]),
          GroupRow(
            first: true,
            primary: context.t('sends.opens.limit'),
            secondary: context.t('sends.edit.opens.min', {'count': send.accessCount}),
            control: AppSwitch(value: _limitOpens, onChanged: editing ? (on) => setState(() => _limitOpens = on) : null),
          ),
          if (_limitOpens)
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _opens,
              enabled: editing,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
              decoration: InputDecoration(
                labelText: context.t('sends.opens.count'),
                errorText: _opensOk ? null : context.t('sends.error.maxAccess', {'min': _floor}),
              ),
            ),
          if (send.hasPassword)
            SegmentedControl<_Password>(
              options: [
                SegmentOption(value: _Password.keep, label: context.t('sends.edit.password.keep')),
                SegmentOption(value: _Password.change, label: context.t('sends.edit.password.change')),
                SegmentOption(value: _Password.remove, label: context.t('sends.edit.password.remove')),
              ],
              value: _passwordMode,
              onChanged: editing ? (mode) => setState(() => _passwordMode = mode) : (_) {},
              semanticLabel: context.t('sends.password'),
              size: SegmentSize.small,
            ),
          if (!send.hasPassword || _passwordMode == _Password.change)
            SecretSelection(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: _password,
                enabled: editing,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: null,
                contextMenuBuilder: secretTextMenu,
                decoration: InputDecoration(
                  labelText: context.t(send.hasPassword ? 'sends.edit.password.new' : 'sends.password'),
                  helperText: send.hasPassword ? null : context.t('sends.password.hint'),
                  helperMaxLines: 3,
                  suffixIcon: RevealPasswordButton(shown: _showPassword, onPressed: () => setState(() => _showPassword = !_showPassword)),
                ),
              ),
            ),
          GroupRow(
            first: true,
            primary: context.t('sends.hideEmail'),
            secondary: context.t('sends.hideEmail.hint'),
            control: AppSwitch(value: _hideEmail, onChanged: editing ? (on) => setState(() => _hideEmail = on) : null),
          ),
          GroupRow(
            first: true,
            primary: context.t('sends.edit.on'),
            secondary: context.t('sends.edit.on.hint'),
            control: AppSwitch(value: _on, onChanged: editing ? (on) => setState(() => _on = on) : null),
          ),
          if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
          if (_busy)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                const LinearProgressIndicator(),
                Text(
                  context.t(_password.text.isNotEmpty ? 'sends.deriving' : 'sends.making'),
                  style: AppType.caption.copyWith(color: p.textSecondary),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
