import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/get_info.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'security_key_controller.dart';

/// The key presented is not the one the PIN was typed for: its PIN is
/// asked for afresh, and the other key's is never tried on it.
class _OtherKey implements Exception {
  const _OtherKey();
}

/// Shows [error] in a toast, unless it is a cancellation.
void showKeyError(BuildContext context, Object error) {
  final text = keyErrorText(context, error);
  if (text != null && context.mounted) showToast(context, text, severity: ToastSeverity.error);
}

/// Runs [task] and tells the person when the key could not be talked to.
/// Returns null then, and when the person cancelled.
Future<T?> guardKey<T>(BuildContext context, Future<T?> Function() task) async {
  try {
    return await task();
  } on SecurityKeyCancelled {
    return null;
  } on FidoUnavailable {
    // The sheet says what this key cannot do.
    return null;
  } catch (error) {
    if (context.mounted) showKeyError(context, error);
    return null;
  }
}

/// Runs [action] with a token for the key's PIN that allows [permission]
/// (a [PinPermission]). The PIN is asked for first, unless the sheet
/// already holds it, and only then is the key asked for: over NFC it is
/// held to the phone just for the exchange.
///
/// A wrong PIN is said with the tries left and asked again; a key that
/// demands a new PIN gets one first; a locked PIN is explained. Returns
/// null when the person gave up. Other failures are thrown.
Future<T?> runWithKeyPin<T>(
  BuildContext context,
  SecurityKeyController controller, {
  required int permission,
  required Future<T> Function(KeySession session, PinToken token) action,
}) async {
  PinWrong? wrong;
  while (true) {
    if (!context.mounted) return null;
    final info = controller.key?.info;
    if (info == null) return null;
    if (controller.pinBlocked) {
      await showKeyPinBlocked(context);
      return null;
    }
    if (controller.pinLocked) {
      await showAppDialog<void>(
        context,
        builder: (context) => _NoticeDialog(title: context.t('securityKeys.pin.prompt.title'), body: context.t('securityKeys.pin.locked')),
      );
      return null;
    }
    if (info.forcePinChange) {
      if (!await showKeyPinForm(context, controller, forced: true)) return null;
      continue;
    }
    if (controller.pin == null) {
      final typed = await showKeyPinPrompt(context, controller, wrong: wrong);
      if (typed == null) return null;
      controller.rememberPin(typed);
    }
    try {
      return await controller.run((session) async {
        final pin = controller.pin;
        // Another key than the PIN was typed for: the sheet forgot the PIN on meeting it.
        if (pin == null) throw const _OtherKey();
        if (session.info.forcePinChange) throw const _OtherKey();
        final token = await session.clientPin.token(pin, permissions: permission);
        return action(session, token);
      });
    } on _OtherKey {
      wrong = null;
    } on PinWrong catch (error) {
      controller.notePinError(error);
      wrong = error;
    } on PinLockedUntilReconnected catch (error) {
      controller.notePinError(error);
    } on PinBlocked catch (error) {
      controller.notePinError(error);
    } on SecurityKeyCancelled {
      return null;
    }
  }
}

/// Explains that the key's PIN is locked for good and how a reset clears it.
Future<void> showKeyPinBlocked(BuildContext context) => showAppDialog<void>(
  context,
  builder: (context) =>
      _NoticeDialog(title: context.t('securityKeys.pin.blocked.title'), body: context.t('securityKeys.pin.blocked'), danger: true),
);

class _NoticeDialog extends StatelessWidget {
  const _NoticeDialog({required this.title, required this.body, this.danger = false});

  final String title;
  final String body;
  final bool danger;

  @override
  Widget build(BuildContext context) => AppDialog(
    semanticLabel: title,
    heading: DialogHeading(
      icon: const Icon(Icons.lock_outline_rounded),
      title: title,
      tone: danger ? DialogTone.danger : DialogTone.accent,
    ),
    content: Text(body, style: AppType.body2.copyWith(color: context.palette.textSecondary)),
    actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.close')))],
  );
}

