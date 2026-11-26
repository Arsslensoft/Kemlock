import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../models/backup_service.dart';
import '../../models/custom_field.dart';
import '../../models/json.dart';
import '../../platform/links.dart';
import '../../ui/ui.dart';
import '../accounts/service_tile.dart';
import '../fields/custom_fields_editor.dart';
import '../fields/custom_fields_view.dart';
import '../sync/kemlock/km_kinds.dart';
import '../sync/space_picker.dart';
import '../sync/sync_store.dart';
import 'backup_codes.dart';
import 'code_import_button.dart';
import 'two_factor_directory.dart';

/// A service's backup codes, `BackupServiceCard.tsx`: its name and how many
/// codes are left, a bar per code, and, when [open], the codes to tap off,
/// copying the next one, a note, adding codes, deleting the service, where
/// to get new codes and which space it is in.
class BackupServiceCard extends ConsumerStatefulWidget {
  const BackupServiceCard({
    super.key,
    required this.service,
    required this.open,
    required this.onToggle,
    required this.onUpdate,
    required this.onDelete,
    required this.onUseNext,
    this.index = 0,
  });

  final BackupService service;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<BackupService> onUpdate;
  final ValueChanged<String> onDelete;

  /// Copy the first unused code and mark it used.
  final ValueChanged<BackupService> onUseNext;

  /// The card's place in the list, which staggers its entrance.
  final int index;

  @override
  ConsumerState<BackupServiceCard> createState() => _BackupServiceCardState();
}

class _BackupServiceCardState extends ConsumerState<BackupServiceCard> {
  final _newCodes = TextEditingController();
  final _noteDraft = TextEditingController();
  bool _adding = false;
  bool _editingNote = false;
  bool _editingFields = false;

  /// The custom fields as the editor last gave them, while they are being edited.
  var _draftFields = <CustomField>[];

  BackupService get _service => widget.service;

  @override
  void dispose() {
    _newCodes.dispose();
    _noteDraft.dispose();
    super.dispose();
  }

  void _toggleCode(int index) {
    final now = ref.read(clockProvider)();
    widget.onUpdate(
      _service.copyWith(
        codes: [for (final (i, code) in _service.codes.indexed) i == index ? markCode(code, used: !code.used, now: now) : code],
      ),
    );
  }

  void _saveNote() {
    final note = _noteDraft.text.trim();
    widget.onUpdate(_service.copyWith(note: note.isEmpty ? unset : note));
    setState(() => _editingNote = false);
  }

  void _saveFields() {
    widget.onUpdate(_service.copyWith(fields: _draftFields));
    setState(() => _editingFields = false);
  }

  void _addCodes(List<String> fresh) {
    if (fresh.isNotEmpty) {
      widget.onUpdate(
        _service.copyWith(
          codes: [
            ..._service.codes,
            for (final code in fresh) BackupCode(code: code),
          ],
        ),
      );
    }
    _newCodes.clear();
    setState(() => _adding = false);
  }

