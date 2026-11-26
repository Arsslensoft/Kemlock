import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/custom_field.dart';
import '../../models/json.dart' show keep, unset;
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../lock/gate_widgets.dart';
import '../settings/prefs.dart';
import '../sync/kemlock/km_custom_fields.dart';
import '../sync/kemlock/km_kinds.dart';
import '../vault/owner_check.dart';
import 'custom_fields_provider.dart';

/// The message id of the word for a field's [kind]: what the person picks for a field of their own.
String fieldKindId(String kind) => switch (kind) {
  CustomFieldKind.hidden => 'fields.kind.hidden',
  CustomFieldKind.boolean => 'fields.kind.boolean',
  _ => 'fields.kind.text',
};

/// The kind of item an admin's definition names for an item of [kind] (`itemKindOf`): an on-key code is a code (`otp`), as the server
/// knows it. Any other kind that the definitions don't list (a plain `key`) is offered the definitions that name every kind only.
String _definitionKind(String kind) => kind == KmKind.keyOtp ? KmKind.otp : kind;

/// A new field of the person's own: no name yet, which is left out until it has one.
const _ownField = CustomField(name: '', value: '', kind: CustomFieldKind.text);

/// The kinds the person may pick for a field of their own, in the order they are offered.
const _pickable = [CustomFieldKind.text, CustomFieldKind.hidden, CustomFieldKind.boolean];

/// One row of the editor: the field as it is now, the controllers of its two texts, and the key that follows it as
/// the list changes.
class _Row {
  _Row(this.field) : original = field;

  final Key key = UniqueKey();
  CustomField field;

  /// What the field held when the sheet opened: showing it again asks who the person is, when Settings says so.
  final CustomField original;
  TextEditingController? _name;
  TextEditingController? _value;

  TextEditingController get name => _name ??= TextEditingController(text: field.name);
  TextEditingController get value => _value ??= TextEditingController(text: field.value);

  var shown = false;

  /// Whether the value may still hold what was saved, or some of it: until it is emptied, so one keystroke on a saved hidden value
  /// does not make the rest of it show without the owner check. Typing into a value that was empty needs none.
  late var holdsSaved = original.value.isNotEmpty;

  void dispose() {
    _name?.dispose();
    _value?.dispose();
  }
}

/// The custom fields of an item, for the sheet that edits or adds it (`crypto.md`, "`fields`: custom fields"): a card
/// of rows, each with a name and a value whose control follows its kind (text, hidden with the eye in the field, or a
/// checkbox), and "Add a field" at the end.
///
/// The person can add a field of their own, unless the admin turned that off, or one the admin offers for this kind of
/// item, which has the admin's name and kind and takes only the value. Rows can be renamed, moved and removed. Nothing
/// is required: a field with no name is left out when the item is written.
///
/// [fields] is the list the item holds. The entries this version can't edit (a `linked` field, one with no name)
/// are not shown; they keep their place in the list [onChanged] gets, and so does every entry nobody edited, the very
/// same [CustomField]: only the one the person changes is replaced, through `copyWith`. The editor keeps the list it
/// edits, so it is read at the start only; [onChanged] gets the whole list after each change.
class CustomFieldsEditor extends ConsumerStatefulWidget {
  const CustomFieldsEditor({super.key, required this.kind, required this.fields, required this.onChanged});

  /// The kind of the item (`itemKindOf(entry)`), which decides which admin fields are offered.
  final String kind;
  final List<CustomField> fields;
  final ValueChanged<List<CustomField>> onChanged;

  @override
  ConsumerState<CustomFieldsEditor> createState() => _CustomFieldsEditorState();
}

class _CustomFieldsEditorState extends ConsumerState<CustomFieldsEditor> {
  late final List<_Row> _rows = [for (final field in widget.fields) _Row(field)];

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _emit() => widget.onChanged([for (final row in _rows) row.field]);

  /// The row with [row] replaced by [field], and the parent told.
  void _set(_Row row, CustomField field) {
    setState(() => row.field = field);
    _emit();
  }

  void _add(CustomField field) {
    setState(() => _rows.add(_Row(field)));
    _emit();
  }

  void _remove(_Row row) {
    setState(() => _rows.remove(row));
    // Disposed once the row has left the tree, which still listens to it until then
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
    _emit();
  }

