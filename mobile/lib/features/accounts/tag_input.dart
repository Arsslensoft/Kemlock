import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import 'service_names.dart';

/// The longest a tag can be.
const maxTagLength = 24;

/// How many tags from other accounts are offered at once.
const maxTagSuggestions = 8;

/// Whether two tags are the same, ignoring case and accents, as
/// `localeCompare` with base sensitivity tells.
bool sameTag(String a, String b) => fold(a) == fold(b);

/// The tags of an account being edited, as `TagInput.tsx` had them: chips
/// that can be removed, a field where Enter or a comma adds what was typed,
/// and the tags of other accounts offered with one tap.
class TagInput extends StatefulWidget {
  const TagInput({super.key, required this.value, required this.onChanged, required this.suggestions});

  final List<String> value;
  final ValueChanged<List<String>> onChanged;

  /// Tags used on other accounts, offered with one tap.
  final List<String> suggestions;

  @override
  State<TagInput> createState() => TagInputState();
}

class TagInputState extends State<TagInput> {
  final _draft = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Leaving the field adds what was typed, as the web field did on blur.
    _focus.addListener(() {
      if (mounted && !_focus.hasFocus && _draft.text.trim().isNotEmpty) _add([_draft.text]);
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Adds whatever is typed and not yet added, and returns the tags with it,
  /// for a form saved while the field still holds a tag.
  List<String> commitDraft() => _draft.text.trim().isEmpty ? widget.value : _add([_draft.text]);

  List<String> _add(List<String> raws) {
    var next = widget.value;
    for (final raw in raws) {
      var tag = raw.trim();
      if (tag.length > maxTagLength) tag = tag.substring(0, maxTagLength);
      if (tag.isNotEmpty && !next.any((t) => sameTag(t, tag))) next = [...next, tag];
    }
    if (!identical(next, widget.value)) widget.onChanged(next);
    _draft.clear();
    return next;
  }

  void _typed(String text) {
    // A comma finishes a tag, as on most tag fields
    final parts = text.split(',');
    if (parts.length < 2) return;
    _add(parts.sublist(0, parts.length - 1));
    _draft.value = TextEditingValue(
      text: parts.last,
      selection: TextSelection.collapsed(offset: parts.last.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final value = widget.value;

    final offered = widget.suggestions.where((s) => !value.any((t) => sameTag(t, s))).take(maxTagSuggestions).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in value) TagChip(label: tag, onDelete: () => widget.onChanged([...value.where((t) => t != tag)])),
              ],
            ),
          ),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _draft,
          focusNode: _focus,
          onChanged: _typed,
          // Enter adds the tag and keeps the field open for the next one, instead of submitting the edit form
          onSubmitted: (text) => _add([text]),
          onEditingComplete: () {},
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(maxTagLength)],
          style: AppType.body1.copyWith(color: p.text),
          decoration: InputDecoration(
            labelText: context.t('tags.label'),
            hintText: context.t('tags.placeholder'),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        if (offered.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in offered) TagChip(label: tag, outlined: true, icon: Icons.add_rounded, onTap: () => _add([tag])),
              ],
            ),
          ),
      ],
    );
  }
}

/// A tag as MUI's `Chip` drew it: a pill with the tag's name, small (24)
/// or [medium] (32) tall, filled, [outlined] or [selected] in Azure, with
/// an optional leading [icon], a tap and a delete button.
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.medium = false,
    this.outlined = false,
    this.selected = false,
    this.icon,
    this.onTap,
    this.onDelete,
  });

  final String label;
  final bool medium;
  final bool outlined;
  final bool selected;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final height = medium ? 32.0 : 24.0;
    final pad = medium ? 12.0 : 8.0;
    final foreground = selected ? p.onPrimary : p.text;
    final background = selected
        ? p.primary
        : outlined
        ? Colors.transparent
        : p.selected;
    final shape = StadiumBorder(side: outlined && !selected ? BorderSide(color: b.line2) : BorderSide.none);

    final content = SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Padding(
              padding: EdgeInsets.only(left: medium ? 5 : 4),
              child: Icon(icon, size: medium ? 18 : 16, color: selected ? p.onPrimary : p.textSecondary),
            ),
          Padding(
            padding: EdgeInsets.only(left: icon != null ? pad - 4 : pad, right: onDelete != null ? pad - 4 : pad),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w500, height: 1, color: foreground),
            ),
          ),
          if (onDelete != null)
            Semantics(
              container: true,
              button: true,
              label: '${MaterialLocalizations.of(context).deleteButtonTooltip} $label',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.only(right: medium ? 5 : 4),
                  child: Icon(Icons.cancel_rounded, size: medium ? 22 : 16, color: p.text.withValues(alpha: 0.26)),
                ),
              ),
            ),
        ],
      ),
    );

    return Semantics(
      container: true,
      button: onTap != null,
      selected: onTap != null ? selected : null,
      child: Material(
        color: background,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, highlightColor: p.hover, child: content),
      ),
    );
  }
}
