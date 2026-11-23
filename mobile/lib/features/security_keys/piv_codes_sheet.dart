import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/piv/piv_commands.dart';
import '../../security_key/piv/piv_data.dart';
import '../../security_key/piv/piv_session.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'piv_controller.dart';
import 'piv_key_prompt.dart';

/// The two codes of a PIV card a person types.
enum PivCode { pin, puk }

/// Opens the sheet of [code]: its tries left, whether it is still the
/// factory one, and changing it; for a blocked PIN, setting a new one
/// with the PUK.
Future<void> showPivCodeSheet(BuildContext context, PivController piv, PivCode code) => showAppBottomSheet<void>(
  context,
  label: context.t(code == PivCode.pin ? 'piv.pin' : 'piv.puk'),
  builder: (_) => PivCodeSheet(piv: piv, code: code),
);

/// Why a new PIN or PUK is refused on the phone, or null when it may be
/// sent: a PIN has 6 to 8 characters and a PUK 8, neither may be the
/// factory one, and the two entries must be the same.
String? pivNewCodeProblem(BuildContext context, PivCode code, String next, String again) {
  final length = utf8.encode(next).length;
  if (code == PivCode.pin && (length < 6 || length > 8)) return context.t('piv.pin.length');
  if (code == PivCode.puk && length != 8) return context.t('piv.puk.length');
  if (next == (code == PivCode.pin ? pivFactoryPin : pivFactoryPuk)) {
    return context.t(code == PivCode.pin ? 'piv.pin.factoryRefused' : 'piv.puk.factoryRefused');
  }
  if (next != again) return context.t('piv.code.mismatch');
  return null;
}

/// The PIN's or the PUK's sheet. Everything is typed and checked here
/// before the key is asked for; the codes typed live only in this sheet
/// and the session they are sent in.
class PivCodeSheet extends StatefulWidget {
  const PivCodeSheet({super.key, required this.piv, required this.code});

  final PivController piv;
  final PivCode code;

  @override
  State<PivCodeSheet> createState() => _PivCodeSheetState();
}

