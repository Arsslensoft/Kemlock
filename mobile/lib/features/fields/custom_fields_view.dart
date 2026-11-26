import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/custom_field.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import '../lock/gate_widgets.dart';
import '../settings/prefs.dart';
import '../sync/kemlock/km_custom_fields.dart';
import '../vault/owner_check.dart';
import 'custom_fields_provider.dart';

/// What a hidden value shows.
const _dots = '••••••••••';

/// A field as the view shows it: its kind and value are what the item holds, always, so a type the admin changed later never
/// reads a value of another type (a text read as a checkbox, a hidden value shown as text). The admin's definition, when it is
/// the admin's and still exists, supplies only the name it has now and the Admin tag.
({String name, String kind, String value, bool admin}) _resolved(CustomField field, KmCustomFields? definitions) {
  final definition = field.adminField == null ? null : definitions?.definition(field.adminField!);
  final kind = field.kind;
  final value = kind == CustomFieldKind.boolean ? (field.value == 'true' ? 'true' : 'false') : field.value;
  return (name: definition?.name ?? field.name.trim(), kind: kind, value: value, admin: definition != null);
}

/// The custom fields of an item, read-only, for its detail sheet: a group of rows with the field's name and its value.
/// A hidden value is masked until the eye shows it, a checkbox reads Yes or No, and every value has a button that copies
/// it the way the app copies a password: through the sensitive clipboard, cleared after the delay Settings gives.
///
/// A field the admin made carries an Admin tag, and shows under the name the admin has for it now. An empty text or
/// hidden value says nothing, so it is left out, as a checkbox always says something; an entry this version can't edit
/// (a `linked` field, one with no name) isn't shown. With nothing to show, this takes no room.
class CustomFieldsView extends ConsumerStatefulWidget {
  const CustomFieldsView({super.key, required this.fields});

  final List<CustomField> fields;

  @override
  ConsumerState<CustomFieldsView> createState() => _CustomFieldsViewState();
}

class _CustomFieldsViewState extends ConsumerState<CustomFieldsView> {
  /// The hidden fields shown now, by their place in the item's list.
  final _shown = <int>{};

  @override
  void didUpdateWidget(CustomFieldsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A place in the list names another field once the list changes (one removed, one added, one reordered), and must not show it
    if (!listEquals(oldWidget.fields, widget.fields)) {
      _shown.clear();
    }
  }

  Future<void> _toggle(int index) async {
    if (!_shown.contains(index) && ref.read(prefsProvider).askBeforeSecret) {
      final reason = context.t('fields.reveal.confirm');
      if (!await ref.read(ownerCheckProvider)(context, ref, reason) || !mounted) {
        return;
      }
    }
    setState(() => _shown.contains(index) ? _shown.remove(index) : _shown.add(index));
  }

  Future<void> _copy(String text) async {
    if (await ref.read(secretClipboardProvider).copy(text) && mounted) {
      ref.read(toastsProvider.notifier).show(context.t('fields.copied'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final definitions = ref.watch(kmCustomFieldsProvider).value;
    final rows = <Widget>[];
    for (final (index, field) in widget.fields.indexed) {
      if (!field.isEditable || field.isBlank) {
        continue;
      }
      final shown = _resolved(field, definitions);
      if (shown.value.isEmpty && shown.kind != CustomFieldKind.boolean) {
        continue;
      }
      rows.add(_row(index, shown, first: rows.isEmpty));
    }
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Group(label: context.t('fields.title'), children: rows),
      ],
    );
  }

  Widget _row(int index, ({String name, String kind, String value, bool admin}) field, {required bool first}) {
    final tag = field.admin ? AccentTag(label: context.t('fields.admin')) : null;
    Widget copyButton(String text) => IconButton(
      key: ValueKey('field-copy-$index'),
      tooltip: context.t('fields.copy', {'name': field.name}),
      icon: const Icon(Icons.copy_rounded, size: 20),
      onPressed: () => unawaited(_copy(text)),
    );
    if (field.kind == CustomFieldKind.boolean) {
      final answer = context.t(field.value == 'true' ? 'fields.yes' : 'fields.no');
      return GroupRow(
        key: ValueKey('field-$index'),
        first: first,
        icon: const Icon(Icons.check_box_outlined),
        primary: field.name,
        secondary: answer,
        tag: tag,
        control: copyButton(answer),
      );
    }
    if (field.kind == CustomFieldKind.hidden) {
      final shown = _shown.contains(index);
      return GroupRow(
        key: ValueKey('field-$index'),
        first: first,
        icon: const Icon(Icons.visibility_off_outlined),
        primary: field.name,
        secondary: shown ? field.value : _dots,
        secondaryStyle: AppType.mono(),
        secondarySemanticsLabel: shown ? null : context.t('fields.hidden'),
        tag: tag,
        control: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevealPasswordButton(shown: shown, onPressed: () => unawaited(_toggle(index))),
            copyButton(field.value),
          ],
        ),
      );
    }
    return GroupRow(
      key: ValueKey('field-$index'),
      first: first,
      icon: const Icon(Icons.notes_rounded),
      primary: field.name,
      secondary: field.value,
      tag: tag,
      control: copyButton(field.value),
    );
  }
}