  /// Swaps [row] with the nearest field a person can edit above (-1) or below (+1): what can't be edited stays where it
  /// was in the list.
  void _move(_Row row, int direction) {
    final from = _rows.indexOf(row);
    var to = from + direction;
    while (to >= 0 && to < _rows.length && !_rows[to].field.isEditable) {
      to += direction;
    }
    if (to < 0 || to >= _rows.length) {
      return;
    }
    setState(() {
      final other = _rows[to];
      _rows[to] = row;
      _rows[from] = other;
    });
    _emit();
  }

  /// Renaming a field makes it the person's own, which an admin's field with a name the admin chose is not.
  void _rename(_Row row, String text) => _set(row, row.field.copyWith(name: text, adminField: _ownOrAdmin(row)));

  /// What [CustomField.copyWith] gets as `adminField` when the person changes the name or the kind of [row]'s field: the field is
  /// then their own, so the link to the admin's definition is cleared; nothing changes for a field that has none.
  Object _ownOrAdmin(_Row row) => row.field.adminField == null ? keep : unset;

  void _write(_Row row, String text) {
    if (text.isEmpty) {
      row.holdsSaved = false;
    }
    _set(row, row.field.copyWith(value: text));
  }

  void _tick(_Row row, bool ticked) => _set(row, row.field.copyWith(value: ticked ? 'true' : 'false'));

  /// A new kind for a field of the person's own; what the value could not mean any more is reset.
  void _pickKind(_Row row, String kind) {
    if (kind == row.field.kind) {
      return;
    }
    final before = row.field.kind;
    final value = kind == CustomFieldKind.boolean
        ? 'false'
        : before == CustomFieldKind.boolean
        ? ''
        : row.field.value;
    row.value.text = value;
    if (value != row.field.value) {
      row.holdsSaved = false;
    }
    _set(row, row.field.copyWith(kind: kind, value: value, adminField: _ownOrAdmin(row)));
  }

  /// Shows or hides a hidden value. Showing what was saved asks first who it is when Settings says so, as the card's
  /// sheet does for its code; what was just typed shows at once.
  Future<void> _toggleShown(_Row row) async {
    if (!row.shown && row.holdsSaved && ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('fields.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) {
        return;
      }
    }
    setState(() => row.shown = !row.shown);
  }

  @override
  Widget build(BuildContext context) {
    final definitions = ref.watch(kmCustomFieldsProvider).value;
    final allowOwn = definitions?.allowOwn ?? true;
    final held = {for (final row in _rows) ?row.field.adminField};
    final offered = [
      for (final definition in definitions?.definitionsFor(_definitionKind(widget.kind)) ?? const <KmFieldDefinition>[])
        if (!held.contains(definition.id)) definition,
    ];
    final editable = _rows.where((row) => row.field.isEditable).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        SectionLabel(context.t('fields.title'), padding: const EdgeInsets.fromLTRB(6, 6, 6, 0)),
        for (final row in editable)
          _FieldRow(
            key: row.key,
            row: row,
            index: _rows.indexOf(row),
            // A field whose definition is gone, or the admin's whose list was never read, is the person's own, as in the view
            admin: isAdminField(row.field, definitions),
            canMove: editable.length > 1,
            canMoveUp: editable.first != row,
            canMoveDown: editable.last != row,
            onRename: (text) => _rename(row, text),
            onWrite: (text) => _write(row, text),
            onTick: (ticked) => _tick(row, ticked),
            onKind: (kind) => _pickKind(row, kind),
            onToggleShown: () => unawaited(_toggleShown(row)),
            onMove: (direction) => _move(row, direction),
            onRemove: () => _remove(row),
          ),
        if (offered.isNotEmpty || allowOwn)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: PopupMenuButton<Object>(
              key: const ValueKey('fields-add'),
              tooltip: context.t('fields.add'),
              onSelected: (choice) => _add(choice is KmFieldDefinition ? choice.toField() : _ownField),
              itemBuilder: (context) => [
                if (offered.isNotEmpty) ...[
                  PopupMenuItem<Object>(enabled: false, height: 32, child: Text(context.t('fields.fromAdmin'))),
                  for (final definition in offered)
                    PopupMenuItem<Object>(
                      key: ValueKey('fields-offer-${definition.id}'),
                      value: definition,
                      child: Text('${definition.name} · ${context.t(fieldKindId(definition.kind))}'),
                    ),
                ],
                if (offered.isNotEmpty && allowOwn) const PopupMenuDivider(),
                if (allowOwn)
                  PopupMenuItem<Object>(
                    key: const ValueKey('fields-own'),
                    value: 'own',
                    child: Text(context.t('fields.own')),
                  ),
              ],
              child: IgnorePointer(
                child: TextButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: Text(context.t('fields.add')),
                ),
              ),
            ),
          ),
        if (!allowOwn)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(context.t('fields.adminOnly'), style: AppType.caption.copyWith(color: context.bmc.faint)),
          ),
      ],
    );
  }
}

