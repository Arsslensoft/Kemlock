import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../ui/ui.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import '../security_keys/key_widgets.dart';
import 'key_reader.dart';

/// What a person is told when reading a security key for a vault failed
/// with [error] (openspec: add-security-key-unlock, decision 7); null for a
/// cancellation. [enrolling] says a key without a PIN is to get one first,
/// where the lock screen says it cannot open a vault.
String? keyReadErrorText(BuildContext context, Object error, {bool enrolling = false}) => switch (error) {
  KeyPinWrong(:final retries) => [
    context.t('securityKeys.pin.wrong'),
    if (retries != null) context.t('securityKeys.pin.triesLeft', {'count': retries}),
  ].join(' '),
  KeyPinPaused() => context.t('securityKeys.pin.locked'),
  KeyPinBlocked() => context.t('lock.key.blocked'),
  KeyNotEnrolled() || KeyNotEnrolledError() => context.t('lock.key.notThisVault'),
  KeyAlreadyEnrolled() || KeyAlreadyEnrolledError() => context.t('unlockMethod.key.already'),
  KeyPinNeeded() => context.t('lock.key.pinNeeded'),
  KeyHasNoPin() => context.t(enrolling ? 'unlockMethod.key.noPin' : 'lock.key.cannot'),
  KeyCannotGiveSecret() => context.t('lock.key.cannot'),
  KeyNotSteady() => context.t('lock.key.unsteady'),
  _ => keyErrorText(context, error),
};

/// Whether [error] is the key's own answer about its PIN, after which the
/// line about eight wrong PINs gives way to what the key said.
bool keyAnsweredPin(Object error) => error is KeyPinWrong || error is KeyPinPaused || error is KeyPinBlocked;

/// The texts of iPhone's NFC sheet for reading a key for a vault.
KeyPrompts keyPrompts(BuildContext context) =>
    (nfcMessage: context.t('securityKeys.nfc.hold'), nfcFailure: context.t('securityKeys.nfc.failed'));

/// What opens the active vault now, for a sheet that asks to confirm an
/// action (openspec: add-security-key-unlock, decision 9): its [password]
/// alone for a vault that opens with it, and an enrolled key's PIN and the
/// key as well for a vault that needs one, a key-only vault taking no
/// password. Null when the key's sheet was closed. Throws what
/// [VaultStore.proveOwner] throws, [IncorrectPasswordError] among them.
Future<OwnerProof?> proveOwnerWithKey(BuildContext context, WidgetRef ref, {String? password}) async {
  final store = ref.read(vaultStoreProvider);
  if (!store.unlockMode().needsKey) return store.proveOwner(password: password);
  final reader = ref.read(keyReaderProvider);
  final challenge = store.keyChallenge();
  final prompts = keyPrompts(context);
  final output = await showKeyPinSheet<KeyOutput>(
    context,
    reader: reader,
    title: context.t('unlockMethod.prove.key.title'),
    body: context.t('unlockMethod.prove.key.body'),
    read: (pin, lastTry) =>
        reader.read(pin: pin, salt: challenge.salt, allow: challenge.credentials, prompts: prompts, lastTryConfirmed: lastTry),
  );
  if (output == null) return null;
  try {
    return await store.proveOwner(password: password, key: (credential: output.credential, output: output.output));
  } finally {
    output.wipe();
  }
}

/// Asks for a security key's PIN, then runs [read] with it on the key
/// presented next, and gives what [read] gave, or null when the sheet was
/// closed. A wrong PIN, a key that is not the vault's and the like are
/// said in the sheet, which stays open for another try; at the key's last
/// try it asks before sending the PIN. [onSetPin], for a key with no PIN
/// yet, offers the Security key sheet where one is set. The PIN is cleared
/// with each read.
Future<T?> showKeyPinSheet<T>(
  BuildContext context, {
  required KeyReader reader,
  required String title,
  required String body,
  required Future<T> Function(Uint8List pin, bool lastTryConfirmed) read,
  bool enrolling = false,
  VoidCallback? onSetPin,
}) => showAppBottomSheet<T>(
  context,
  label: title,
  builder: (_) => KeyPinSheet<T>(reader: reader, title: title, body: body, read: read, enrolling: enrolling, onSetPin: onSetPin),
);

