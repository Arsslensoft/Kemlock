import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';

/// Whether an export is sealed with a password or plain JSON anyone can read.
enum ExportMode { encrypted, plaintext }

/// The frame of the export and import sheets, laid out as their dialogs
/// were: the heading with its icon tile, the content, which scrolls when
/// the sheet runs out of room, and the [actions] at the bottom right under
/// a hairline (MUI's `DialogContent dividers`).
class TransferSheet extends StatelessWidget {
  const TransferSheet({super.key, required this.icon, required this.title, required this.children, required this.actions});

  final IconData icon;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: Icon(icon), title: title),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
            child: DefaultTextStyle.merge(
              style: AppType.body1.copyWith(color: p.text),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
        Divider(height: 1, color: p.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 8, children: actions),
        ),
      ],
    );
  }
}

/// The Cancel or Close button of a transfer sheet, which closes it.
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(label));
}

/// A password field, outlined as the app's fields are. With [revealable]
/// an eye button at the end shows and hides what was typed.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.label,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.helperText,
    this.errorText,
    this.enabled = true,
    this.autofocus = false,
    this.revealable = true,
    this.dense = false,
    this.textInputAction = TextInputAction.done,
  });

  final String label;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? helperText;

  /// Paints the field red with this under it.
  final String? errorText;
  final bool enabled;
  final bool autofocus;
  final bool revealable;

  /// MUI's `size="small"`: 40 tall instead of 56.
  final bool dense;
  final TextInputAction textInputAction;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  // Shown and copied, the password goes through the secret clipboard
  @override
  Widget build(BuildContext context) => SecretSelection(
    child: TextField(
      enableIMEPersonalizedLearning: false,
      controller: widget.controller,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: !_shown,
      autocorrect: false,
      enableSuggestions: false,
      contextMenuBuilder: secretTextMenu,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.textInputAction,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        helperMaxLines: 3,
        errorText: widget.errorText,
        errorMaxLines: 3,
        isDense: widget.dense,
        contentPadding: widget.dense ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10) : null,
        suffixIcon: widget.revealable
            ? IconButton(
                onPressed: widget.enabled ? () => setState(() => _shown = !_shown) : null,
                icon: Icon(
                  _shown ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 22,
                  semanticLabel: context.t(_shown ? 'lock.hidePassword' : 'lock.showPassword'),
                ),
              )
            : null,
      ),
    ),
  );
}

/// How a [TransferTag] is painted.
enum TagTone {
  /// An outline in line2: counts and names.
  neutral,

  /// An Azure outline: what protects the file, what was found.
  accent,

  /// An Azure tint: a step done.
  filled,
}

/// A small pill of text, MUI's `<Chip size="small">`. With [onDelete] a
/// cross at its end removes it, named for screen readers as Flutter's
/// chips name theirs.
class TransferTag extends StatelessWidget {
  const TransferTag(this.label, {super.key, this.tone = TagTone.neutral, this.onDelete});

  final String label;
  final TagTone tone;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final ink = switch (tone) {
      TagTone.neutral => p.text,
      TagTone.accent || TagTone.filled => b.accentText,
    };
    return Container(
      height: 26,
      padding: EdgeInsets.only(left: 10, right: onDelete == null ? 10 : 3),
      decoration: BoxDecoration(
        color: tone == TagTone.filled ? b.accentSoft : null,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: switch (tone) {
            TagTone.neutral => b.line2,
            TagTone.accent => b.accentLine,
            TagTone.filled => Colors.transparent,
          },
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: fontSans, fontSize: 12.5, fontWeight: FontWeight.w500, height: 1.2, color: ink),
            ),
          ),
          if (onDelete != null)
            Semantics(
              button: true,
              label: MaterialLocalizations.of(context).deleteButtonTooltip,
              excludeSemantics: true,
              onTap: onDelete,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDelete,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.cancel_rounded, size: 18, color: ink.withValues(alpha: 0.45)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The small spaced capitals that number an import's steps.
class StepOverline extends StatelessWidget {
  const StepOverline(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text.toUpperCase(), style: AppType.overline.copyWith(color: context.palette.textSecondary)),
  );
}

/// A bar for work of unknown length. Under reduced motion it holds still,
/// as the app's other spinners do, so it doesn't sweep for ever.
class WorkingBar extends StatelessWidget {
  const WorkingBar({super.key});

  @override
  Widget build(BuildContext context) =>
      Motion.reduced(context) ? const ExcludeSemantics(child: LinearProgressIndicator(value: 0.35)) : const LinearProgressIndicator();
}

/// What is being worked on, in a caption over a [WorkingBar].
class WorkingNote extends StatelessWidget {
  const WorkingNote({super.key, this.caption});

  final String? caption;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption != null) ...[
          Text(caption!, style: AppType.caption.copyWith(color: context.palette.textSecondary)),
          const SizedBox(height: 5),
        ],
        const WorkingBar(),
      ],
    ),
  );
}

/// Picks an encrypted or a plain export, with a lock on each choice.
/// While not [enabled] it is dimmed and doesn't take taps.
class ExportModeControl extends StatelessWidget {
  const ExportModeControl({super.key, required this.value, required this.onChanged, required this.semanticLabel, this.enabled = true});

  final ExportMode value;
  final ValueChanged<ExportMode> onChanged;
  final String semanticLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: AnimatedOpacity(
      opacity: enabled ? 1 : 0.5,
      duration: Motion.reduced(context) ? Duration.zero : Motion.colour,
      child: SegmentedControl<ExportMode>(
        semanticLabel: semanticLabel,
        value: value,
        onChanged: onChanged,
        options: [
          SegmentOption(value: ExportMode.encrypted, label: context.t('export.mode.encrypted'), icon: const Icon(Icons.lock_rounded)),
          SegmentOption(value: ExportMode.plaintext, label: context.t('export.mode.plaintext'), icon: const Icon(Icons.lock_open_rounded)),
        ],
      ),
    ),
  );
}

/// [children] with [gap] between each one and the next.
List<Widget> spaced(List<Widget> children, {double gap = 16}) => [
  for (final (i, child) in children.indexed) ...[if (i > 0) SizedBox(height: gap), child],
];

/// Once the next frame is laid out, scrolls the sheet just far enough that
/// what [key] marks is in view, such as a result that appeared below.
void revealAfterFrame(GlobalKey key) => WidgetsBinding.instance.addPostFrameCallback((_) {
  final context = key.currentContext;
  if (context == null || !context.mounted) return;
  unawaited(
    Scrollable.ensureVisible(
      context,
      duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 350),
      curve: Ease.out,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    ),
  );
});
