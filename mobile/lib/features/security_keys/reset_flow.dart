import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/fido/reset.dart';
import '../../ui/ui.dart';
import '../lock/unlock_method_sheet.dart';
import 'key_widgets.dart';
import 'security_key_controller.dart';

/// Asks whether to reset the key, saying plainly what that erases, and
/// then leads through the steps. Nothing is sent before the confirmation,
/// and no PIN is needed.
Future<void> startKeyReset(BuildContext context, SecurityKeyController controller) async {
  // The key the warning is about, as it was read: the reset goes to no key that differs from it
  final shown = controller.key;
  if (shown?.info == null) return;
  final confirmed = await showConfirmDialog(
    context,
    icon: const Icon(Icons.restart_alt_rounded),
    title: context.t('securityKeys.reset.title'),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(context.t('securityKeys.reset.statement.signIns')),
        const SizedBox(height: 8),
        Text(context.t('securityKeys.reset.statement.erased')),
        const SizedBox(height: 8),
        Text(context.t('securityKeys.reset.statement.undo')),
        // openspec: add-security-key-unlock
        const VaultKeysResetLine(),
      ],
    ),
    confirmLabel: context.t('securityKeys.reset.confirm'),
    cancelLabel: context.t('export.cancel'),
  );
  if (!confirmed || !context.mounted) return;
  await showAppBottomSheet<void>(
    context,
    label: context.t('securityKeys.reset.button'),
    builder: (_) => KeyResetFlow(controller: controller, shown: shown!),
  );
}

/// Whether the key of [session] may be the one [shown] describes. FIDO2
/// gives a key no identity of its own, so this is what can be compared: the
/// model (its AAGUID), the firmware and the name the key gives over USB when
/// both readings have one, and whether it has a PIN. Two keys of one model
/// and firmware, both with a PIN or both without, are not told apart, over
/// NFC or over USB, where the phone names a key anew each time it is
/// plugged in, as a reset needs it to be.
bool resetMayGoTo(KeyDetails shown, KeySession session) {
  final before = shown.info;
  final now = session.info;
  if (before == null || !before.sameModelAs(now)) return false;
  if (before.firmwareVersion != null && now.firmwareVersion != null && before.firmwareVersion != now.firmwareVersion) return false;
  final name = session.connection.device.productName;
  if (shown.productName != null && name != null && shown.productName != name) return false;
  return before.pin == now.pin;
}

/// The key presented for a reset is not the one the warning was about.
class ResetOtherKey implements Exception {
  const ResetOtherKey();
}

enum _Step {
  /// The key must lose its power first: unplugged, or taken away.
  leave,

  /// The key is waited for; the reset goes out the moment it is back.
  arrive,
  done,
  failed,
}

/// The steps of a reset after the confirmation. A key takes a reset only
/// in the ten seconds after it gets power, so the key is asked to leave
/// and come back, and the reset is sent as soon as it is there. The rule
/// is the key's: the app runs no timer of its own, it moves fast and
/// explains a refusal.
class KeyResetFlow extends StatefulWidget {
  const KeyResetFlow({super.key, required this.controller, required this.shown});

  final SecurityKeyController controller;

  /// The key as it was read when the person confirmed: the reset is sent
  /// only to a key [resetMayGoTo] lets through.
  final KeyDetails shown;

  @override
  State<KeyResetFlow> createState() => _KeyResetFlowState();
}

class _KeyResetFlowState extends State<KeyResetFlow> {
  late final bool _overNfc = widget.controller.key?.isNfc ?? widget.controller.capabilities.readsOnRequest;
  _Step _step = _Step.leave;
  bool _sending = false;
  String? _failure;

