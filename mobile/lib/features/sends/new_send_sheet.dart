/// The New Send sheet (`docs/plans/add-sends.md`, design 4 and tasks 5.2 and 9): a text or a file, the name the
/// recipient sees, notes only the owner sees, when it is deleted, whether the link stops earlier, how many times it may
/// be opened, an optional password and "Hide my email". It makes the Send, then shows its link.
///
/// What a Send can't be made of or from is said on the sheet: offline mode, no Kemlock Server sync, and a phone on a
/// replica, which the home server's Sends can't be made through. A file over 50 MB is refused before anything is
/// sealed, an expiry after the deletion isn't offered, and a server's refusal (a policy, a smaller file limit) is shown
/// in its own words. Everything typed is emptied when the sheet closes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/network.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../lock/gate_widgets.dart';
import '../notes/note_files.dart' show fileSizeText;
import '../settings/offline_alert.dart';
import '../sync/sync_sheet_frame.dart';
import '../sync/sync_store.dart';
import 'send_link_sheet.dart';
import 'sends_providers.dart';
import 'sends_service.dart';
import 'sends_support.dart';

/// Opens the New Send sheet. With [text] (and the item's [name]) it starts a text Send from an item of the vault: the
/// Send is a copy, and isn't linked to the item.
Future<void> showNewSendSheet(BuildContext context, {String? text, String? name}) => showAppBottomSheet<void>(
  context,
  label: context.t('sends.new.title'),
  builder: (_) => NewSendSheet(text: text, name: name),
);

/// The sheet that makes a Send.
class NewSendSheet extends ConsumerStatefulWidget {
  const NewSendSheet({super.key, this.text, this.name});

  /// A text to start from, for a Send made from an item.
  final String? text;
  final String? name;

  @override
  ConsumerState<NewSendSheet> createState() => _NewSendSheetState();
}

class _NewSendSheetState extends ConsumerState<NewSendSheet> {
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _text = TextEditingController(text: widget.text ?? '');
  final _notes = TextEditingController();
  final _password = TextEditingController();
  final _opens = TextEditingController(text: '1');

  var _file = false;
  PickedFile? _picked;
  var _deleteDays = 7;
  int? _expiryDays;
  var _limitOpens = false;
  var _hideEmail = false;
  var _showPassword = false;
  var _busy = false;
  String? _error;
  MadeSend? _made;