class _PivCodeSheetState extends State<PivCodeSheet> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  bool _sending = false;

  PivController get _piv => widget.piv;
  bool get _isPin => widget.code == PivCode.pin;

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    for (final field in [_current, _next, _again]) {
      field.addListener(() => setState(() {}));
    }
    // The codes typed go when the app is hidden (design decision 11).
    _lifecycle = AppLifecycleListener(onHide: _forget);
  }

  void _forget() {
    for (final field in [_current, _next, _again]) {
      field.clear();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final field in [_current, _next, _again]) {
      field.dispose();
    }
    super.dispose();
  }

  /// Whether the PIN is blocked and this sheet sets a new one with the PUK.
  bool get _unblocking => _isPin && (_piv.state?.pinBlocked ?? false);

  bool get _filled => _current.text.isNotEmpty && _next.text.isNotEmpty && _again.text.isNotEmpty;

  Future<void> _submit({bool lastTry = false}) async {
    final state = _piv.state;
    if (!_filled || _sending || state == null) return;
    final unblocking = _unblocking;
    // The code sent first: the PIN to change it, the PUK to change it or to unblock the PIN.
    final usesPuk = !_isPin || unblocking;
    setState(() => _error = null);
    // A card takes eight bytes at most: a longer current code can't be the right one.
    final problem = utf8.encode(_current.text).length > 8
        ? context.t(usesPuk ? 'piv.puk.length' : 'piv.pin.length')
        : pivNewCodeProblem(context, unblocking ? PivCode.pin : widget.code, _next.text, _again.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final tries = usesPuk ? state.pukTries : state.pinTries;
    if (tries == 0) {
      setState(() => _error = context.t(usesPuk ? 'piv.puk.blocked' : 'piv.pin.blocked'));
      return;
    }
    if (tries == 1 && !lastTry) {
      if (!await confirmPivLastTry(context, context.t(usesPuk ? 'piv.lastTry.puk' : 'piv.lastTry.pin'))) return;
      lastTry = true;
    }
    final current = utf8.encode(_current.text);
    final next = utf8.encode(_next.text);
    setState(() => _sending = true);
    try {
      await _piv.run((session) async {
        if (usesPuk) {
          session.holdPuk(current);
          if (unblocking) {
            await session.unblockPin(next, lastTry: lastTry);
          } else {
            await session.changePuk(next, lastTry: lastTry);
          }
        } else {
          session.holdPin(current);
          await session.changePin(next, lastTry: lastTry);
        }
      }, shown: state);
      if (!mounted) return;
      showToast(
        context,
        context.t(
          unblocking
              ? 'piv.pin.unblocked'
              : _isPin
              ? 'piv.pin.changed'
              : 'piv.puk.changed',
        ),
      );
      Navigator.of(context).pop();
    } on PivLastTry {
      if (mounted) setState(() => _sending = false);
      if (mounted && await confirmPivLastTry(context, context.t(usesPuk ? 'piv.lastTry.puk' : 'piv.lastTry.pin'))) {
        await _submit(lastTry: true);
      }
      return;
    } on PivWrongCode catch (wrong) {
      if (mounted) {
        setState(
          () => _error =
              '${context.t(usesPuk ? 'piv.puk.wrong' : 'piv.pin.wrong')} ${context.t('securityKeys.pin.triesLeft', {'count': wrong.triesLeft})}',
        );
      }
    } on PivBlocked {
      if (mounted) setState(() => _error = context.t(usesPuk ? 'piv.puk.blocked' : 'piv.pin.blocked'));
    } on SecurityKeyCancelled {
      // Nothing to say: the form stays as it was.
    } catch (error) {
      if (mounted) setState(() => _error = pivErrorText(context, error));
    } finally {
      current.fillRange(0, current.length, 0);
      next.fillRange(0, next.length, 0);
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _piv, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final p = context.palette;
    final state = _piv.state;
    final unblocking = _unblocking;
    final pinTries = state?.pinTries;
    final pukTries = state?.pukTries;
    final bothBlocked = (state?.pinBlocked ?? false) && (state?.pukBlocked ?? false);
    final pukBlocked = state?.pukBlocked ?? false;
    final tries = _isPin && !unblocking ? pinTries : pukTries;
    final factory = (_isPin ? state?.pin?.isDefault : state?.puk?.isDefault) ?? false;
    final busy = _sending || _piv.busy;
    final noForm = bothBlocked || (!_isPin && pukBlocked);
    final title = context.t(_isPin ? 'piv.pin' : 'piv.puk');

    Widget field(TextEditingController controller, String label, {bool first = false, bool last = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: PivCodeField(
        controller: controller,
        label: label,
        autofocus: first,
        enabled: !busy,
        last: last,
        onSubmitted: () => unawaited(_submit()),
      ),
    );

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
                KeyActivity(controller: _piv.keys),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(context.t(_isPin ? 'piv.pin.about' : 'piv.puk.about'), style: AppType.body2.copyWith(color: p.textSecondary)),
                ),
                const SizedBox(height: 14),
                if (bothBlocked)
                  AppAlert(severity: AlertSeverity.error, child: Text(context.t('piv.codes.bothBlocked')))
                else if (!_isPin && pukBlocked)
                  AppAlert(severity: AlertSeverity.error, child: Text(context.t('piv.puk.blocked')))
                else if (unblocking)
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('piv.pin.unblock.body')))
                else if (tries == 1)
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t(_isPin ? 'piv.lastTry.pin' : 'piv.lastTry.puk')))
                else if (tries != null)
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('securityKeys.pin.triesLeft', {'count': tries}))),
                if (factory && !noForm) ...[
                  const SizedBox(height: 10),
                  AppAlert(
                    severity: AlertSeverity.warning,
                    child: Text(context.t(_isPin ? 'piv.pin.factoryWarning' : 'piv.puk.factoryWarning')),
                  ),
                ],
                if (_error != null) ...[const SizedBox(height: 10), AppAlert(severity: AlertSeverity.error, child: Text(_error!))],
                const SizedBox(height: 16),
                if (!noForm) ...[
                  field(_current, context.t(_isPin && !unblocking ? 'piv.pin.current' : 'piv.puk.current'), first: true),
                  field(_next, context.t(_isPin ? 'piv.pin.new' : 'piv.puk.new')),
                  field(_again, context.t(_isPin ? 'piv.pin.repeat' : 'piv.puk.repeat'), last: true),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                    child: Text(
                      context.t(_isPin ? 'piv.pin.rules' : 'piv.puk.rules'),
                      style: AppType.caption.copyWith(color: p.textSecondary),
                    ),
                  ),
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: _filled && !busy ? () => unawaited(_submit()) : null,
                    child: Text(
                      context.t(
                        unblocking
                            ? 'piv.pin.unblock'
                            : _isPin
                            ? 'piv.pin.change'
                            : 'piv.puk.change',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