  SecurityKeyController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _controller.removeListener(_onKey);
    super.dispose();
  }

  void _begin() {
    if (!mounted) return;
    setState(() {
      _failure = null;
      _sending = false;
      _step = _controller.hub.live == null ? _Step.arrive : _Step.leave;
    });
    if (_step == _Step.arrive) unawaited(_send());
  }

  void _onKey() {
    if (!mounted) return;
    if (_step == _Step.leave && _controller.hub.live == null) {
      setState(() => _step = _Step.arrive);
      unawaited(_send());
    } else {
      setState(() {});
    }
  }

  Future<void> _send() async {
    try {
      await _controller.run((session) async {
        if (!resetMayGoTo(widget.shown, session)) throw const ResetOtherKey();
        if (mounted) setState(() => _sending = true);
        await resetKey(session.fido);
        _controller.forgetPinState();
        await _controller.refresh(session);
      }, viaNfc: _overNfc && _controller.capabilities.readsOnRequest);
      if (mounted) setState(() => _step = _Step.done);
    } on SecurityKeyCancelled {
      if (mounted) Navigator.of(context).pop();
    } on ResetOtherKey {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _failure = context.t('securityKeys.reset.failed.otherKey');
      });
    } on ResetRefused catch (refused) {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _failure = switch (refused.refusal) {
          ResetRefusal.notAllowed => [
            context.t('securityKeys.reset.failed.late'),
            if (_overNfc && _controller.capabilities.usb) context.t('securityKeys.reset.failed.late.usb'),
          ].join(' '),
          ResetRefusal.noTouch => context.t('securityKeys.reset.failed.noTouch'),
          _ => context.t('securityKeys.reset.failed.denied'),
        };
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _step = _Step.failed;
        _failure = keyErrorText(context, error) ?? context.t('securityKeys.error.failed');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final touch = _controller.touchNeeded;
    final (IconData icon, String title, String? detail) = switch (_step) {
      _Step.done => (Icons.check_rounded, context.t('securityKeys.reset.done'), null),
      _Step.failed => (Icons.error_outline_rounded, _failure ?? context.t('securityKeys.error.failed'), null),
      _ when touch => (Icons.touch_app_outlined, context.t('securityKeys.activity.touch'), null),
      _ when _sending => (Icons.restart_alt_rounded, context.t('securityKeys.reset.step.sending'), null),
      _Step.leave when _overNfc => (Icons.contactless_outlined, context.t('securityKeys.reset.step.nfc.away'), null),
      _ when _overNfc => (Icons.contactless_outlined, context.t('securityKeys.reset.step.nfc'), null),
      _ => (Icons.usb_rounded, context.t('securityKeys.reset.step.usb'), context.t('securityKeys.reset.step.usb.detail')),
    };
    final failed = _step == _Step.failed;
    // While a key is waited for: which keys are refused, and which can't be
    final waiting = (_step == _Step.leave || _step == _Step.arrive) && !touch && !_sending;
    final mark = Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: failed ? b.dangerSoft : b.accentSoft, borderRadius: BorderRadius.circular(24)),
      child: Icon(icon, size: 34, color: failed ? p.error : b.accentText),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.reset.button')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Center(
                    child: touch && _step != _Step.done && !failed
                        ? Breathe(period: const Duration(milliseconds: 1600), scale: 1.12, child: mark)
                        : mark,
                  ),
                ),
                const SizedBox(height: 18),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppType.h4.copyWith(color: p.text),
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: AppType.body2.copyWith(color: p.textSecondary),
                  ),
                ],
                if (waiting) ...[
                  const SizedBox(height: 10),
                  Text(
                    context.t('securityKeys.reset.step.sameModel'),
                    textAlign: TextAlign.center,
                    style: AppType.caption.copyWith(color: p.textSecondary),
                  ),
                ],
                const SizedBox(height: 22),
                if (_step == _Step.done)
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.t('securityKeys.reset.done.close')),
                  )
                else if (failed) ...[
                  FilledButton(style: largeButtonStyle, onPressed: _begin, child: Text(context.t('securityKeys.reset.again'))),
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('export.close'))),
                ] else
                  TextButton(
                    onPressed: () {
                      if (_controller.busy) {
                        unawaited(_controller.cancel());
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Text(context.t('export.cancel')),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