/// What the person is told about the tries the key has left.
class _TriesLeft extends StatelessWidget {
  const _TriesLeft({required this.retries, this.wrong = false});

  final int? retries;
  final bool wrong;

  @override
  Widget build(BuildContext context) => AppAlert(
    severity: wrong ? AlertSeverity.error : AlertSeverity.warning,
    child: Text(
      [
        if (wrong) context.t('securityKeys.pin.wrong'),
        if (retries != null) context.t('securityKeys.pin.triesLeft', {'count': retries}),
        context.t('securityKeys.pin.wrong.warning'),
      ].join(' '),
    ),
  );
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

/// Asks for the PIN of the key, and resolves to it as UTF-8, or to null
/// when the person backs out. After a [wrong] PIN it says so with the
/// tries left; before anything was typed it says how many are left when
/// the key reported three or fewer.
Future<Uint8List?> showKeyPinPrompt(BuildContext context, SecurityKeyController controller, {PinWrong? wrong}) =>
    showAppBottomSheet<Uint8List>(
      context,
      label: context.t('securityKeys.pin.prompt.title'),
      builder: (_) => _PinPrompt(retries: wrong?.retries ?? controller.key?.retries, wrong: wrong != null),
    );

/// The same prompt for a feature outside the Security key sheet, which
/// keeps no PIN and has read nothing of the key: [body] says what the PIN
/// is for (openspec: add-vaultwarden-security-key).
Future<Uint8List?> showKeyPinPromptFor(BuildContext context, {required String body, PinWrong? wrong}) => showAppBottomSheet<Uint8List>(
  context,
  label: context.t('securityKeys.pin.prompt.title'),
  builder: (_) => _PinPrompt(retries: wrong?.retries, wrong: wrong != null, body: body),
);

class _PinPrompt extends StatefulWidget {
  const _PinPrompt({required this.retries, required this.wrong, this.body});

  final int? retries;
  final bool wrong;

  /// What the PIN is for, when it is not for the Security key sheet.
  final String? body;

