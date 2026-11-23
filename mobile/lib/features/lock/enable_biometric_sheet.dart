import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/unlock_keys.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../settings/auto_lock.dart';
import 'error_text.dart';

/// What the phone's biometrics are called, and what they do here.
({String labelId, String hintId}) _platformIds() => defaultTargetPlatform == TargetPlatform.iOS
    ? (labelId: 'enableBiometric.platform.ios.label', hintId: 'enableBiometric.platform.ios.hint')
    : (labelId: 'enableBiometric.platform.android.label', hintId: 'enableBiometric.platform.android.hint');

/// Offers biometric unlock for the open vault, as `EnableBiometricDialog.tsx`
/// did in the phone app: Face ID or Touch ID on an iPhone, the fingerprint
/// or face unlock on Android. Enabling puts a key in the phone's hardware,
/// which shows the system prompt once, with auto-lock held while it is up.
/// The sheet can't be dismissed while the prompt is up.
Future<void> showEnableBiometricSheet(BuildContext context) async {
  final ids = _platformIds();
  final label = context.t(ids.labelId);
  await showAppBottomSheet<void>(
    context,
    label: context.t('enableBiometric.unlock', {'label': label}),
    builder: (_) => _EnableBiometric(label: label, hintId: ids.hintId),
  );
}

class _EnableBiometric extends ConsumerStatefulWidget {
  const _EnableBiometric({required this.label, required this.hintId});

  final String label;
  final String hintId;

  @override
  ConsumerState<_EnableBiometric> createState() => _EnableBiometricState();
}

class _EnableBiometricState extends ConsumerState<_EnableBiometric> {
  var _loading = false;
  var _done = false;
  String? _error;

  Future<void> _enable() async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    final unlockKeys = ref.read(unlockKeysProvider);
    final holds = ref.read(autoLockHoldsProvider);
    final store = ref.read(vaultStoreProvider);
    final failed = context.t('enableBiometric.error');
    final reason = context.t('enableBiometric.prompt', {'label': widget.label});
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      // Class 3 biometrics on Android, Face ID or Touch ID with a passcode on iOS
      if (!await unlockKeys.status()) throw const UnlockKeyUnavailable();
      // The prompt hides the app on some phones, which mustn't lock the vault
      await holds.withHeld(() => store.enableBiometricUnlock(session, reason));
      if (mounted) setState(() => _done = true);
    } on UnlockKeyCancelled {
      // The button is there to try again
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error, failed));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final label = widget.label;
    return PopScope(
      canPop: !_loading,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ExcludeSemantics(
                child: PopIn(
                  key: ValueKey(_done),
                  duration: const Duration(milliseconds: 500),
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: _done ? p.primary : p.paper,
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: b.line2),
                    ),
                    child: Icon(_done ? Icons.check_rounded : Icons.face_rounded, size: 38, color: _done ? p.onPrimary : b.accentText),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Semantics(
              header: true,
              liveRegion: true,
              child: Text(
                context.t(_done ? 'enableBiometric.done.title' : 'enableBiometric.unlock', {'label': label}),
                textAlign: TextAlign.center,
                style: AppType.h4.copyWith(color: p.text),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _done ? context.t('enableBiometric.done.body', {'label': label}) : context.t(widget.hintId),
              textAlign: TextAlign.center,
              style: AppType.body2.copyWith(color: p.textSecondary),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 16),
              AppAlert(
                severity: AlertSeverity.error,
                onClose: () => setState(() => _error = null),
                closeLabel: context.t('passkey.close'),
                child: Text(error),
              ),
            ],
            const SizedBox(height: 28),
            if (_done)
              FilledButton(
                style: largeButtonStyle,
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.t('enableBiometric.done')),
              )
            else ...[
              FilledButton(
                style: largeButtonStyle,
                onPressed: _loading ? null : _enable,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loading) ...[
                      SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.disabled)),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        _loading ? context.t('enableBiometric.loading') : context.t('enableBiometric.enable', {'label': label}),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _loading ? null : () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(foregroundColor: p.text),
                child: Text(context.t('enableBiometric.notNow')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
