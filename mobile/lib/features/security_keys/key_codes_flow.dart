/// What a person sees while Kemlock talks to a key's code application:
/// the prompt to present or touch the key, the password dialog, and what
/// went wrong, said plainly (openspec: add-security-key-codes).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/toasts.dart';
import '../../i18n/messages.dart';
import '../../models/key_account.dart';
import '../../platform/secret_clipboard.dart';
import '../../ui/ui.dart';
import 'key_codes.dart';

/// What a person is told when an exchange with a key ended as [result]
/// says. Null when there is nothing to say: it went well, or they cancelled.
String? keyCodesProblemText(BuildContext context, KeyCodesResult result) => switch (result.outcome) {
  KeyCodesOutcome.done || KeyCodesOutcome.cancelled => null,
  KeyCodesOutcome.passwordNeeded || KeyCodesOutcome.wrongPassword => context.t('keyCodes.password.wrong'),
  KeyCodesOutcome.untrustedKey => context.t('keyCodes.untrusted'),
  KeyCodesOutcome.unsupported => context.t('keyCodes.unsupported'),
  KeyCodesOutcome.interrupted => context.t(result.partial ? 'keyCodes.interrupted.partial' : 'keyCodes.interrupted'),
  KeyCodesOutcome.notTouched => context.t('keyCodes.notTouched'),
  KeyCodesOutcome.otherKey => context.t('keyCodes.otherKey'),
  KeyCodesOutcome.full => context.t('keyCodes.full', {'capacity': result.capacity ?? 32}),
  KeyCodesOutcome.noSuchAccount => context.t('keyCodes.noSuchAccount'),
  KeyCodesOutcome.unavailable => context.t('securityKeys.wait.none'),
  KeyCodesOutcome.nfcOff => context.t('securityKeys.error.nfcOff'),
  KeyCodesOutcome.refused => switch (result.refusal) {
    KeyRefusal.steam => context.t('keyCodes.refused.steam'),
    KeyRefusal.space => context.t('keyCodes.refused.space'),
    KeyRefusal.name => context.t('keyCodes.refused.name', {'bytes': result.nameBytes ?? 0}),
    KeyRefusal.algorithm => context.t('keyCodes.refused.algorithm', {'version': '${result.version}'}),
    KeyRefusal.touch => context.t('keyCodes.refused.touch', {'version': '${result.version}'}),
    KeyRefusal.secret || null => context.t('keyCodes.refused.secret'),
  },
  // The caller asks before replacing.
  KeyCodesOutcome.exists => null,
  KeyCodesOutcome.mismatch => context.t('keyCodes.move.mismatch'),
  KeyCodesOutcome.unchecked => context.t('keyCodes.move.unchecked'),
  KeyCodesOutcome.failed => context.t('keyCodes.failed'),
};

/// Says what went wrong with [result] in a toast, if anything did.
void showKeyCodesProblem(BuildContext context, KeyCodesResult result) {
  final text = keyCodesProblemText(context, result);
  if (text != null && context.mounted) showToast(context, text, severity: ToastSeverity.error);
}

/// One try of an exchange with a key: with what proves the password, once
/// the person typed it, and whether to remember that on this phone.
typedef KeyCodesAttempt = Future<KeyCodesResult> Function(Uint8List? accessKey, bool remember);

/// Runs [attempt] with the prompt to present or touch the key over the
/// screen, asks for the key's password when the key wants it and tries
/// again, and says what went wrong in the end. [onCancel] stops the
/// exchange when it runs on a key a screen holds; without it the wait for
/// a key is cancelled. With [quiet] a failure is returned and not said.
Future<KeyCodesResult> runKeyCodes(
  BuildContext context,
  WidgetRef ref,
  KeyCodesAttempt attempt, {
  Future<void> Function()? onCancel,
  bool quiet = false,
}) async {
  Uint8List? accessKey;
  var remember = false;
  while (true) {
    final running = attempt(accessKey, remember);
    final prompt = showAppDialog<void>(
      context,
      barrierDismissible: false,
      builder: (_) => _KeyPrompt(done: running, onCancel: onCancel ?? ref.read(keyCodesProvider.notifier).cancel),
    );
    final result = await running;
    // The prompt closes itself as the exchange ends; what comes next waits for it, so
    // a caller that closes its own sheet does not close the prompt in its place.
    if (context.mounted) await prompt;
    if (!context.mounted) return result;
    if (result.asksPassword && result.device != null) {
      final typed = await showAppDialog<({String password, bool remember})>(
        context,
        builder: (_) => KeyPasswordDialog(wrong: result.outcome == KeyCodesOutcome.wrongPassword, refused: result.rememberedRefused),
      );
      if (typed == null) return KeyCodesResult(KeyCodesOutcome.cancelled, device: result.device);
      accessKey = keyAccessFor(typed.password, result.device!);
      remember = typed.remember;
      if (!context.mounted) return result;
      continue;
    }
    if (!quiet) showKeyCodesProblem(context, result);
    return result;
  }
}

