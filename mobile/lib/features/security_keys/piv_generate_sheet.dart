import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/keys/algorithms.dart';
import '../../crypto/keys/pem.dart';
import '../../i18n/messages.dart';
import '../../platform/files.dart';
import '../../platform/security_keys.dart';
import '../../security_key/piv/piv_commands.dart';
import '../../security_key/piv/piv_data.dart';
import '../../security_key/piv/piv_operations.dart';
import '../../security_key/piv/piv_session.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'piv_controller.dart';
import 'piv_key_prompt.dart';

/// What a generated key gets: a certificate of its own, or a request for
/// an authority to sign, with a self-signed one as a placeholder.
enum PivCertificateKind { selfSigned, request }

/// How long a self-signed certificate is valid, in years.
const pivValidities = [1, 2, 5, 10];

/// Opens the Add sheet for [slot] (design decision 6): everything is asked
/// first, then the key is generated and its certificate stored in one
/// connection.
/// Resolves to true when the person chose to import a certificate instead.
Future<bool?> showPivGenerateSheet(BuildContext context, PivController piv, PivSlot slot, {PivCertificateKind? kind}) =>
    showAppBottomSheet<bool>(
      context,
      label: context.t('piv.generate.title'),
      builder: (_) => PivGenerateSheet(piv: piv, slot: slot, kind: kind ?? PivCertificateKind.selfSigned),
    );

/// The Add sheet: the algorithm, a certificate or a request, the name,
/// the validity and the PIN; then Generate. A slot that holds a key and no
/// certificate, because the key was taken away before the certificate
/// was stored, offers Finish.
class PivGenerateSheet extends ConsumerStatefulWidget {
  const PivGenerateSheet({super.key, required this.piv, required this.slot, this.kind = PivCertificateKind.selfSigned});

  final PivController piv;
  final PivSlot slot;
  final PivCertificateKind kind;

  @override
  ConsumerState<PivGenerateSheet> createState() => _PivGenerateSheetState();
}