  List<TextEditingController> get _fields => [_name, _text, _notes, _password, _opens];

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      field.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    // What was typed (a secret, a password) doesn't stay in a controller. The listeners go first, so emptying a
    // field runs no setState on an element that is going away.
    for (final field in _fields) {
      field.removeListener(_changed);
      field.clear();
      field.dispose();
    }
    _picked = null;
    super.dispose();
  }

  int? get _opensNumber => int.tryParse(_opens.text.trim());

  bool get _opensOk => !_limitOpens || (_opensNumber != null && _opensNumber! >= 1);

  /// The days the link may stop working after: those before the deletion.
  List<int> get _expiryChoices => [
    for (final days in sendDeleteDayChoices)
      if (days < _deleteDays) days,
  ];

  bool get _complete => _file ? _picked != null : _name.text.trim().isNotEmpty && _text.text.isNotEmpty;

  Future<void> _pick() async {
    PickedFile? picked;
    try {
      picked = await ref.read(fileServiceProvider).pickFile();
    } on Object {
      picked = null;
    }
    if (picked == null || !mounted) return;
    if (picked.bytes.length > sendFileLimit) {
      setState(() => _error = context.t('sends.file.tooBig', {'limit': fileSizeText(context, sendFileLimit)}));
      return;
    }
    setState(() {
      _picked = picked;
      _error = null;
    });
  }

  Future<void> _make() async {
    final service = ref.read(sendsServiceProvider);
    if (service == null || _busy) return;
    final now = ref.read(clockProvider)();
    final expiry = _expiryDays;
    final password = _password.text;
    final picked = _picked;
    final NewSend input;
    if (_file) {
      if (picked == null) return;
      input = NewSend.file(
        name: picked.name,
        bytes: picked.bytes,
        mime: picked.mimeType ?? 'application/octet-stream',
        notes: _notes.text,
        deleteInDays: _deleteDays,
        expiresAt: expiry == null ? null : now.add(Duration(days: expiry)),
        maxAccess: _limitOpens ? _opensNumber : null,
        password: password,
        hideEmail: _hideEmail,
      );
    } else {
      input = NewSend.text(
        name: _name.text.trim(),
        text: _text.text,
        notes: _notes.text,
        deleteInDays: _deleteDays,
        expiresAt: expiry == null ? null : now.add(Duration(days: expiry)),
        maxAccess: _limitOpens ? _opensNumber : null,
        password: password,
        hideEmail: _hideEmail,
      );
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await service.make(input);
      if (mounted) setState(() => _made = made);
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
    final made = _made;
    if (made != null) return SendLinkSheet(link: made.link);
    final p = context.palette;
    final offline = ref.watch(offlineProvider);
    final away = ref.watch(kemlockAwayProvider);
    final service = ref.watch(sendsServiceProvider);
    final blocked = offline || away != null || service == null;
    final hasPassword = _password.text.isNotEmpty;
    final canMake = !blocked && !_busy && _complete && _opensOk;
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: const Icon(Icons.send_rounded),
        title: context.t('sends.new.title'),
        actions: [
          TextButton(
            style: inheritButtonStyle(context),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(context.t('changePw.cancel')),
          ),
          FilledButton(onPressed: canMake ? () => unawaited(_make()) : null, child: Text(context.t('sends.make'))),
        ],
        children: [
          if (offline) OfflineAlert(context.t('sends.offline')),
          if (!offline && service == null) AppAlert(severity: AlertSeverity.info, child: Text(context.t('sends.noSync'))),
          if (!offline && away != null)
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('sends.away', {'time': sendsTime(context, away.since)}))),
          if (widget.text != null) SheetText(context.t('sends.fromItem.copy')),
          SegmentedControl<bool>(
            options: [
              SegmentOption(value: false, label: context.t('sends.new.text'), icon: const Icon(Icons.notes_rounded)),
              SegmentOption(value: true, label: context.t('sends.new.file'), icon: const Icon(Icons.attach_file_rounded)),
            ],
            value: _file,
            onChanged: _busy ? (_) {} : (file) => setState(() => _file = file),
            semanticLabel: context.t('sends.new.what'),
          ),
          if (_file)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                if (_picked case final picked?)
                  Text(
                    context.t('sends.file.chosen', {'name': picked.name, 'size': fileSizeText(context, picked.bytes.length)}),
                    style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => unawaited(_pick()),
                  icon: const Icon(Icons.folder_open_rounded, size: 20),
                  label: Text(context.t(_picked == null ? 'sends.file.choose' : 'sends.file.change')),
                ),
              ],
            )
          else ...[
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _name,
              enabled: !_busy,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: context.t('sends.field.name'), helperText: context.t('sends.field.name.hint')),
            ),
            SecretSelection(
              child: TextField(
                enableIMEPersonalizedLearning: false,
                controller: _text,
                enabled: !_busy,
                minLines: 3,
                maxLines: 8,
                autocorrect: false,
                enableSuggestions: false,
                contextMenuBuilder: secretTextMenu,
                decoration: InputDecoration(labelText: context.t('sends.field.text'), alignLabelWithHint: true),
              ),
            ),
          ],
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _notes,
            enabled: !_busy,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: context.t('sends.field.notes'), helperText: context.t('sends.field.notes.hint')),
          ),
          _chips(context.t('sends.deletes'), [
            for (final days in sendDeleteDayChoices)
              ChoiceChip(
                label: Text(sendsDays(context, days)),
                selected: _deleteDays == days,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _deleteDays = days;
                        // An expiry after the deletion isn't offered
                        if (_expiryDays != null && _expiryDays! >= days) _expiryDays = null;
                      }),
              ),
          ]),
          _chips(context.t('sends.expires'), [
            ChoiceChip(
              label: Text(context.t('sends.expires.never')),
              selected: _expiryDays == null,
              onSelected: _busy ? null : (_) => setState(() => _expiryDays = null),
            ),
            for (final days in _expiryChoices)
              ChoiceChip(
                label: Text(sendsDays(context, days)),
                selected: _expiryDays == days,
                onSelected: _busy ? null : (_) => setState(() => _expiryDays = days),
              ),
          ]),
          GroupRow(
            first: true,
            primary: context.t('sends.opens.limit'),
            control: AppSwitch(value: _limitOpens, onChanged: _busy ? null : (on) => setState(() => _limitOpens = on)),
          ),
          if (_limitOpens)
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _opens,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
              decoration: InputDecoration(
                labelText: context.t('sends.opens.count'),
                errorText: _opensOk ? null : context.t('sends.error.maxAccess', {'min': 1}),
              ),
            ),
          SecretSelection(
            child: TextField(
              enableIMEPersonalizedLearning: false,
              controller: _password,
              enabled: !_busy,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: null,
              contextMenuBuilder: secretTextMenu,
              decoration: InputDecoration(
                labelText: context.t('sends.password'),
                helperText: context.t('sends.password.hint'),
                helperMaxLines: 3,
                suffixIcon: RevealPasswordButton(shown: _showPassword, onPressed: () => setState(() => _showPassword = !_showPassword)),
              ),
            ),
          ),
          GroupRow(
            first: true,
            primary: context.t('sends.hideEmail'),
            secondary: context.t('sends.hideEmail.hint'),
            control: AppSwitch(value: _hideEmail, onChanged: _busy ? null : (on) => setState(() => _hideEmail = on)),
          ),
          if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
          if (_busy)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                const LinearProgressIndicator(),
                Text(context.t(hasPassword ? 'sends.deriving' : 'sends.making'), style: AppType.caption.copyWith(color: p.textSecondary)),
              ],
            ),
        ],
      ),
    );
  }
}
