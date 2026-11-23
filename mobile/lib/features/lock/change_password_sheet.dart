import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import '../breaches/leak_check.dart';
import '../settings/prefs.dart';
import '../spaces/space_policies_provider.dart';
import 'gate_widgets.dart';
import 'key_pin_sheet.dart';
import 'master_password.dart';

/// Changes the open vault's master password, as `ChangePasswordDialog.tsx`
/// did: the current password is checked first, the new one is typed twice
/// and needs 12 characters or more, and the vault's key pair stays as it
/// is, only wrapped under the new password. The sheet can't be dismissed
/// while the new key is derived.
///
/// When the vault's leak check is on (openspec: password-leak-check), the
/// new password is first checked against the ones known from data breaches;
/// the sheet's checkbox is that setting.
Future<void> showChangePasswordSheet(BuildContext context) async {
  await showAppBottomSheet<void>(context, label: context.t('changePw.title'), builder: (_) => const _ChangePassword());
}

class _ChangePassword extends ConsumerStatefulWidget {
  const _ChangePassword();

  @override
  ConsumerState<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends ConsumerState<_ChangePassword> with LeakChecking {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  var _show = false;
  var _loading = false;
  var _keyAsked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in [_current, _next, _confirm]) {
      field.addListener(_rebuild);
    }
    leakCheckOn = ref.read(prefsProvider).leakCheck;
  }

  void _rebuild() => setState(() => leakPasswordEdited(_next.text));

  void _setLeakCheck(bool on) {
    ref.read(prefsProvider.notifier).update((prefs) => prefs.copyWith(leakCheck: on));
    setState(() {
      leakCheckOn = on;
      if (!on) leakFinding = null;
    });
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _mismatch => _confirm.text.isNotEmpty && _next.text != _confirm.text;

  bool get _canSubmit =>
      !_loading && !leakChecking && _current.text.isNotEmpty && _next.text.isNotEmpty && _confirm.text.isNotEmpty && !_mismatch;

  void _close() {
    if (!_loading) Navigator.of(context).pop();
  }

  /// Changes the password, after the leak check when it is on. [unchecked]
  /// goes on without it: the person chose to keep a leaked password, or to
  /// continue when the check couldn't be made.
  Future<void> _change({bool unchecked = false}) async {
    if (!_canSubmit) return;
    final next = _next.text;
    if (next != _confirm.text) {
      setState(() => _error = context.t('changePw.error.mismatch'));
      return;
    }
    if (!masterPasswordLongEnough(next)) {
      setState(() => _error = context.t('changePw.error.tooShort'));
      return;
    }
    // A space the member belongs to may ask for a longer one than the vault's own minimum
    final short = ref.read(spacePoliciesProvider).shortfallsOf(next);
    if (short.isNotEmpty) {
      setState(() => _error = context.t('changePw.error.space', {'space': short.first.label, 'length': short.first.minimum}));
      return;
    }
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    final store = ref.read(vaultStoreProvider);
    final controller = ref.read(vaultControllerProvider.notifier);
    final incorrect = context.t('changePw.error.incorrect');
    final navigator = Navigator.of(context);
    setState(() => _error = null);
    if (!await passesLeakCheck(next, skip: unchecked)) return;
    // The password was edited while the check was out: it has to be submitted again
    if (!mounted || next != _next.text || !_canSubmit) return;
    // The progress waits while the key's own sheet is up
    final asksKey = store.unlockMode().needsKey;
    setState(() {
      _error = null;
      _loading = true;
      _keyAsked = asksKey;
    });
    try {
      // The current password is checked again before the key is wrapped anew, with the vault's
      // security key too when it needs one (openspec: add-security-key-unlock, decision 9)
      final proof = await proveOwnerWithKey(context, ref, password: _current.text);
      if (mounted) setState(() => _keyAsked = false);
      if (proof == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final VaultSession changed;
      try {
        changed = await store.changePassword(session, next, proof: proof);
      } finally {
        proof.wipe();
      }
      controller.passwordChanged(changed);
      if (!mounted) return;
      setState(() => _loading = false);
      navigator.pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = incorrect;
        _loading = false;
        _keyAsked = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Shown and copied, a password goes through the secret clipboard
    Widget field(
      TextEditingController controller,
      String labelId, {
      bool autofocus = false,
      String? errorText,
      String? helperText,
      Widget? suffix,
      bool last = false,
    }) => SecretSelection(
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        enabled: !_loading,
        obscureText: !_show,
        autocorrect: false,
        enableSuggestions: false,
        // Null, not the empty default: the phone's password manager neither fills nor saves them
        autofillHints: null,
        enableIMEPersonalizedLearning: false,
        contextMenuBuilder: secretTextMenu,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onSubmitted: last ? (_) => _change() : null,
        style: AppType.body1.copyWith(color: p.text),
        decoration: InputDecoration(labelText: context.t(labelId), errorText: errorText, helperText: helperText, suffixIcon: suffix),
      ),
    );

    return PopScope(
      canPop: !_loading,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogHeading(icon: const Icon(Icons.key_rounded), title: context.t('changePw.title')),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  Text(context.t('changePw.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                  if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
                  field(
                    _current,
                    'changePw.field.current',
                    autofocus: true,
                    suffix: RevealPasswordButton(shown: _show, onPressed: () => setState(() => _show = !_show)),
                  ),
                  field(_next, 'changePw.field.new'),
                  field(
                    _confirm,
                    'changePw.field.confirm',
                    errorText: _mismatch ? context.t('changePw.field.mismatch') : null,
                    // Keeps the room the message takes, so nothing jumps when it shows
                    helperText: ' ',
                    last: true,
                  ),
                  LeakCheckOption(value: leakCheckOn, onChanged: _loading || leakChecking ? null : _setLeakCheck),
                  if (leakNotice case final finding?)
                    LeakFindingNotice(finding: finding, onUseAnyway: () => _change(unchecked: true), onRetry: _change),
                  if (leakChecking)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(context.t('leakCheck.checking'), style: AppType.caption.copyWith(color: p.textSecondary)),
                        const SizedBox(height: 6),
                        const LinearProgressIndicator(),
                      ],
                    ),
                  if (_loading && !_keyAsked)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(context.t('changePw.loading'), style: AppType.caption.copyWith(color: p.textSecondary)),
                        const SizedBox(height: 6),
                        const LinearProgressIndicator(),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 14,
                runSpacing: 8,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: p.text),
                    onPressed: _loading ? null : _close,
                    child: Text(context.t('changePw.cancel')),
                  ),
                  FilledButton(onPressed: _canSubmit ? _change : null, child: Text(context.t('changePw.button'))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
