import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../i18n/messages.dart';
import '../../platform/security_keys.dart';
import '../../security_key/fido/bio_enrollment.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/ctap.dart';
import '../../ui/ui.dart';
import 'key_widgets.dart';
import 'pin_forms.dart';
import 'security_key_controller.dart';

/// Runs [action] on the key's fingerprint commands, after the PIN, and
/// returns the list as the key has it afterwards.
Future<List<KeyFingerprint>?> _withReader(
  BuildContext context,
  SecurityKeyController controller, [
  Future<void> Function(BioEnrollment bio)? action,
]) => runWithKeyPin(
  context,
  controller,
  permission: PinPermission.bioEnrollment,
  action: (session, token) async {
    final bio = BioEnrollment(session.fido, session.info.bioEnrollmentCommand!, token);
    await action?.call(bio);
    return bio.list();
  },
);

/// Asks for the key's PIN, reads its fingerprints and opens the list. A
/// key with no reader never gets here: its row is greyed, and this does
/// nothing for it.
Future<void> openKeyFingerprints(BuildContext context, SecurityKeyController controller) async {
  if (controller.key?.info?.bioEnrollmentCommand == null) return;
  final fingerprints = await guardKey(context, () => _withReader(context, controller));
  if (fingerprints == null || !context.mounted) return;
  await showAppBottomSheet<void>(
    context,
    label: context.t('securityKeys.fingerprints.row'),
    builder: (_) => KeyFingerprintsSheet(controller: controller, fingerprints: fingerprints),
  );
}

/// The fingerprints on a key with a reader: the list by name, adding one
/// touch by touch, renaming and removing.
class KeyFingerprintsSheet extends StatefulWidget {
  const KeyFingerprintsSheet({super.key, required this.controller, required this.fingerprints});

  final SecurityKeyController controller;
  final List<KeyFingerprint> fingerprints;

  @override
  State<KeyFingerprintsSheet> createState() => _KeyFingerprintsSheetState();
}

class _KeyFingerprintsSheetState extends State<KeyFingerprintsSheet> {
  late List<KeyFingerprint> _fingerprints = widget.fingerprints;
  bool _enrolling = false;
  bool _working = false;

  /// How many more good touches the key asks for, once it has said.
  int? _remaining;

  /// What was wrong with the last touch, when something was.
  String? _sample;
  String? _notice;

  SecurityKeyController get _controller => widget.controller;

  String? _sampleText(FingerprintSample sample) => switch (sample) {
    FingerprintSample.good => null,
    FingerprintSample.tooShort || FingerprintSample.tooFast => context.t('securityKeys.fingerprints.bad.short'),
    FingerprintSample.tooHigh ||
    FingerprintSample.tooLow ||
    FingerprintSample.tooLeft ||
    FingerprintSample.tooRight ||
    FingerprintSample.tooSkewed => context.t('securityKeys.fingerprints.bad.off'),
    FingerprintSample.alreadyEnrolled => context.t('securityKeys.fingerprints.bad.exists'),
    _ => context.t('securityKeys.fingerprints.bad.quality'),
  };