class KeyPinSheet<T> extends StatefulWidget {
  const KeyPinSheet({
    super.key,
    required this.reader,
    required this.title,
    required this.body,
    required this.read,
    this.enrolling = false,
    this.onSetPin,
  });

  final KeyReader reader;
  final String title;
  final String body;
  final Future<T> Function(Uint8List pin, bool lastTryConfirmed) read;
  final bool enrolling;
  final VoidCallback? onSetPin;

  @override
  State<KeyPinSheet<T>> createState() => _KeyPinSheetState<T>();
}

class _KeyPinSheetState<T> extends State<KeyPinSheet<T>> {
  final _pin = TextEditingController();
  var _reading = false;
  var _answered = false;
  String? _error;
  var _noPin = false;

  @override
  void initState() {
    super.initState();
    widget.reader.stage.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.reader.stage.removeListener(_changed);
    if (_reading) unawaited(widget.reader.cancel());
    _pin.dispose();
    super.dispose();
  }

  Future<void> _read({bool lastTryConfirmed = false}) async {
    if (_reading) return;
    final pin = Uint8List.fromList(utf8.encode(_pin.text));
    setState(() {
      _reading = true;
      _error = null;
      _noPin = false;
    });
    late final T result;
    Object? failure;
    try {
      result = await widget.read(pin, lastTryConfirmed);
    } catch (error) {
      failure = error;
    } finally {
      pin.fillRange(0, pin.length, 0);
    }
    if (!mounted) return;
    if (failure == null) {
      _pin.clear();
      Navigator.of(context).pop(result);
      return;
    }
    setState(() => _reading = false);
    if (failure is KeyPinLastTry) {
      final send = await showConfirmDialog(
        context,
        title: context.t('lock.key.lastTry.title'),
        body: Text(context.t('lock.key.lastTry.body')),
        cancelLabel: context.t('export.cancel'),
        confirmLabel: context.t('lock.key.lastTry.confirm'),
      );
      if (send && mounted) await _read(lastTryConfirmed: true);
      return;
    }
    final error = failure;
    setState(() {
      _answered = _answered || keyAnsweredPin(error);
      _noPin = error is KeyHasNoPin;
      _error = keyReadErrorText(context, error, enrolling: widget.enrolling);
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final stage = widget.reader.stage.value;
    final activity = switch (stage) {
      KeyReadStage.touch => context.t('securityKeys.activity.touch'),
      KeyReadStage.working => context.t('securityKeys.activity.working'),
      KeyReadStage.idle || KeyReadStage.waiting => context.t('securityKeys.wait.title'),
    };
    return PopScope(
      canPop: !_reading,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeySheetHeader(title: widget.title),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 14,
                children: [
                  Text(widget.body, style: AppType.body2.copyWith(color: p.textSecondary)),
                  if (_error case final error?)
                    AppAlert(
                      severity: AlertSeverity.error,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(error),
                          if (_noPin && widget.onSetPin != null)
                            TextButton(onPressed: widget.onSetPin, child: Text(context.t('securityKeys.pin.set'))),
                        ],
                      ),
                    ),
                  TextField(
                    controller: _pin,
                    autofocus: true,
                    enabled: !_reading,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _read(),
                    style: TextStyle(fontFamily: fontMono, fontSize: 18, letterSpacing: 3, color: p.text),
                    decoration: InputDecoration(
                      labelText: context.t('lock.key.pin'),
                      helperText: _answered ? ' ' : context.t('lock.key.pinNote'),
                    ),
                  ),
                  if (_reading)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(activity, style: AppType.caption.copyWith(color: p.textSecondary)),
                        const SizedBox(height: 6),
                        const LinearProgressIndicator(),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 14,
                runSpacing: 8,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: p.text),
                    onPressed: _reading ? () => unawaited(widget.reader.cancel()) : () => Navigator.of(context).pop(),
                    child: Text(context.t('export.cancel')),
                  ),
                  FilledButton(onPressed: _reading ? null : _read, child: Text(context.t('lock.key.read'))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