  Future<void> _delete() async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_outline_rounded),
      title: context.t('backupCard.delete.title'),
      body: _DeleteBody(name: _service.serviceName, count: _service.codes.length),
      cancelLabel: context.t('backupCard.delete.cancel'),
      confirmLabel: context.t('backupCard.delete.confirm'),
    );
    if (confirmed) widget.onDelete(_service.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Where to get new codes or recover access, from the bundled 2fa.directory copy.
    final directory = widget.open ? ref.watch(twoFactorDirectoryProvider).value : null;
    final entry = directory?.findService(_service.serviceName);

    return Rise(
      delay: Duration(milliseconds: widget.index * 70 + 80),
      duration: const Duration(milliseconds: 550),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: _service.serviceName,
          child: Material(
            color: p.paper,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: p.divider),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                if (_service.codes.isNotEmpty) _bars(context),
                _Expand(
                  open: widget.open,
                  child: _body(context, entry: entry),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final total = _service.codes.length;
    final unused = _service.codes.where((code) => !code.used).length;
    final low = isLow(_service);
    final summary = total == 0
        ? context.t('backupCard.footer.none')
        : unused == 0
        ? context.t('backupCard.footer.allUsed')
        : context.t('backupCard.left', {'unused': unused, 'total': total});
    final reduced = Motion.reduced(context);

    return MergeSemantics(
      child: Semantics(
        button: true,
        expanded: widget.open,
        child: InkWell(
          onTap: widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                ServiceTile(name: _service.serviceName),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _service.serviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: fontSans,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.16,
                          color: p.text,
                        ),
                      ),
                      AnimatedDefaultTextStyle(
                        duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
                        style: TextStyle(fontFamily: fontSans, fontSize: 13, height: 1.4, color: low ? p.warning : p.textSecondary),
                        child: Text(summary),
                      ),
                    ],
                  ),
                ),
                if (low) ...[
                  const SizedBox(width: 8),
                  PopIn(
                    duration: const Duration(milliseconds: 400),
                    curve: Ease.css,
                    child: Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: b.warnSoft, borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        context.t('backupCard.low'),
                        style: TextStyle(fontFamily: fontSans, fontSize: 11.5, fontWeight: FontWeight.w600, height: 1, color: p.warning),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                ExcludeSemantics(
                  child: AnimatedRotation(
                    turns: widget.open ? 0.5 : 0,
                    duration: reduced ? Duration.zero : const Duration(milliseconds: 400),
                    curve: Ease.sheet,
                    child: Icon(Icons.expand_more_rounded, color: b.faint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A bar per code: used ones greyed, the rest Azure, or amber when running low.
  Widget _bars(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final low = isLow(_service);
    final reduced = Motion.reduced(context);
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Row(
          children: [
            for (final (i, code) in _service.codes.indexed) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: AnimatedContainer(
                  duration: reduced ? Duration.zero : const Duration(milliseconds: 350),
                  height: 4,
                  decoration: BoxDecoration(
                    color: code.used
                        ? b.line2
                        : low
                        ? p.warning
                        : b.accentText,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, {required DirectoryEntry? entry}) {
    final p = context.palette;
    final total = _service.codes.length;
    final note = _service.note;
    final docs = entry?.docs;
    final recovery = entry?.recovery;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isLow(_service))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: AppAlert(
                  severity: AlertSeverity.warning,
                  icon: const Icon(Icons.warning_amber_rounded, size: 20),
                  child: Text(context.t('backupCard.lowHint', {'name': _service.serviceName})),
                ),
              ),
            if (docs != null || recovery != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (docs != null) _DirectoryLink(url: docs, label: context.t('backupCard.directory.docs'), color: p.primary),
                    if (recovery != null) _DirectoryLink(url: recovery, label: context.t('backupCard.directory.recovery'), color: p.text),
                  ],
                ),
              ),
            if (_editingNote)
              _noteEditor(context)
            else if (note != null && note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(note, style: AppType.body2.copyWith(color: p.textSecondary)),
              ),
            if (total == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(context.t('backupCard.empty'), style: AppType.body2.copyWith(color: p.textSecondary)),
              )
            else
              Padding(padding: const EdgeInsets.only(top: 12), child: _codeGrid(context)),
            if (_editingFields) _fieldsEditor(context) else CustomFieldsView(fields: _service.fields),
            if (_adding) _addForm(context) else _actions(context),
            if (!_editingFields)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('fields-edit'),
                  onPressed: () => setState(() {
                    _draftFields = [..._service.fields];
                    _editingFields = true;
                  }),
                  icon: const Icon(Icons.list_alt_rounded, size: 18),
                  label: Text(context.t('fields.edit')),
                ),
              ),
            _SpaceRow(
              value: _service.spaceId,
              onChanged: (spaceId) => widget.onUpdate(_service.copyWith(spaceId: spaceId ?? unset)),
            ),
          ],
        ),
      ),
    );
  }

  /// The codes, two to a row, each row as tall as its tallest code.
  Widget _codeGrid(BuildContext context) {
    final codes = _service.codes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var row = 0; row < codes.length; row += 2) ...[
          if (row > 0) const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _codeTile(context, row)),
                const SizedBox(width: 8),
                Expanded(child: row + 1 < codes.length ? _codeTile(context, row + 1) : const SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _codeTile(BuildContext context, int index) {
    final p = context.palette;
    final b = context.bmc;
    final code = _service.codes[index];
    final locale = Localizations.localeOf(context).toLanguageTag();
    final usedAt = code.used && code.usedAt != null ? DateTime.fromMillisecondsSinceEpoch(code.usedAt!) : null;
    final tooltip = usedAt != null
        ? context.t('backupCard.tooltip.usedOn', {'date': DateFormat.yMMMd(locale).format(usedAt)})
        : context.t(code.used ? 'backupCard.tooltip.markUnused' : 'backupCard.tooltip.markUsed');
    final reduced = Motion.reduced(context);

    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          toggled: code.used,
          child: PressScale(
            child: Material(
              color: b.raised,
              borderRadius: BorderRadius.circular(13),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('code-$index'),
                onTap: () => _toggleCode(index),
                child: AnimatedOpacity(
                  opacity: code.used ? 0.55 : 1,
                  duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 46),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: _StruckCode(code: code.code, used: code.used),
                            ),
                          ),
                          if (usedAt != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              DateFormat.MMMd(locale).format(usedAt),
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(fontFamily: fontSans, fontSize: 11, color: b.faint),
                            ),
                          ] else if (code.used) ...[
                            const SizedBox(width: 8),
                            PopIn(
                              duration: const Duration(milliseconds: 400),
                              child: Icon(Icons.check_rounded, size: 15, color: p.textSecondary),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noteEditor(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _noteDraft,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: context.t('accountSheet.note'),
            hintText: context.t('backupCard.notePlaceholder'),
            hintMaxLines: 2,
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        _FormButtons(
          cancelLabel: context.t('backupCard.cancel'),
          onCancel: () => setState(() => _editingNote = false),
          confirmLabel: context.t('accountSheet.save'),
          onConfirm: _saveNote,
        ),
      ],
    ),
  );

  /// The custom fields' editor, with Cancel and Save under it as the note's has.
  Widget _fieldsEditor(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CustomFieldsEditor(
          key: const ValueKey('fields-editor'),
          kind: itemKindOf(_service),
          fields: _draftFields,
          onChanged: (next) => _draftFields = next,
        ),
        const SizedBox(height: 8),
        _FormButtons(
          cancelLabel: context.t('backupCard.cancel'),
          onCancel: () => setState(() => _editingFields = false),
          confirmLabel: context.t('accountSheet.save'),
          onConfirm: _saveFields,
        ),
      ],
    ),
  );

  Widget _addForm(BuildContext context) {
    final p = context.palette;
    final parsed = parseCodes(_newCodes.text);
    final existing = {for (final code in _service.codes) code.code};
    final fresh = [
      for (final code in parsed)
        if (!existing.contains(code)) code,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _newCodes,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            style: AppType.mono(fontSize: 13, color: p.text),
            decoration: InputDecoration(
              labelText: context.t('addBackup.field.codes'),
              hintText: context.t('backupCard.addPlaceholder'),
              hintMaxLines: 2,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          CodeImportButton(
            onCodes: (codes) {
              _newCodes.text = [_newCodes.text.trim(), ...codes].where((part) => part.isNotEmpty).join('\n');
              setState(() {});
            },
          ),
          if (_newCodes.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                context.t('backupCard.newCodesSummary', {'newCount': fresh.length, 'dupCount': parsed.length - fresh.length}),
                style: AppType.caption.copyWith(color: p.textSecondary),
              ),
            ),
          const SizedBox(height: 8),
          _FormButtons(
            cancelLabel: context.t('backupCard.cancel'),
            onCancel: () {
              _newCodes.clear();
              setState(() => _adding = false);
            },
            confirmLabel: context.t('backupCard.addCodes', {'count': fresh.length}),
            onConfirm: fresh.isEmpty ? null : () => _addCodes(fresh),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final unused = _service.codes.where((code) => !code.used).length;
    final hasNote = _service.note?.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: AnimatedOpacity(
              opacity: unused == 0 ? 0.5 : 1,
              duration: Motion.reduced(context) ? Duration.zero : Motion.colour,
              child: PressScale(
                enabled: unused > 0,
                child: TextButton.icon(
                  onPressed: unused == 0 ? null : () => widget.onUseNext(_service),
                  style: ButtonStyle(
                    backgroundColor: WidgetStatePropertyAll(b.accentSoft),
                    foregroundColor: WidgetStatePropertyAll(b.accentText),
                    iconColor: WidgetStatePropertyAll(b.accentText),
                  ),
                  icon: const Icon(Icons.content_copy_rounded, size: 18),
                  label: Text(context.t('backupCard.useNext'), maxLines: 1, softWrap: false, overflow: TextOverflow.fade),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SquareButton(
            icon: Icons.sticky_note_2_outlined,
            tooltip: context.t('backupCard.noteButton'),
            background: b.raised,
            foreground: hasNote ? b.accentText : p.text,
            onPressed: () {
              _noteDraft.text = _service.note ?? '';
              setState(() => _editingNote = true);
            },
          ),
          const SizedBox(width: 8),
          _SquareButton(
            icon: Icons.add_rounded,
            tooltip: context.t('backupCard.addButton'),
            background: b.raised,
            foreground: p.text,
            onPressed: () => setState(() => _adding = true),
          ),
          const SizedBox(width: 8),
          _SquareButton(
            icon: Icons.delete_outline_rounded,
            label: context.t('backupCard.tooltip.delete'),
            background: b.dangerSoft,
            foreground: p.error,
            onPressed: () => unawaited(_delete()),
          ),
        ],
      ),
    );
  }
}

/// Grows the card's body open and shut over .5s on [Ease.sheet], as the
/// web app's `grid-template-rows` did. Once shut, the body is gone, so
/// screen readers and taps skip it, as `visibility: hidden` had it.
class _Expand extends StatefulWidget {
  const _Expand({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<_Expand> createState() => _ExpandState();
}

class _ExpandState extends State<_Expand> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 500), value: widget.open ? 1 : 0);
  late final _size = CurvedAnimation(parent: _controller, curve: Ease.sheet, reverseCurve: Ease.sheet.flipped);

  @override
  void didUpdateWidget(_Expand old) {
    super.didUpdateWidget(old);
    if (widget.open == old.open) return;
    if (Motion.reduced(context)) {
      _controller.value = widget.open ? 1 : 0;
    } else {
      unawaited(widget.open ? _controller.forward() : _controller.reverse());
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) => _controller.isDismissed
        ? const SizedBox(width: double.infinity)
        : ClipRect(
            child: SizeTransition(sizeFactor: _size, alignment: Alignment.topCenter, child: child),
          ),
    child: widget.child,
  );
}