/// The dialog that stays up while a key is asked something: present the
/// key, the exchange under way, or a touch. It closes by itself when [done] ends.
class _KeyPrompt extends ConsumerStatefulWidget {
  const _KeyPrompt({required this.done, required this.onCancel});

  final Future<Object?> done;
  final Future<void> Function() onCancel;

  @override
  ConsumerState<_KeyPrompt> createState() => _KeyPromptState();
}

class _KeyPromptState extends ConsumerState<_KeyPrompt> {
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (mounted) Navigator.of(context).pop();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = context.bmc;
    final p = context.palette;
    final activity = ref.watch(keyCodesProvider.select((state) => state.activity));
    final (text, mark) = switch (activity) {
      KeyCodesActivity.touch => (
        context.t('keyCodes.prompt.touch'),
        Breathe(
          period: const Duration(milliseconds: 1600),
          scale: 1.18,
          child: Icon(Icons.touch_app_outlined, size: 22, color: b.accentText),
        ) as Widget,
      ),
      KeyCodesActivity.waiting => (context.t('keyCodes.prompt.present'), Icon(Icons.contactless_outlined, size: 22, color: b.accentText)),
      _ => (context.t('keyCodes.prompt.working'), Spinner(color: b.accentText)),
    };
    return PopScope(
      canPop: false,
      child: AppDialog(
        semanticLabel: context.t('keyCodes.prompt.title'),
        heading: DialogHeading(icon: const Icon(Icons.key_rounded), title: context.t('keyCodes.prompt.title')),
        content: Semantics(
          container: true,
          liveRegion: true,
          child: Row(
            children: [
              ExcludeSemantics(
                child: SizedBox(width: 24, height: 24, child: Center(child: mark)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text, style: AppType.body2.copyWith(color: p.textSecondary)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: p.text),
            onPressed: () => unawaited(widget.onCancel()),
            child: Text(context.t('export.cancel')),
          ),
        ],
      ),
    );
  }
}

/// Asks for the password of a key's code application, with "Remember on
/// this phone" off until the person ticks it. Pops with what was typed.
class KeyPasswordDialog extends StatefulWidget {
  const KeyPasswordDialog({super.key, this.wrong = false, this.refused = false});

  /// The password typed before was not the key's.
  final bool wrong;

  /// A remembered value was refused by the key, and dropped.
  final bool refused;

  @override
  State<KeyPasswordDialog> createState() => _KeyPasswordDialogState();
}

class _KeyPasswordDialogState extends State<KeyPasswordDialog> {
  final _password = TextEditingController();
  var _remember = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isEmpty) return;
    Navigator.of(context).pop((password: _password.text, remember: _remember));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final title = context.t('keyCodes.password.title');
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.password_rounded), title: title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.wrong)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppAlert(severity: AlertSeverity.error, child: Text(context.t('keyCodes.password.wrong'))),
            )
          else if (widget.refused)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppAlert(severity: AlertSeverity.info, child: Text(context.t('keyCodes.password.refused'))),
            ),
          Text(context.t('keyCodes.password.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          const SizedBox(height: 14),
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _password,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(labelText: context.t('keyCodes.password.label')),
          ),
          const SizedBox(height: 6),
          MergeSemantics(
            child: InkWell(
              onTap: () => setState(() => _remember = !_remember),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Checkbox(
                      value: _remember,
                      onChanged: (value) => setState(() => _remember = value ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(context.t('keyCodes.password.remember'), style: AppType.body1.copyWith(color: p.text)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Text(context.t('keyCodes.password.remember.detail'), style: AppType.caption.copyWith(color: b.faint)),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('export.cancel')),
        ),
        FilledButton(onPressed: _password.text.isEmpty ? null : _submit, child: Text(context.t('keyCodes.password.continue'))),
      ],
    );
  }
}

