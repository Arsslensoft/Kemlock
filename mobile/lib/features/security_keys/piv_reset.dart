import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'piv_controller.dart';

/// Resets the key's PIV application (design decision 12): after a warning
/// naming what is lost and the typed word, both codes are blocked, the
/// reset sent and the slots read again. With [finishing], for a key whose
/// codes are both blocked already, a plain question is enough. Afterwards
/// a vault note for the key is offered for deletion.
Future<void> startPivReset(BuildContext context, PivController piv, {bool finishing = false}) async {
  final state = piv.state;
  if (state == null || !state.makerCommands) return;
  final bool go;
  if (finishing) {
    go = await showConfirmDialog(
      context,
      icon: const Icon(Icons.restart_alt_rounded),
      title: context.t('piv.reset.finish'),
      body: Text(context.t('piv.reset.finish.body')),
      confirmLabel: context.t('piv.reset.button'),
      cancelLabel: context.t('export.cancel'),
      danger: true,
    );
  } else {
    go = await showAppBottomSheet<bool>(context, label: context.t('piv.reset.row'), builder: (_) => const PivResetConfirm()) ?? false;
  }
  if (!go || !context.mounted) return;
  // The card identifier goes with the reset: the note is looked for under the name the key had.
  final keyId = state.keyId;
  try {
    // Only on the key the warning was read for: a key read while it was up is not that one
    await piv.run(pivReset, shown: state);
  } on SecurityKeyCancelled {
    return;
  } catch (error) {
    final text = context.mounted ? pivErrorText(context, error) : null;
    if (text != null && context.mounted) showToast(context, text, severity: ToastSeverity.error);
    return;
  }
  if (!context.mounted) return;
  showToast(context, context.t('piv.reset.done'));
  final notes = ProviderScope.containerOf(context, listen: false).read(pivNotesProvider);
  final note = pivNoteFor(notes.notes, keyId);
  if (note == null) return;
  final delete = await showConfirmDialog(
    context,
    icon: const Icon(Icons.delete_outline_rounded),
    title: context.t('piv.reset.note.title'),
    body: Text(context.t('piv.reset.note.body', {'title': note.title})),
    confirmLabel: context.t('piv.reset.note.delete'),
    cancelLabel: context.t('piv.reset.note.keep'),
  );
  if (delete) await notes.delete(note);
}

/// The warning before a reset, and the word to type.
class PivResetConfirm extends StatefulWidget {
  const PivResetConfirm({super.key});

  @override
  State<PivResetConfirm> createState() => _PivResetConfirmState();
}

class _PivResetConfirmState extends State<PivResetConfirm> {
  final _word = TextEditingController();

  @override
  void initState() {
    super.initState();
    _word.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final word = context.t('piv.reset.word');
    final typed = _word.text.trim().toUpperCase() == word.toUpperCase();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('piv.reset.row')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppAlert(severity: AlertSeverity.error, child: Text(context.t('piv.reset.lost'))),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(context.t('piv.reset.kept'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _word,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: context.t('piv.reset.type', {'word': word})),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle.merge(filledButtonColors(background: p.error, foreground: p.onError)),
                  onPressed: typed ? () => Navigator.of(context).pop(true) : null,
                  child: Text(context.t('piv.reset.button')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