class _PivGenerateSheetState extends ConsumerState<PivGenerateSheet> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  PivAlgorithm _algorithm = PivAlgorithm.eccP256;
  late PivCertificateKind _kind = widget.kind;
  int _years = 2;

  /// The public half of a key generated in this sheet whose certificate
  /// was not stored yet, or one the card reports for a slot with no
  /// certificate: Finish gives it its certificate.
  PublicHalf? _held;

  /// The key was taken away after generating.
  bool _dropped = false;
  bool _sending = false;
  String? _error;

  PivSlot get _slot => widget.slot;

  @override
  void initState() {
    super.initState();
    for (final field in [_name, _pin]) {
      field.addListener(() => setState(() {}));
    }
    final slot = widget.piv.state?.slots[_slot];
    if (slot != null && !slot.inUse && slot.metadata?.generated == true) _held = slot.publicKey;
    // The PIN typed goes when the app is hidden (design decision 11).
    _lifecycle = AppLifecycleListener(onHide: _pin.clear);
  }

  late final AppLifecycleListener _lifecycle;

  @override
  void dispose() {
    _lifecycle.dispose();
    _pin.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _filled => _name.text.trim().isNotEmpty && (!_slot.needsPin || _pin.text.isNotEmpty);

  Future<void> _submit({bool lastTry = false}) async {
    if (!_filled || _sending) return;
    final state = widget.piv.state;
    if (state == null) return;
    setState(() => _error = null);
    final name = _name.text.trim();
    if (name.length > 64) {
      setState(() => _error = context.t('piv.generate.nameTooLong'));
      return;
    }
    if (_slot.needsPin) {
      if (utf8.encode(_pin.text).length > 8) {
        setState(() => _error = context.t('piv.pin.length'));
        return;
      }
      if (state.pinBlocked) {
        setState(() => _error = context.t('piv.pin.blocked'));
        return;
      }
      if (state.pinTries == 1 && !lastTry) {
        if (!await confirmPivLastTry(context, context.t('piv.lastTry.pin'))) return;
        lastTry = true;
      }
    }
    final finishing = _held != null;
    if (!finishing && (state.slots[_slot]?.inUse ?? false)) {
      if (!mounted) return;
      final replace = await showConfirmDialog(
        context,
        icon: const Icon(Icons.swap_horiz_rounded),
        title: context.t('piv.generate.replace.title', {'slot': _slot.id}),
        body: Text(context.t('piv.generate.replace.body')),
        confirmLabel: context.t('piv.generate.replace.confirm'),
        cancelLabel: context.t('export.cancel'),
        danger: true,
      );
      if (!replace) return;
    }
    if (!mounted) return;
    final now = ref.read(clockProvider)().toUtc();
    final from = DateTime.utc(now.year, now.month, now.day, now.hour, now.minute, now.second);
    final years = _kind == PivCertificateKind.request ? 1 : _years;
    final until = DateTime.utc(from.year + years, from.month, from.day, from.hour, from.minute, from.second);
    final pin = utf8.encode(_pin.text);
    setState(() => _sending = true);
    try {
      final done = await runWithManagementKey(context, widget.piv, (session) async {
        if (_slot.needsPin) {
          session.holdPin(pin);
          await session.verifyPin(lastTry: lastTry);
        }
        final key = _held ?? await session.card.generate(_slot, _algorithm);
        _held = key;
        final reported = session.state.slots[_slot]?.publicKey;
        if (finishing && reported != null && !samePublicKey(reported, key)) throw const PivKeyMismatch();
        final certificate = await pivSelfSigned(
          session,
          _slot,
          key,
          commonName: name,
          notBefore: from,
          notAfter: until,
          lastTry: lastTry,
          pinVerified: _slot.needsPin,
        );
        final request = _kind == PivCertificateKind.request
            ? await pivRequest(session, _slot, key, commonName: name, lastTry: lastTry, pinVerified: _slot.needsPin)
            : null;
        await pivStoreCertificate(session, _slot, certificate);
        _held = null;
        return request;
      });
      if (done == null || !mounted) return;
      _dropped = false;
      final request = done.result;
      if (request != null) {
        await ref
            .read(fileServiceProvider)
            .shareFile(
              '${_slot.id}-${_fileName(name)}.csr',
              Uint8List.fromList(utf8.encode(writePem('CERTIFICATE REQUEST', request))),
              mimeType: 'application/pkcs10',
            );
      }
      if (!mounted) return;
      showToast(
        context,
        [context.t(request == null ? 'piv.generate.done' : 'piv.generate.done.request'), pivUsedText(context, done.used)].join(' '),
      );
      Navigator.of(context).pop();
    } on PivLastTry {
      // The tries went down since the sheet was read: the person is asked first.
      if (mounted) setState(() => _sending = false);
      if (mounted && await confirmPivLastTry(context, context.t('piv.lastTry.pin'))) await _submit(lastTry: true);
      return;
    } on PivWrongCode catch (wrong) {
      if (mounted) {
        setState(() => _error = '${context.t('piv.pin.wrong')} ${context.t('securityKeys.pin.triesLeft', {'count': wrong.triesLeft})}');
      }
    } on SecurityKeyRemoved catch (error) {
      if (!mounted) return;
      if (_held != null && !finishing) {
        setState(() => _dropped = true);
      } else {
        setState(() => _error = pivErrorText(context, error));
      }
    } on SecurityKeyTimeout catch (error) {
      if (!mounted) return;
      if (_held != null && !finishing) {
        setState(() => _dropped = true);
      } else {
        setState(() => _error = pivErrorText(context, error));
      }
    } on SecurityKeyCancelled {
      // Nothing to say.
    } catch (error) {
      if (mounted) setState(() => _error = pivErrorText(context, error));
    } finally {
      pin.fillRange(0, pin.length, 0);
      if (mounted) setState(() => _sending = false);
    }
  }

  static String _fileName(String name) {
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '').trim();
    return clean.isEmpty ? 'certificate' : clean;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final finishing = _held != null;
    final busy = _sending || widget.piv.busy;
    final state = widget.piv.state;
    final inUse = state?.slots[_slot]?.inUse ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('piv.generate.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyActivity(controller: widget.piv.keys),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    context.t('piv.generate.caption', {'slot': _slot.id, 'name': pivSlotName(context, _slot)}),
                    style: AppType.body2.copyWith(color: p.textSecondary),
                  ),
                ),
                const SizedBox(height: 14),
                if (finishing) ...[
                  AppAlert(
                    severity: AlertSeverity.warning,
                    child: Text(context.t(_dropped ? 'piv.generate.dropped' : 'piv.generate.keyOnly')),
                  ),
                  const SizedBox(height: 14),
                ] else if (inUse) ...[
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('piv.generate.inUse'))),
                  const SizedBox(height: 14),
                ],
                if (_error != null) ...[AppAlert(severity: AlertSeverity.error, child: Text(_error!)), const SizedBox(height: 14)],
                if (!finishing) ...[
                  SectionLabel(context.t('piv.generate.algorithm'), padding: const EdgeInsets.fromLTRB(6, 0, 6, 8)),
                  SegmentedControl<PivAlgorithm>(
                    semanticLabel: context.t('piv.generate.algorithm'),
                    value: _algorithm,
                    onChanged: busy ? (_) {} : (value) => setState(() => _algorithm = value),
                    options: const [
                      SegmentOption(value: PivAlgorithm.eccP256, label: 'ECC P-256'),
                      SegmentOption(value: PivAlgorithm.eccP384, label: 'ECC P-384'),
                      SegmentOption(value: PivAlgorithm.rsa2048, label: 'RSA 2048'),
                    ],
                  ),
                  if (_algorithm == PivAlgorithm.rsa2048) ...[
                    const SizedBox(height: 10),
                    AppAlert(severity: AlertSeverity.info, child: Text(context.t('piv.generate.rsaSlow'))),
                  ],
                  const SizedBox(height: 16),
                ],
                SegmentedControl<PivCertificateKind>(
                  semanticLabel: context.t('piv.generate.kind'),
                  value: _kind,
                  onChanged: busy ? (_) {} : (value) => setState(() => _kind = value),
                  options: [
                    SegmentOption(value: PivCertificateKind.selfSigned, label: context.t('piv.generate.selfSigned')),
                    SegmentOption(value: PivCertificateKind.request, label: context.t('piv.generate.request')),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    context.t(_kind == PivCertificateKind.request ? 'piv.generate.request.hint' : 'piv.generate.selfSigned.hint'),
                    style: AppType.caption.copyWith(color: p.textSecondary),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  enabled: !busy,
                  autocorrect: false,
                  inputFormatters: [LengthLimitingTextInputFormatter(64)],
                  textInputAction: _slot.needsPin ? TextInputAction.next : TextInputAction.done,
                  decoration: InputDecoration(labelText: context.t('piv.generate.name'), helperText: context.t('piv.generate.name.hint')),
                ),
                if (_kind == PivCertificateKind.selfSigned) ...[
                  SectionLabel(context.t('piv.generate.validity'), padding: const EdgeInsets.fromLTRB(6, 18, 6, 8)),
                  SegmentedControl<int>(
                    semanticLabel: context.t('piv.generate.validity'),
                    value: _years,
                    onChanged: busy ? (_) {} : (value) => setState(() => _years = value),
                    options: [
                      for (final years in pivValidities)
                        SegmentOption(value: years, label: context.t('piv.generate.years', {'count': years})),
                    ],
                  ),
                ],
                if (_slot.needsPin) ...[
                  const SizedBox(height: 16),
                  PivCodeField(
                    controller: _pin,
                    label: context.t('piv.pin.field'),
                    enabled: !busy,
                    last: true,
                    onSubmitted: () => unawaited(_submit()),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  style: largeButtonStyle,
                  onPressed: _filled && !busy ? () => unawaited(_submit()) : null,
                  child: Text(context.t(finishing ? 'piv.generate.finish' : 'piv.generate.button')),
                ),
                if (finishing && !_dropped) ...[
                  const SizedBox(height: 6),
                  TextButton(onPressed: busy ? null : () => setState(() => _held = null), child: Text(context.t('piv.generate.instead'))),
                ],
                if (!inUse && !finishing) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: busy ? null : () => Navigator.of(context).pop(true),
                    child: Text(context.t('piv.generate.importInstead')),
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