/// A code, struck through from the left once it's used.
class _StruckCode extends StatelessWidget {
  const _StruckCode({required this.code, required this.used});

  final String code;
  final bool used;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final reduced = Motion.reduced(context);
    final color = used ? b.faint : p.text;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: used ? 1 : 0),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 400),
      curve: Ease.out,
      builder: (context, progress, child) => CustomPaint(
        foregroundPainter: _StrikePainter(progress: progress, color: color),
        child: child,
      ),
      child: AnimatedDefaultTextStyle(
        duration: reduced ? Duration.zero : const Duration(milliseconds: 300),
        style: AppType.mono(fontSize: 13.5, color: color).copyWith(letterSpacing: 0.27, height: 1.35),
        child: Text(code),
      ),
    );
  }
}

/// The 1.5px line through a used code, 3px past each end, drawn [progress] of the way.
class _StrikePainter extends CustomPainter {
  const _StrikePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final width = (size.width + 6) * progress;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(-3, size.height * 0.52 - 0.75, width, 1.5), const Radius.circular(1)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_StrikePainter old) => old.progress != progress || old.color != color;
}

/// A 44px rounded-square icon button of the card's action row, named by
/// its [tooltip] or, without one, by [label].
class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.icon,
    this.tooltip,
    this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final IconData icon;
  final String? tooltip;
  final String? label;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => PressScale(
    scale: 0.94,
    child: IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        fixedSize: const Size.square(44),
        minimumSize: const Size.square(44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Icon(icon, size: 20, semanticLabel: tooltip == null ? label : null),
    ),
  );
}

