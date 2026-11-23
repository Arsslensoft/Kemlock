import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../security_key/piv/piv_commands.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../security_key/piv/piv_session.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'piv_controller.dart';

/// Why the management key is asked for.
enum PivKeyAsk {
  /// The open vault has no note for this key, and it is not on its factory key.
  notFound,

  /// The key refused the one in the vault's note.
  vaultRefused,

  /// The key refused the one typed.
  wrong,
}

/// Runs [action] once the management key is proven to the key, in the
/// same session (design decision 9): the factory key if the key still
/// has it, else the one in the open vault's note for it, else one the
/// person types, which is asked for before the key is. A refused note
/// says it no longer matches and asks for the key to be typed.
///
/// Returns what [action] returned and where the key came from, or null
/// when the person gave up at the prompt. Whatever else fails is thrown.
Future<({T result, PivKeySource used})?> runWithManagementKey<T>(
  BuildContext context,
  PivController piv,
  Future<T> Function(PivSession session) action,
) async {
  final notes = ProviderScope.containerOf(context, listen: false).read(pivNotesProvider);
  var skipFactory = false;
  var skipNote = false;
  PivKeyAsk? asked;
  while (true) {
    final state = piv.state;
    if (state == null || !context.mounted) return null;
    var source = pivKnownKey(state, notes.notes, skipFactory: skipFactory, skipNote: skipNote);
    if (source == null) {
      final typed = await showPivManagementKeyPrompt(context, asked ?? PivKeyAsk.notFound);
      if (typed == null) return null;
      source = PivTypedKey(typed);
    }
    final used = source;
    try {
      // On the key whose note or factory key was chosen, and no other
      final result = await piv.run((session) async {
        await pivProve(session, used);
        return action(session);
      }, shown: state);
      return (result: result, used: used);
    } on PivVaultKeyRefused {
      skipNote = true;
      asked = PivKeyAsk.vaultRefused;
    } on PivManagementKeyRefused {
      if (used is PivFactoryKey) {
        // Changed since it was read: the note, or the person, has it.
        skipFactory = true;
      } else {
        asked = PivKeyAsk.wrong;
      }
    }
  }
}

/// Asks for the management key, as hex, and resolves to it, or to null
/// when the person backs out. [why] says what to tell them first.
Future<Uint8List?> showPivManagementKeyPrompt(BuildContext context, PivKeyAsk why) => showAppBottomSheet<Uint8List>(
  context,
  label: context.t('piv.managementKey'),
  builder: (_) => _KeyPrompt(why: why),
);

class _KeyPrompt extends StatefulWidget {
  const _KeyPrompt({required this.why});

  final PivKeyAsk why;

  @override
  State<_KeyPrompt> createState() => _KeyPromptState();
}

class _KeyPromptState extends State<_KeyPrompt> {
  final _field = TextEditingController();
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() => _invalid = false));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final key = parsePivManagementKey(_field.text);
    if (key == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(key);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (severity, text) = switch (widget.why) {
      PivKeyAsk.notFound => (AlertSeverity.info, context.t('piv.managementKey.ask.notFound')),
      PivKeyAsk.vaultRefused => (AlertSeverity.warning, context.t('piv.managementKey.ask.vaultRefused')),
      PivKeyAsk.wrong => (AlertSeverity.error, context.t('piv.error.managementKey')),
    };
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
                AppAlert(severity: severity, child: Text(text)),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(context.t('piv.managementKey.ask.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                const SizedBox(height: 14),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _field,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  minLines: 1,
                  maxLines: 3,
                  style: AppType.mono(fontSize: 14, fontWeight: FontWeight.w500),
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: context.t('piv.managementKey.field'),
                    errorText: _invalid ? context.t('piv.managementKey.invalid') : null,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _field.text.trim().isEmpty ? null : _submit,
                  child: Text(context.t('piv.continue')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Runs [task], and shows a toast for a failure with the PIV wording.
/// Returns null when it failed or was cancelled.
Future<T?> guardPiv<T>(BuildContext context, Future<T?> Function() task) async {
  try {
    return await task();
  } catch (error) {
    final text = context.mounted ? pivErrorText(context, error) : null;
    if (text != null && context.mounted) showToast(context, text, severity: ToastSeverity.error);
    return null;
  }
}

/// Asks, before a PIN or PUK is sent with one try left, whether to go on:
/// a wrong one now blocks it. [question] says which code it is.
Future<bool> confirmPivLastTry(BuildContext context, String question) => showConfirmDialog(
  context,
  icon: const Icon(Icons.warning_amber_rounded),
  title: context.t('piv.lastTry.title'),
  body: Text(question),
  confirmLabel: context.t('piv.continue'),
  cancelLabel: context.t('export.cancel'),
);

/// A field for a PIN or PUK: hidden as it is typed, on the number pad
/// unless the person switches to the full keyboard, since a PIV PIN may
/// hold letters. Its length is checked by the form, which says the rule.
class PivCodeField extends StatefulWidget {
  const PivCodeField({
    super.key,
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.enabled = true,
    this.last = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final bool enabled;

  /// The last field of its form: Done submits it.
  final bool last;
  final VoidCallback? onSubmitted;

  @override
  State<PivCodeField> createState() => _PivCodeFieldState();
}

class _PivCodeFieldState extends State<PivCodeField> {
  bool _digits = true;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _switch() {
    setState(() => _digits = !_digits);
    // The keyboard changes only when the field is focused afresh.
    if (_focus.hasFocus) {
      _focus.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) => TextField(
    enableIMEPersonalizedLearning: false,
    controller: widget.controller,
    focusNode: _focus,
    autofocus: widget.autofocus,
    enabled: widget.enabled,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: _digits ? TextInputType.number : TextInputType.visiblePassword,
    // A longer one is refused on the phone with the rule, rather than cut short unseen.
    inputFormatters: [LengthLimitingTextInputFormatter(64)],
    textInputAction: widget.last ? TextInputAction.done : TextInputAction.next,
    onSubmitted: widget.last ? (_) => widget.onSubmitted?.call() : null,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        onPressed: widget.enabled ? _switch : null,
        tooltip: context.t(_digits ? 'piv.code.keyboard' : 'piv.code.digits'),
        icon: Icon(_digits ? Icons.keyboard_outlined : Icons.dialpad_rounded, size: 20),
      ),
    ),
  );
}

/// Tells the person [body] under [title], with one button to close it.
Future<void> showPivNotice(BuildContext context, {required String title, required String body, bool danger = false}) => showAppDialog<void>(
  context,
  builder: (context) => AppDialog(
    semanticLabel: title,
    heading: DialogHeading(
      icon: Icon(danger ? Icons.error_outline_rounded : Icons.info_outline_rounded),
      title: title,
      tone: danger ? DialogTone.danger : DialogTone.accent,
    ),
    content: Text(body, style: AppType.body2.copyWith(color: context.palette.textSecondary)),
    actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.close')))],
  ),
);