/// "Read the key": reads the key the person presents, or the one [runner]
/// holds.
Future<KeyCodesResult?> readKeyCodes(BuildContext context, WidgetRef ref, {KeyRunner? runner, Future<void> Function()? onCancel}) {
  final codes = ref.read(keyCodesProvider.notifier);
  return runKeyCodes(
    context,
    ref,
    onCancel: onCancel,
    (accessKey, remember) => codes.read(runner: runner, accessKey: accessKey, remember: remember),
  );
}

/// Asks the key for the one code of [account]: a touch account, or the
/// next code of a counter-based one.
Future<KeyCodesResult?> askKeyCode(BuildContext context, WidgetRef ref, KeyAccount account) {
  final codes = ref.read(keyCodesProvider.notifier);
  return runKeyCodes(context, ref, (accessKey, remember) => codes.calculate(account, accessKey: accessKey, remember: remember));
}

/// Copies [code], the code of [account] read from its key, as every code
/// is copied; says so in a toast. False when nothing was copied.
Future<bool> copyKeyCode(BuildContext context, WidgetRef ref, KeyAccount account, String code) async {
  if (!await ref.read(secretClipboardProvider).copy(code)) return false;
  if (context.mounted) ref.read(toastsProvider.notifier).show(context.t('accounts.copied', {'name': keyAccountTitle(context, account)}));
  return true;
}

/// What a row calls an on-key account: its issuer, else its label, else "Unknown".
String keyAccountTitle(BuildContext context, KeyAccount account) =>
    account.displayName.isNotEmpty ? account.displayName : context.t('accountCard.unknown');

/// Asks, then forgets the key [device] in this vault: the names of its
/// accounts, their tags and notes, and its remembered password. Nothing is
/// sent to the key. True when it was forgotten.
Future<bool> forgetKeyCodes(BuildContext context, WidgetRef ref, String device) async {
  final confirmed = await showConfirmDialog(
    context,
    icon: const Icon(Icons.link_off_rounded),
    title: context.t('keyCodes.forget.title'),
    body: Text(context.t('keyCodes.forget.body')),
    cancelLabel: context.t('export.cancel'),
    confirmLabel: context.t('keyCodes.forget.confirm'),
  );
  if (!confirmed || !context.mounted) return false;
  final done = await ref.read(keyCodesProvider.notifier).forget(device);
  if (!context.mounted) return done;
  if (done) {
    showToast(context, context.t('keyCodes.forgotten'));
  } else {
    showToast(context, context.t('keyCodes.snack.updateFailed'), severity: ToastSeverity.error);
  }
  return done;
}

/// Asks before deleting [account] from its key, naming it, then deletes
/// it there and from the list. True when it is gone.
Future<bool> deleteKeyAccount(
  BuildContext context,
  WidgetRef ref,
  KeyAccount account, {
  KeyRunner? runner,
  Future<void> Function()? onCancel,
}) async {
  final name = keyAccountTitle(context, account);
  final confirmed = await showConfirmDialog(
    context,
    icon: const Icon(Icons.delete_outline_rounded),
    title: context.t('keyCodes.delete.title'),
    body: Text(context.t('keyCodes.delete.body', {'name': name})),
    cancelLabel: context.t('export.cancel'),
    confirmLabel: context.t('keyCodes.delete'),
  );
  if (!confirmed || !context.mounted) return false;
  final codes = ref.read(keyCodesProvider.notifier);
  final result = await runKeyCodes(
    context,
    ref,
    onCancel: onCancel,
    (accessKey, remember) => codes.delete(account, runner: runner, accessKey: accessKey, remember: remember),
  );
  if (result.ok && context.mounted) showToast(context, context.t('keyCodes.deleted', {'name': name}));
  return result.ok;
}