/// Cancel and the confirming button, at the right, under a form in the card.
class _FormButtons extends StatelessWidget {
  const _FormButtons({required this.cancelLabel, required this.onCancel, required this.confirmLabel, required this.onConfirm});

  final String cancelLabel;
  final VoidCallback onCancel;
  final String confirmLabel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    spacing: 8,
    runSpacing: 8,
    children: [
      TextButton(
        style: TextButton.styleFrom(foregroundColor: context.palette.text),
        onPressed: onCancel,
        child: Text(cancelLabel),
      ),
      FilledButton(onPressed: onConfirm, child: Text(confirmLabel)),
    ],
  );
}

/// A link of the 2FA directory, opened in the browser.
class _DirectoryLink extends ConsumerWidget {
  const _DirectoryLink({required this.url, required this.label, required this.color});

  final String url;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MergeSemantics(
    child: Semantics(
      link: true,
      linkUrl: Uri.tryParse(url),
      child: TextButton.icon(
        style: smallButtonStyle.merge(TextButton.styleFrom(foregroundColor: color, iconColor: color)),
        onPressed: () => unawaited(ref.read(linkOpenerProvider).open(context, Uri.parse(url))),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        iconAlignment: IconAlignment.end,
        label: Text(label),
      ),
    ),
  );
}

/// The space the service lives in. The picker shows only when there's a
/// space to pick or the service is in one, and so does its gap.
class _SpaceRow extends ConsumerWidget {
  const _SpaceRow({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSpaces = ref.watch(syncProvider.select((sync) => sync.settings?.spaces.isNotEmpty ?? false));
    if (!hasSpaces && (value == null || value!.isEmpty)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SpacePicker(small: true, value: value, onChanged: onChanged),
    );
  }
}

/// "Remove **GitHub** and all 4 backup codes? This cannot be undone.", with the name in bold.
class _DeleteBody extends StatelessWidget {
  const _DeleteBody({required this.name, required this.count});

  final String name;
  final int count;

  /// Stands in for the name while the message is formatted, to find where it goes.
  static const _marker = '\u{E000}';

  @override
  Widget build(BuildContext context) {
    final parts = context.t('backupCard.delete.body', {'name': _marker, 'count': count}).split(_marker);
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, part) in parts.indexed) ...[
            if (i > 0)
              TextSpan(
                text: name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            TextSpan(text: part),
          ],
        ],
      ),
    );
  }
}