  @override
  State<_PinPrompt> createState() => _PinPromptState();
}

class _PinPromptState extends State<_PinPrompt> {
  final _pin = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pin.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pin.text.isEmpty) return;
    Navigator.of(context).pop(_utf8(_pin.text));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final few = widget.retries != null && widget.retries! <= 3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.pin.prompt.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    widget.body ?? context.t('securityKeys.pin.prompt.body'),
                    style: AppType.body2.copyWith(color: p.textSecondary),
                  ),
                ),
                if (widget.wrong || few) ...[const SizedBox(height: 14), _TriesLeft(retries: widget.retries, wrong: widget.wrong)],
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _pin,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(labelText: context.t('securityKeys.pin.field')),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _pin.text.isEmpty ? null : _submit,
                  child: Text(context.t('securityKeys.pin.continue')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens the form that sets a first PIN on a key that has none, or
/// changes the PIN of one that has. Resolves to true when the key took
/// the new PIN. With [forced] it says the key demands the change.
Future<bool> showKeyPinForm(BuildContext context, SecurityKeyController controller, {bool forced = false}) async {
  final info = controller.key?.info;
  if (info == null) return false;
  final change = info.pin == KeyPinState.set;
  if (change && controller.pinBlocked) {
    await showKeyPinBlocked(context);
    return false;
  }
  final done = await showAppBottomSheet<bool>(
    context,
    label: context.t(change ? 'securityKeys.pin.change' : 'securityKeys.pin.set'),
    builder: (_) => KeyPinForm(controller: controller, change: change, forced: forced),
  );
  return done ?? false;
}

/// The set-PIN and change-PIN form. Everything is typed and checked here
/// before the key is asked for.
class KeyPinForm extends StatefulWidget {
  const KeyPinForm({super.key, required this.controller, required this.change, this.forced = false});

  final SecurityKeyController controller;

  /// Whether the key has a PIN, which is then typed first.
  final bool change;
  final bool forced;

  @override
  State<KeyPinForm> createState() => _KeyPinFormState();
}

class _KeyPinFormState extends State<KeyPinForm> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  PinWrong? _wrong;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    for (final field in [_current, _next, _again]) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in [_current, _next, _again]) {
      field.dispose();
    }
    super.dispose();
  }

  bool get _filled => _next.text.isNotEmpty && _again.text.isNotEmpty && (!widget.change || _current.text.isNotEmpty);

  Future<void> _submit() async {
    if (!_filled || _sending) return;
    final controller = widget.controller;
    final minimum = controller.key?.info?.minPinLength ?? 4;
    setState(() {
      _error = null;
      _wrong = null;
    });
    if (_next.text != _again.text) {
      setState(() => _error = context.t('securityKeys.pin.mismatch'));
      return;
    }
    final next = _utf8(_next.text);
    try {
      checkNewPin(next, minimum);
    } on PinTooShort catch (short) {
      setState(() => _error = context.t('securityKeys.pin.tooShort', {'count': short.minimum}));
      return;
    } on PinTooLong {
      setState(() => _error = context.t('securityKeys.pin.tooLong'));
      return;
    }
    final current = _utf8(_current.text);
    setState(() => _sending = true);
    try {
      await controller.run((session) async {
        if (session.info.pin == KeyPinState.set) {
          await session.clientPin.changePin(current, next);
        } else {
          await session.clientPin.setPin(next);
        }
        controller.rememberPin(next);
        await controller.refresh(session);
      });
      if (!mounted) return;
      showToast(context, context.t(widget.change ? 'securityKeys.pin.done.changed' : 'securityKeys.pin.done.set'));
      Navigator.of(context).pop(true);
    } on PinWrong catch (error) {
      controller.notePinError(error);
      if (mounted) setState(() => _wrong = error);
    } on PinTooShort catch (short) {
      // The key met now asks for more than the one read before.
      if (mounted) setState(() => _error = context.t('securityKeys.pin.tooShort', {'count': short.minimum}));
    } on PinRefusedByKey {
      if (mounted) setState(() => _error = context.t(widget.change ? 'securityKeys.pin.refused' : 'securityKeys.pin.refused.first'));
    } on PinError catch (error) {
      controller.notePinError(error);
      if (mounted) setState(() => _error = keyErrorText(context, error));
    } on SecurityKeyCancelled {
      // Nothing to say: the form stays as it was.
    } catch (error) {
      if (mounted) setState(() => _error = keyErrorText(context, error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _field(TextEditingController controller, String label, {bool last = false, bool first = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      enableIMEPersonalizedLearning: false,
      controller: controller,
      autofocus: first,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      enabled: !_sending,
      inputFormatters: [LengthLimitingTextInputFormatter(128)],
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onSubmitted: last ? (_) => unawaited(_submit()) : null,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final title = context.t(widget.change ? 'securityKeys.pin.change' : 'securityKeys.pin.set');
    final retries = _wrong?.retries ?? widget.controller.key?.retries;
    final few = widget.change && retries != null && retries <= 3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: title),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.controller),
                if (widget.forced) ...[
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.pin.forced'))),
                  const SizedBox(height: 14),
                ],
                if (_wrong != null || few) ...[_TriesLeft(retries: retries, wrong: _wrong != null), const SizedBox(height: 14)],
                if (_error != null) ...[AppAlert(severity: AlertSeverity.error, child: Text(_error!)), const SizedBox(height: 14)],
                if (widget.change) _field(_current, context.t('securityKeys.pin.current'), first: true),
                _field(_next, context.t('securityKeys.pin.new'), first: !widget.change),
                _field(_again, context.t('securityKeys.pin.repeat'), last: true),
                const SizedBox(height: 2),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _filled && !_sending ? () => unawaited(_submit()) : null,
                  child: Text(context.t(widget.change ? 'securityKeys.pin.change' : 'securityKeys.pin.set.save')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