  /// Runs [action] and takes the list the key has afterwards. Returns
  /// whether it went through.
  Future<bool> _change(Future<void> Function(BioEnrollment bio) action) async {
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      final fingerprints = await _withReader(context, _controller, action);
      if (fingerprints == null || !mounted) return false;
      setState(() => _fingerprints = fingerprints);
      return true;
    } on SecurityKeyCancelled {
      return false;
    } on CtapError catch (error) {
      if (mounted) {
        setState(
          () => _notice = switch (error.status) {
            CtapStatus.fingerprintDatabaseFull => context.t('securityKeys.fingerprints.full'),
            CtapStatus.userActionTimeout => context.t('securityKeys.fingerprints.noTouch'),
            _ => keyErrorText(context, error),
          },
        );
      }
      return false;
    } catch (error) {
      if (mounted) setState(() => _notice = keyErrorText(context, error));
      return false;
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _add() async {
    // A touch of the reader while the key is held to a phone is not practical: adding wants the key plugged in.
    if (_controller.key?.isNfc ?? true) {
      setState(() => _notice = context.t('securityKeys.fingerprints.add.nfc'));
      return;
    }
    setState(() {
      _enrolling = true;
      _remaining = null;
      _sample = null;
    });
    Uint8List? made;
    final added = await _change((bio) async {
      void show(EnrollStep step) {
        if (!mounted) return;
        setState(() {
          _remaining = step.remaining;
          _sample = _sampleText(step.sample);
        });
      }

      try {
        var step = await bio.begin();
        show(step);
        while (!step.done) {
          step = await bio.next(step.templateId);
          show(step);
        }
        made = step.templateId;
      } on SecurityKeyCancelled {
        // Giving up half-way: the key is told to drop the unfinished fingerprint.
        try {
          await bio.cancel();
        } on Exception {
          // The key is gone, and the unfinished fingerprint with its power.
        }
        rethrow;
      }
    });
    if (!mounted) return;
    setState(() => _enrolling = false);
    final id = made;
    if (!added || id == null) return;
    showToast(context, context.t('securityKeys.fingerprints.added'));
    await _rename(KeyFingerprint(id, null));
  }

  String _name(KeyFingerprint fingerprint, int index) => fingerprint.name == null || fingerprint.name!.isEmpty
      ? context.t('securityKeys.fingerprints.unnamed', {'number': index + 1})
      : fingerprint.name!;

  Future<void> _rename(KeyFingerprint fingerprint) async {
    final name = await showAppDialog<String>(context, builder: (_) => _NameDialog(initial: fingerprint.name ?? ''));
    if (name == null || name.isEmpty || !mounted) return;
    await _change((bio) => bio.rename(fingerprint.id, name));
  }

  Future<void> _remove(KeyFingerprint fingerprint, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.fingerprint_rounded),
      title: context.t('securityKeys.fingerprints.remove.title'),
      body: Text(context.t('securityKeys.fingerprints.remove.body', {'name': name})),
      confirmLabel: context.t('securityKeys.fingerprints.remove'),
      cancelLabel: context.t('export.cancel'),
    );
    if (!confirmed || !mounted) return;
    await _change((bio) => bio.remove(fingerprint.id));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final idle = !_working && !_controller.busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeySheetHeader(title: context.t('securityKeys.fingerprints.row')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_enrolling) KeyActivity(controller: _controller),
                if (_notice != null) ...[AppAlert(severity: AlertSeverity.warning, child: Text(_notice!)), const SizedBox(height: 14)],
                if (_enrolling)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 8, 20),
                    child: Column(
                      children: [
                        ExcludeSemantics(
                          child: Breathe(
                            period: const Duration(milliseconds: 1800),
                            scale: 1.12,
                            child: Container(
                              width: 72,
                              height: 72,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(24)),
                              child: Icon(Icons.fingerprint_rounded, size: 36, color: b.accentText),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            context.t('securityKeys.fingerprints.touch'),
                            textAlign: TextAlign.center,
                            style: AppType.h4.copyWith(color: p.text),
                          ),
                        ),
                        if (_remaining != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            context.t('securityKeys.fingerprints.remaining', {'count': _remaining}),
                            style: AppType.body2.copyWith(color: p.textSecondary),
                          ),
                        ],
                        if (_sample != null) ...[
                          const SizedBox(height: 12),
                          AppAlert(severity: AlertSeverity.warning, child: Text(_sample!)),
                        ],
                        const SizedBox(height: 14),
                        TextButton(onPressed: () => unawaited(_controller.cancel()), child: Text(context.t('export.cancel'))),
                      ],
                    ),
                  )
                else ...[
                  if (_fingerprints.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        context.t('securityKeys.fingerprints.empty'),
                        textAlign: TextAlign.center,
                        style: AppType.body2.copyWith(color: p.textSecondary),
                      ),
                    )
                  else
                    GroupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (index, fingerprint) in _fingerprints.indexed)
                            GroupRow(
                              first: index == 0,
                              icon: const Icon(Icons.fingerprint_rounded),
                              primary: _name(fingerprint, index),
                              control: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: idle ? () => unawaited(_rename(fingerprint)) : null,
                                    icon: Icon(Icons.edit_outlined, size: 20, semanticLabel: context.t('securityKeys.fingerprints.rename')),
                                  ),
                                  IconButton(
                                    onPressed: idle ? () => unawaited(_remove(fingerprint, _name(fingerprint, index))) : null,
                                    icon: Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                      color: p.error,
                                      semanticLabel: context.t('securityKeys.fingerprints.remove'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: largeButtonStyle,
                    onPressed: idle ? () => unawaited(_add()) : null,
                    child: Text(context.t('securityKeys.fingerprints.add')),
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

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = context.t('securityKeys.fingerprints.name.title');
    return AppDialog(
      semanticLabel: title,
      heading: DialogHeading(icon: const Icon(Icons.fingerprint_rounded), title: title),
      content: TextField(
        enableIMEPersonalizedLearning: false,
        controller: _name,
        autofocus: true,
        maxLength: 15,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        decoration: InputDecoration(labelText: context.t('securityKeys.fingerprints.name.field')),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: context.palette.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('export.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text.trim()),
          child: Text(context.t('securityKeys.fingerprints.name.save')),
        ),
      ],
    );
  }
}
