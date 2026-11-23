import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../ui/ui.dart';
import '../../vault/key_unlock.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_store.dart';
import '../recovery/recovery_kit_sheet.dart';
import '../settings/prefs.dart';
import 'gate_widgets.dart';
import 'key_pin_sheet.dart';
import 'key_replaced_summary.dart';

/// Replaces the open vault's key pair (openspec: replace-vault-key-pair):
/// says what it does, checks the master password, has the person make a new
/// Recovery Kit of the old one's shape or go on without one, and then runs
/// the replacement, which the sheet can't be closed during. [exposed] is
/// for the vault known to have been in an old biometric entry, asked once
/// after it opens: the sheet then says so, and can be put off.
Future<void> showReplaceKeySheet(BuildContext context, {bool exposed = false}) => showAppBottomSheet<void>(
  context,
  label: context.t('replaceKey.title'),
  builder: (_) => ReplaceKeySheet(exposed: exposed),
);

enum _Step { password, kit, working, done }

class ReplaceKeySheet extends ConsumerStatefulWidget {
  const ReplaceKeySheet({super.key, this.exposed = false});

  /// The vault's key is known to have been in an old biometric entry.
  final bool exposed;

  @override
  ConsumerState<ReplaceKeySheet> createState() => _ReplaceKeySheetState();
}

class _ReplaceKeySheetState extends ConsumerState<ReplaceKeySheet> {
  final _password = TextEditingController();
  var _step = _Step.password;
  var _show = false;
  var _checking = false;

  /// The message id of what went wrong, or null.
  String? _error;

  /// The vault's kit as it was before, whose shape the new one takes.
  late final RecoveryKitInfo? _kit = ref.read(vaultStoreProvider).recoveryKitInfo();

  /// When the last encrypted export was made, before the replacement: those
  /// made while the old kit existed still open with its pieces.
  late final int? _lastExportAt = ref.read(prefsProvider).lastBackupAt;

  /// How the vault opens: one that needs a security key confirms with
  /// [_proof], what [proveOwnerWithKey] gave, kept until the sheet closes.
  late final UnlockMode _opens = ref.read(vaultStoreProvider).unlockMode();
  bool get _needsKey => _opens.needsKey;
  bool get _keyOnly => !_opens.hasPassword;
  OwnerProof? _proof;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _proof?.wipe();
    _password.dispose();
    super.dispose();
  }

  bool get _busy => _checking || _step == _Step.working;

  void _close() {
    if (!_busy) Navigator.of(context).pop();
  }

  /// Checks the password before anything else, so no kit is made for nothing.
  /// A vault that needs a security key is asked for its key too, or for its
  /// key alone (openspec: add-security-key-unlock, decision 10).
  Future<void> _checkPassword() async {
    if (_busy || (_password.text.isEmpty && !_keyOnly)) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      if (_needsKey) {
        _proof?.wipe();
        _proof = await proveOwnerWithKey(context, ref, password: _keyOnly ? null : _password.text);
        if (_proof == null) {
          if (mounted) setState(() => _checking = false);
          return;
        }
      } else {
        await ref.read(vaultStoreProvider).unlockVault(_password.text);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = 'replaceKey.error.incorrect';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (_kit == null) return _replace();
    setState(() => _step = _Step.kit);
  }

  Future<void> _makeKit() async {
    final kit = _kit;
    if (kit == null) return;
    final made = await showReplacementKitSheet(context, threshold: kit.threshold, shares: kit.shares);
    if (made != null && mounted) await _replace(kit: made);
  }

  Future<void> _replace({RecoveryKey? kit}) async {
    setState(() {
      _step = _Step.working;
      _error = null;
    });
    try {
      await ref
          .read(vaultControllerProvider.notifier)
          .replaceKey(_password.text, kit: kit, dropKit: _kit != null && kit == null, proof: _proof);
      if (mounted) setState(() => _step = _Step.done);
    } on KeyReplacementIncomplete {
      if (mounted) {
        setState(() {
          _step = _Step.done;
          _error = 'replaceKey.error.unreadable';
        });
      }
    } on SafetyNetError {
      // Going on without a kit would leave a vault that needs its key with no way back in
      if (mounted) {
        setState(() {
          _step = _Step.kit;
          _error = 'unlockMethod.recovery.lastWayBack';
        });
      }
    } on IncorrectPasswordError {
      if (mounted) {
        setState(() {
          _step = _Step.password;
          _error = 'replaceKey.error.incorrect';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _step = _Step.password;
          _error = 'replaceKey.error.failed';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final body = AppType.body2.copyWith(color: p.textSecondary);
    final error = _error == null ? null : AppAlert(severity: AlertSeverity.error, child: Text(context.t(_error!)));
    Widget progress(String id) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.t(id), style: AppType.caption.copyWith(color: p.textSecondary)),
        const SizedBox(height: 6),
        const LinearProgressIndicator(),
      ],
    );

    final (String title, List<Widget> content, List<Widget> actions) = switch (_step) {
      _Step.password => (
        'replaceKey.title',
        [
          if (widget.exposed) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('replaceKey.exposed'))),
          Text(context.t('replaceKey.body'), style: body),
          if (_kit != null) Text(context.t('replaceKey.kitNote'), style: body),
          ?error,
          if (!_keyOnly)
            // Shown and copied, the password goes through the secret clipboard
            SecretSelection(
              child: TextField(
                controller: _password,
                autofocus: !widget.exposed,
                enabled: !_checking,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                // Null, not the empty default: the phone's password manager neither fills nor saves it
                autofillHints: null,
                enableIMEPersonalizedLearning: false,
                contextMenuBuilder: secretTextMenu,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _checkPassword(),
                style: AppType.body1.copyWith(color: p.text),
                decoration: InputDecoration(
                  labelText: context.t('unlock.field.password'),
                  suffixIcon: RevealPasswordButton(shown: _show, onPressed: () => setState(() => _show = !_show)),
                ),
              ),
            ),
          // A vault that needs a key shows the key's own sheet and its progress instead
          if (_checking && !_needsKey) progress('replaceKey.checking'),
        ],
        [
          _SheetButton(label: context.t(widget.exposed ? 'replaceKey.notNow' : 'changePw.cancel'), onPressed: _checking ? null : _close),
          FilledButton(
            onPressed: _checking || (_password.text.isEmpty && !_keyOnly) ? null : _checkPassword,
            child: Text(context.t(_kit == null ? 'replaceKey.button' : 'replaceKey.continue')),
          ),
        ],
      ),
      _Step.kit => (
        'replaceKey.kit.title',
        [Text(context.t('replaceKey.kit.body'), style: body), ?error],
        [
          _SheetButton(label: context.t('replaceKey.kit.skip'), onPressed: () => _replace()),
          FilledButton(onPressed: _makeKit, child: Text(context.t('replaceKey.kit.make'))),
        ],
      ),
      _Step.working => ('replaceKey.title', [progress('replaceKey.working')], const <Widget>[]),
      _Step.done => (
        'replaceKey.done.title',
        [?error, KeyReplacedSummary(oldKit: _kit, lastExportAt: _lastExportAt)],
        [FilledButton(onPressed: _close, child: Text(context.t('enableBiometric.done')))],
      ),
    };

    return PopScope(
      canPop: !_busy,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogHeading(icon: const Icon(Icons.autorenew_rounded), title: context.t(title)),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 16, children: content),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Wrap(alignment: WrapAlignment.end, spacing: 14, runSpacing: 8, children: actions),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain text button in the text's colour, as the sheets' Cancel is.
class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(foregroundColor: context.palette.text),
    onPressed: onPressed,
    child: Text(label),
  );
}