/// One field in the editor.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.row,
    required this.index,
    required this.admin,
    required this.canMove,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onRename,
    required this.onWrite,
    required this.onTick,
    required this.onKind,
    required this.onToggleShown,
    required this.onMove,
    required this.onRemove,
  });

  final _Row row;

  /// The row's place in the item's list, which keys its widgets.
  final int index;

  /// Whether the admin made the field: its name and kind are fixed.
  final bool admin;
  final bool canMove;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onWrite;
  final ValueChanged<bool> onTick;
  final ValueChanged<String> onKind;
  final VoidCallback onToggleShown;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final field = row.field;
    final label = admin ? field.name : context.t('fields.value');

    final Widget control;
    if (field.kind == CustomFieldKind.boolean) {
      control = CheckboxListTile(
        key: ValueKey('field-tick-$index'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        title: Text(admin ? field.name : context.t('fields.checked'), style: AppType.body1.copyWith(color: p.text)),
        value: field.isChecked,
        onChanged: (ticked) => onTick(ticked ?? false),
      );
    } else if (field.kind == CustomFieldKind.hidden) {
      control = SecretSelection(
        child: TextField(
          key: ValueKey('field-value-$index'),
          enableIMEPersonalizedLearning: false,
          controller: row.value,
          obscureText: !row.shown,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: null,
          contextMenuBuilder: secretTextMenu,
          style: AppType.mono(),
          onChanged: onWrite,
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: RevealPasswordButton(shown: row.shown, onPressed: onToggleShown),
          ),
        ),
      );
    } else {
      control = TextField(
        key: ValueKey('field-value-$index'),
        enableIMEPersonalizedLearning: false,
        controller: row.value,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 1,
        maxLines: 4,
        keyboardType: TextInputType.multiline,
        onChanged: onWrite,
        decoration: InputDecoration(labelText: label),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
      decoration: BoxDecoration(
        color: b.raised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: admin
                    ? Row(
                        spacing: 8,
                        children: [
                          Flexible(
                            child: Text(
                              field.name,
                              style: AppType.body1.copyWith(color: p.text, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          AccentTag(label: context.t('fields.admin')),
                        ],
                      )
                    : TextField(
                        key: ValueKey('field-name-$index'),
                        enableIMEPersonalizedLearning: false,
                        controller: row.name,
                        autocorrect: false,
                        textCapitalization: TextCapitalization.sentences,
                        onChanged: onRename,
                        decoration: InputDecoration(labelText: context.t('fields.name')),
                      ),
              ),
              if (canMove)
                PopupMenuButton<int>(
                  key: ValueKey('field-move-$index'),
                  tooltip: context.t('fields.move'),
                  icon: const Icon(Icons.swap_vert_rounded, size: 20),
                  onSelected: onMove,
                  itemBuilder: (context) => [
                    PopupMenuItem<int>(value: -1, enabled: canMoveUp, child: Text(context.t('fields.moveUp'))),
                    PopupMenuItem<int>(value: 1, enabled: canMoveDown, child: Text(context.t('fields.moveDown'))),
                  ],
                ),
              IconButton(
                key: ValueKey('field-remove-$index'),
                tooltip: context.t('fields.remove'),
                icon: Icon(Icons.close_rounded, size: 20, color: b.faint),
                onPressed: onRemove,
              ),
            ],
          ),
          if (!admin)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final kind in _pickable)
                    ChoiceChip(
                      key: ValueKey('field-kind-$index-$kind'),
                      label: Text(context.t(fieldKindId(kind))),
                      selected: field.kind == kind,
                      onSelected: (_) => onKind(kind),
                    ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsetsDirectional.only(top: admin ? 8 : 0, end: 8),
            child: control,
          ),
        ],
      ),
    );
  }
}
