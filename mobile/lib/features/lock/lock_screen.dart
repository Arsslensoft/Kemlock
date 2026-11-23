import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../i18n/messages.dart';
import '../../platform/secret_selection.dart';
import '../../platform/security_keys.dart';
import '../../ui/ui.dart';
import '../../vault/key_unlock.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../../vault/vault_registry.dart';
import '../../vault/vault_store.dart';
import '../export/android_export.dart';
import '../import/credential_exchange.dart';
import '../mail/mail_service.dart';
import '../mail/request_route.dart';
import '../recovery/recovery_unlock_sheet.dart';
import '../share/shared_item_waiting.dart';
import 'error_text.dart';
import 'gate_widgets.dart';
import 'key_pin_sheet.dart';
import 'key_reader.dart';
import 'unlock_attempts.dart';

/// How long the vault's opening plays before the app takes over.
const openDelay = Duration(milliseconds: 380);

/// How long the right password of a vault that needs both is kept for its
/// key (openspec: add-security-key-unlock, decision 7).
const keyStepTimeout = Duration(minutes: 2);

/// Where the lock screen is: waiting, at the biometric prompt, checking the
/// password, reading a security key, or opening.
enum _Phase { idle, quick, password, key, open }

/// The lock screen, `LockScreen.tsx`: the vault dial, a choice among the
/// listed vaults, and the master password, or biometric unlock where it is
/// set up, which it prompts for straight away. A hidden vault is never
/// offered: its password alone opens it.
///
/// Each password typed is counted against the listed vault on screen, or
/// the phone when none is, before it is checked ([UnlockAttempts]), and the
/// screen says how many wrong ones there were since that vault last opened.
/// From three, or when asked, it offers the Recovery Kit or wiping every
/// vault. With the erase turned on in Settings, it warns from three tries
/// left and erases every vault at the chosen number, or at once when a
/// count is there already (the app was killed during the last check).
///
/// A vault that needs a security key (openspec: add-security-key-unlock)
/// has a key step: after its password for a vault that needs both, at once
/// for a listed vault that opens with a key alone. It asks for the key's
/// PIN, then the key, and offers the Recovery Kit and the password form.
/// Nothing at the key step is counted: the key counts its own PIN tries.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key, this.openRecovery = showRecoveryUnlockSheet});

  /// Opens the Recovery Kit sheet, which gives the session it opened, or
  /// null. Tests put in their own.
  final Future<VaultSession?> Function(BuildContext context) openRecovery;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  late final VaultRegistry _vaults = ref.read(vaultRegistryProvider);
  late final VaultStore _store = ref.read(vaultStoreProvider);
  late final UnlockAttempts _attempts = ref.read(unlockAttemptsProvider);
  late final List<String> _listed;
  final _password = TextEditingController();
  final _focus = FocusNode();
  String? _vaultId;
  late _Phase _phase;
  late bool _usePassword;
  var _showPassword = false;
  String? _error;
  String? _quickError;

  /// Why biometric unlock went away for the vault on screen, above the password form.
  String? _notice;

  /// The wrong passwords of the slot on screen since it last opened.
  var _failures = UnlockFailures.none;
  var _forgot = false;
  Timer? _openTimer;
  Timer? _focusTimer;

  // The key step. [_keyVault] is the vault it opens: the listed key-only
  // vault on screen, or the vault whose password gave [_pending].
  late final KeyReader _reader = ref.read(keyReaderProvider);
  String? _keyVault;
  PendingKeyStep? _pending;
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();
  SecurityKeyCapabilities? _keyReach;

  /// A key has answered a PIN, so the line about 8 wrong PINs gives way to its count.
  var _keyAnswered = false;
  String? _keyError;
  Timer? _keyTimer;
  AppLifecycleListener? _lifecycle;

  bool get _atKey => _keyVault != null;

  @override
  void initState() {
    super.initState();
    _listed = _vaults.listedVaultIds();
    // A hidden vault is never preselected: with none listed, the password alone picks one
    _vaultId = _choose(_vaults.startingVault());
    _failures = _attempts.read(_vaultId);
    _lifecycle = AppLifecycleListener(onStateChange: _lifecycleChanged);
    _reader.stage.addListener(_stageChanged);
    unawaited(_reader.capabilities().then((reach) => mounted ? setState(() => _keyReach = reach) : null, onError: (Object _) {}));
    // A listed vault that opens with a key alone starts on its key step
    if (_keyOnly(_vaultId)) _keyVault = _vaultId;
    // A try counted and never checked can have reached the erase already
    final eraseAfter = readUnlockErase(ref.read(keyValueStoreProvider));
    if (eraseAfter != null && _attempts.highestCount() >= eraseAfter) {
      _phase = _Phase.idle;
      _usePassword = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _erase(eraseAfter);
      });
      return;
    }
    final quick = _quickFor(_vaultId);
    _phase = quick ? _Phase.quick : _Phase.idle;
    _usePassword = !quick;
    _password.addListener(_rebuild);
    // Prompt for a registered biometric straight away; fall back quietly to the buttons
    if (quick) WidgetsBinding.instance.addPostFrameCallback((_) => _autoQuick());
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _openTimer?.cancel();
    _focusTimer?.cancel();
    _keyTimer?.cancel();
    _pending?.wipe();
    _lifecycle?.dispose();
    _reader.stage.removeListener(_stageChanged);
    _password.dispose();
    _focus.dispose();
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  /// What the key is doing changed: the line under the title says it.
  void _stageChanged() {
    if (mounted && _phase == _Phase.key) setState(() {});
  }

  /// Whether [id] is a listed vault that opens with a security key alone.
  bool _keyOnly(String? id) => id != null && _store.unlockMode(id) == UnlockMode.key;

  /// The right password of a vault that needs both: the key step, for two
  /// minutes at most.
  void _toKeyStep(PendingKeyStep pending) {
    _keyTimer?.cancel();
    _keyTimer = Timer(keyStepTimeout, () => _leaveKeyStep(notice: context.t('lock.key.expired')));
    setState(() {
      _pending = pending;
      _keyVault = pending.vault;
      _keyError = null;
      _password.clear();
      _phase = _Phase.idle;
    });
    _focusTimer = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _pinFocus.requestFocus();
    });
  }

  /// Back to the password form: the step a password gave is dropped, and
  /// with it the password's key; the PIN is cleared.
  void _leaveKeyStep({String? notice}) {
    _keyTimer?.cancel();
    _keyTimer = null;
    _pending?.wipe();
    _pending = null;
    _pin.clear();
    if (_phase == _Phase.key) unawaited(_reader.cancel());
    if (!mounted) return;
    setState(() {
      _keyVault = null;
      _keyError = null;
      _notice = notice ?? _notice;
      _usePassword = true;
      if (_phase == _Phase.key) _phase = _Phase.idle;
    });
    _focusTimer = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _focus.requestFocus();
    });
  }

  /// The app was hidden. A password typed and not sent goes, and the
  /// reveal button covers it again: whoever picks the phone up next finds
  /// an empty field. Unless the system's NFC sheet or USB question hides it
  /// for the key's sake, the step a password gave goes too, and so does a
  /// PIN typed.
  void _lifecycleChanged(AppLifecycleState state) {
    if (state != AppLifecycleState.hidden && state != AppLifecycleState.paused) return;
    _password.clear();
    if (_showPassword && mounted) setState(() => _showPassword = false);
    if (!_atKey || _reader.coveredBySystem) return;
    if (_pending != null) return _leaveKeyStep();
    _pin.clear();
  }

  /// Reads the key presented next for the vault of the key step, after its
  /// PIN, and opens the vault with what it gives. Nothing here is counted.
  Future<void> _readKey({bool lastTryConfirmed = false}) async {
    final vault = _keyVault;
    if (vault == null || _phase != _Phase.idle) return;
    final pending = _pending;
    final prompts = keyPrompts(context);
    final challenge = _store.keyChallenge(vault);
    final pin = Uint8List.fromList(utf8.encode(_pin.text));
    setState(() {
      _keyError = null;
      _error = null;
      _notice = null;
      _phase = _Phase.key;
    });
    KeyOutput? output;
    String? error;
    try {
      output = await _reader.read(
        pin: pin,
        salt: challenge.salt,
        allow: challenge.credentials,
        prompts: prompts,
        lastTryConfirmed: lastTryConfirmed,
      );
      // The step was left while the key was read
      if (!mounted || _keyVault != vault || _pending != pending) return;
      final session = await _store.unlockWithSecurityKey(vault, (credential: output.credential, output: output.output), pending: pending);
      _keyTimer?.cancel();
      _pending?.wipe();
      _pending = null;
      _pin.clear();
      _open(session, _attempts.reset(_vaultId));
      return;
    } on KeyPinLastTry {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      final send = await showConfirmDialog(
        context,
        title: context.t('lock.key.lastTry.title'),
        body: Text(context.t('lock.key.lastTry.body')),
        cancelLabel: context.t('export.cancel'),
        confirmLabel: context.t('lock.key.lastTry.confirm'),
      );
      if (send && mounted) return _readKey(lastTryConfirmed: true);
      return;
    } on ProofIncompleteError {
      // The password's step went while the key was read: the password is typed again
      _leaveKeyStep();
      return;
    } catch (other) {
      _keyAnswered = _keyAnswered || keyAnsweredPin(other);
      if (mounted) error = keyReadErrorText(context, other);
    } finally {
      output?.wipe();
      pin.fillRange(0, pin.length, 0);
    }
    if (!mounted) return;
    setState(() {
      _keyError = error;
      _pin.clear();
      if (_phase == _Phase.key) _phase = _Phase.idle;
    });
    _focusTimer = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _pinFocus.requestFocus();
    });
  }

  /// Points storage at a listed vault, so its biometric unlock is the one offered.
  String? _choose(String? id) {
    if (id != null) _vaults.active = id;
    return id;
  }

  bool _quickFor(String? id) => id != null && _store.hasBiometricUnlock();

  /// Plays the opening, then hands the session to the app, with the wrong
  /// passwords [failures] the slot on screen had, for the app to report.
  /// Whichever vault opened, hidden ones too, the slot's count goes back to
  /// zero, so a watcher sees what an open of the vault on screen does.
  void _open(VaultSession session, UnlockFailures failures) {
    if (!mounted) return;
    setState(() => _phase = _Phase.open);
    final controller = ref.read(vaultControllerProvider.notifier);
    final phone = _vaultId == null;
    _openTimer = Timer(openDelay, () => unawaited(controller.open(session, failures: failures, phoneSlot: phone)));
  }

  /// The biometric prompt, then the vault it opens; null when nothing
  /// opened. When biometric unlock went away, because biometrics changed or
  /// because the phone has none the hardware key can use and the old entry
  /// was deleted, says why, once, and asks for the password.
  Future<VaultSession?> _runQuick() async {
    final reason = context.t('unlock.passkey.useBiometric');
    final invalidated = context.t('unlock.biometric.invalidated');
    final unsupported = context.t('unlock.biometric.unsupported');
    final result = await _store.unlockWithBiometrics(reason, ref.read(biometricsProvider));
    switch (result.outcome) {
      case BiometricOutcome.invalidated:
        _biometricsGone(invalidated);
      case BiometricOutcome.unsupported:
        _biometricsGone(unsupported);
      case BiometricOutcome.opened || BiometricOutcome.moved || BiometricOutcome.fellBack || BiometricOutcome.cancelled:
        break;
    }
    return result.session;
  }

  /// Biometric unlock is off for the vault on screen now: the password form,
  /// with [notice] saying why.
  void _biometricsGone(String notice) {
    if (!mounted) return;
    setState(() {
      _notice = notice;
      _usePassword = true;
    });
    _focusTimer = Timer(const Duration(milliseconds: 50), () {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _autoQuick() async {
    if (!mounted) return;
    try {
      final session = await _runQuick();
      if (session != null) {
        _open(session, _attempts.reset(_vaultId));
        return;
      }
    } catch (_) {
      // The buttons are there to try again
    }
    if (mounted) setState(() => _phase = _Phase.idle);
  }

  Future<void> _quick() async {
    final fallback = context.t('unlock.passkey.waitingBiometric');
    setState(() {
      _quickError = null;
      _error = null;
      _phase = _Phase.quick;
    });
    try {
      final session = await _runQuick();
      if (session != null) {
        _open(session, _attempts.reset(_vaultId));
      } else if (mounted) {
        setState(() => _phase = _Phase.idle);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _quickError = errorText(error, fallback);
      });
    }
  }

  Future<void> _unlock() async {
    final password = _password.text;
    if (password.isEmpty || _phase == _Phase.password || _phase == _Phase.open) return;
    final incorrect = context.t('unlock.error.incorrectPassword');
    final failed = context.t('unlock.error.failed');
    setState(() {
      _error = null;
      _quickError = null;
      _phase = _Phase.password;
    });
    final slot = _vaultId;
    // Written to the phone's storage before the password is checked, so quitting during scrypt takes no try back
    final before = await _attempts.countTry(slot);
    // Let "Verifying…" show before the key is derived
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      switch (await _store.beginUnlock(password, slot)) {
        case UnlockOpened(:final session):
          // The try that opened was no wrong password: what is reported is what came before it
          _open(session, _attempts.reset(slot, before: before));
        case UnlockNeedsKey(:final pending):
          // Nor was the right password of a vault that needs both; the count goes to zero once it opens
          _attempts.restore(slot, before);
          if (!mounted) return pending.wipe();
          _failures = before;
          _toKeyStep(pending);
      }
    } on IncorrectPasswordError {
      if (!mounted) return;
      final eraseAfter = readUnlockErase(ref.read(keyValueStoreProvider));
      if (eraseAfter != null && _attempts.read(slot).count >= eraseAfter) return _erase(eraseAfter);
      setState(() {
        _failures = _attempts.read(slot);
        _error = incorrect;
        _password.clear();
        _phase = _Phase.idle;
      });
      _focusTimer = Timer(const Duration(milliseconds: 50), () {
        if (mounted) _focus.requestFocus();
      });
    } catch (error) {
      // Anything else is the vault's storage failing, after the right password as well: it is no wrong
      // password, so it isn't counted, and it never erases
      _attempts.restore(slot, before);
      if (!mounted) return;
      setState(() {
        _failures = _attempts.read(slot);
        _error = errorText(error, failed);
        _phase = _Phase.idle;
      });
    }
  }

  void _switchVault(String id) {
    if (id == _vaultId || _phase != _Phase.idle) return;
    _pending?.wipe();
    _pending = null;
    _keyTimer?.cancel();
    _pin.clear();
    setState(() {
      _vaultId = _choose(id);
      _keyVault = _keyOnly(id) ? id : null;
      _keyError = null;
      _usePassword = !_quickFor(id);
      _error = null;
      _quickError = null;
      _notice = null;
      _failures = _attempts.read(id);
    });
  }

  Future<void> _recover() async {
    final session = await widget.openRecovery(context);
    if (session == null) return;
    // A vault the kit opened has no key step left to finish
    _keyTimer?.cancel();
    _pending?.wipe();
    _pending = null;
    _pin.clear();
    _open(session, _attempts.reset(_vaultId));
  }

  /// Erases every vault on the phone after [after] wrong passwords in a
  /// row, as the reset does, hardware keys included, and leaves the note
  /// the setup screen shows. Killed in the middle, the app finishes the
  /// erase, note and all, at its next launch.
  void _erase(int after) {
    final now = ref.read(clockProvider)();
    // Setup takes the screen's place; until it does, nothing is being checked any more
    if (mounted) setState(() => _phase = _Phase.idle);
    _store.wipeVault(
      erasedNote: erasedNoteValue(at: now, after: after),
    );
    ref.read(vaultControllerProvider.notifier).wiped();
  }

  Future<void> _confirmWipe() async {
    final confirmed = await showConfirmDialog(
      context,
      icon: const Icon(Icons.delete_forever_rounded),
      title: context.t('unlock.wipe.title'),
      body: Text(context.t('unlock.wipe.body')),
      cancelLabel: context.t('unlock.wipe.cancel'),
      confirmLabel: context.t('unlock.wipe.confirm'),
    );
    if (!confirmed || !mounted) return;
    _store.wipeVault();
    ref.read(vaultControllerProvider.notifier).wiped();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final quickAvailable = _quickFor(_vaultId);
    final eraseAfter = ref.watch(unlockEraseProvider);
    final triesLeft = eraseAfter == null ? null : eraseAfter - _failures.count;
    final quickLabel = context.t('unlock.passkey.useBiometric');
    final title = switch (_phase) {
      _Phase.open => 'lock.title.open',
      // An iPhone reads a key's FIDO2 over NFC only; an Android phone may also take it plugged in
      _ when _atKey => _keyReach != null && !_keyReach!.readsOnRequest && _keyReach!.usb ? 'lock.key.titleAndroid' : 'lock.key.title',
      _Phase.idle => 'lock.title.locked',
      _Phase.quick || _Phase.password || _Phase.key => 'lock.title.verifying',
    };
    final sub = switch (_phase) {
      _Phase.open => context.t('lock.sub.open'),
      _ when _atKey => _keyStepLine(context),
      _Phase.password => context.t('unlock.loading'),
      _Phase.quick => context.t('unlock.passkey.waitingBiometric'),
      _Phase.idle || _Phase.key => context.t('lock.sub.locked'),
    };

    return Scaffold(
      backgroundColor: p.background,
      body: FadeIn(
        child: GateLayout(
          maxWidth: 440,
          child: Column(
            children: [
              BrandWordmark(height: 26, label: context.t('app.title')),
              const SizedBox(height: 32),
              VaultDial(
                state: switch (_phase) {
                  _Phase.open => VaultDialState.open,
                  _Phase.idle => VaultDialState.idle,
                  _Phase.quick || _Phase.password || _Phase.key => VaultDialState.busy,
                },
                icon: Icon(
                  _phase == _Phase.open
                      ? Icons.check_rounded
                      : _atKey
                      ? Icons.key_rounded
                      : Icons.lock_rounded,
                ),
              ),
              const SizedBox(height: 28),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  context.t(title),
                  textAlign: TextAlign.center,
                  style: AppType.h2.copyWith(fontSize: 31, letterSpacing: -1.085, color: p.text),
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: AppType.body1.copyWith(color: p.textSecondary),
                ),
              ),
              const Expanded(child: SizedBox(height: 32)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  // A mail app's request brought the lock screen up (openspec: add-pgp-mail-provider)
                  if (ref.watch(mailFrontProvider) case final request?) MailRequestLine(front: request),
                  if (sharedItemWaits(ref)) const SharedItemWaiting(),
                  if (credentialExchangeWaits(ref)) const CredentialExchangeWaiting(),
                  if (exportRequestWaits(ref)) const ExportRequestWaiting(),
                  if (_quickError case final quickError?)
                    AppAlert(
                      severity: AlertSeverity.error,
                      onClose: () => setState(() => _quickError = null),
                      closeLabel: context.t('passkey.close'),
                      child: Text(quickError),
                    ),
                  if (_notice case final notice?)
                    AppAlert(
                      severity: AlertSeverity.info,
                      onClose: () => setState(() => _notice = null),
                      closeLabel: context.t('passkey.close'),
                      child: Text(notice),
                    ),
                  if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(error)),
                  if (_failures.count > 0 && !_atKey) _FailuresNote(failures: _failures, phone: _vaultId == null),
                  if (triesLeft != null && triesLeft > 0 && triesLeft <= 3 && !_atKey)
                    AppAlert(severity: AlertSeverity.error, child: Text(context.t('lock.erase.warning', {'left': triesLeft}))),
                  if ((_forgot || _failures.count >= 3) && !_atKey) _ForgotBox(onRecover: _recover, onReset: _confirmWipe),
                  if (_listed.length > 1 && !_atKey)
                    _VaultPicker(
                      ids: _listed,
                      chosen: _vaultId,
                      nameOf: (id) => _vaults.vaultName(id) ?? context.t('vaults.defaultName'),
                      onChoose: _switchVault,
                    ),
                  if (_atKey)
                    Rise(key: const ValueKey('key'), duration: const Duration(milliseconds: 450), child: _keyForm(context))
                  else if (_keyOnly(_vaultId))
                    // "Open another vault" from a vault that opens with its key: the password form, and the way back
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _passwordForm(context, quickAvailable: false, quickLabel: quickLabel),
                        TextButton.icon(
                          onPressed: _phase == _Phase.idle ? () => setState(() => _keyVault = _vaultId) : null,
                          style: TextButton.styleFrom(foregroundColor: b.accentText),
                          icon: const Icon(Icons.key_rounded),
                          label: Text(context.t('lock.key.useKey')),
                        ),
                      ],
                    )
                  else if (_usePassword)
                    Rise(
                      key: const ValueKey('password'),
                      duration: const Duration(milliseconds: 450),
                      child: _passwordForm(context, quickAvailable: quickAvailable, quickLabel: quickLabel),
                    )
                  else
                    Rise(
                      key: const ValueKey('quick'),
                      duration: const Duration(milliseconds: 450),
                      child: _QuickUnlock(
                        phase: _phase,
                        label: quickLabel,
                        onQuick: _quick,
                        onUsePassword: () => setState(() => _usePassword = true),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 13, color: b.faint),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      context.t('lock.footer'),
                      style: TextStyle(fontFamily: fontSans, fontSize: 12, color: b.faint),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _passwordForm(BuildContext context, {required bool quickAvailable, required String quickLabel}) {
    final p = context.palette;
    final b = context.bmc;
    final busy = _phase == _Phase.password || _phase == _Phase.open;
    final canSubmit = _password.text.isNotEmpty && _phase == _Phase.idle;
    final fields = Theme.of(context).inputDecorationTheme;
    // The field is rounder than the others, to match the unlock button inside it
    InputBorder? round(InputBorder? border) =>
        border is OutlineInputBorder ? border.copyWith(borderRadius: BorderRadius.circular(19)) : border;

    // Shown and copied, the password goes through the secret clipboard
    return SecretSelection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          TextField(
            controller: _password,
            focusNode: _focus,
            autofocus: true,
            enabled: !busy,
            obscureText: !_showPassword,
            autocorrect: false,
            enableSuggestions: false,
            // Null, not the empty default: the phone's password manager neither fills nor saves it
            autofillHints: null,
            enableIMEPersonalizedLearning: false,
            contextMenuBuilder: secretTextMenu,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _unlock(),
            style: AppType.body1.copyWith(color: p.text),
            decoration: InputDecoration(
              labelText: context.t('unlock.field.password'),
              contentPadding: const EdgeInsets.fromLTRB(16, 19, 0, 19),
              border: round(fields.border),
              enabledBorder: round(fields.enabledBorder),
              disabledBorder: round(fields.disabledBorder),
              focusedBorder: round(fields.focusedBorder),
              errorBorder: round(fields.errorBorder),
              focusedErrorBorder: round(fields.focusedErrorBorder),
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    RevealPasswordButton(shown: _showPassword, onPressed: () => setState(() => _showPassword = !_showPassword)),
                    IconButton(
                      onPressed: canSubmit ? _unlock : null,
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(46),
                        minimumSize: const Size.square(46),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                        backgroundColor: p.primary,
                        foregroundColor: p.onPrimary,
                        disabledBackgroundColor: b.raised,
                        disabledForegroundColor: b.faint,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: Icon(Icons.arrow_forward_rounded, semanticLabel: context.t('unlock.button')),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_phase == _Phase.password) LinearProgressIndicator(semanticsLabel: context.t('unlock.loading')),
          if (quickAvailable)
            TextButton.icon(
              onPressed: () => setState(() {
                _usePassword = false;
                _error = null;
              }),
              style: TextButton.styleFrom(foregroundColor: b.accentText),
              icon: const Icon(Icons.face_rounded),
              label: Text(quickLabel),
            ),
          if (!_forgot && _failures.count < 3)
            Center(
              child: TextButton(
                onPressed: () => setState(() => _forgot = true),
                style: smallButtonStyle.merge(TextButton.styleFrom(foregroundColor: p.textSecondary)),
                child: Text(context.t('unlock.error.forgotPassword')),
              ),
            ),
        ],
      ),
    );
  }

  /// The line under the key step's title: what the key is doing while it
  /// is read, else which vault it opens. A hidden vault is not named.
  String _keyStepLine(BuildContext context) {
    if (_phase == _Phase.key) {
      return switch (_reader.stage.value) {
        KeyReadStage.touch => context.t('securityKeys.activity.touch'),
        KeyReadStage.working => context.t('securityKeys.activity.working'),
        KeyReadStage.idle || KeyReadStage.waiting => context.t('securityKeys.wait.title'),
      };
    }
    final vault = _keyVault!;
    // A vault with no name of its own goes unnamed: "My vault vault" says nothing
    final name = _vaults.isListed(vault) ? _vaults.vaultName(vault) : null;
    if (_pending == null) return name == null ? context.t('lock.key.keyOnlyUnnamed') : context.t('lock.key.keyOnly', {'name': name});
    return name == null ? context.t('lock.key.bothHidden') : context.t('lock.key.both', {'name': name});
  }

  /// The key step (`Lock.dc.html`): the key's PIN in the round field, with
  /// the button that starts the read, then the Recovery Kit and the
  /// password form.
  Widget _keyForm(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final reading = _phase == _Phase.key;
    final idle = _phase == _Phase.idle;
    final fields = Theme.of(context).inputDecorationTheme;
    InputBorder? round(InputBorder? border) =>
        border is OutlineInputBorder ? border.copyWith(borderRadius: BorderRadius.circular(19)) : border;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        if (_keyError case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppAlert(severity: AlertSeverity.error, child: Text(error)),
          ),
        TextField(
          controller: _pin,
          focusNode: _pinFocus,
          autofocus: true,
          enabled: idle,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _readKey(),
          style: TextStyle(fontFamily: fontMono, fontSize: 20, letterSpacing: 4, color: p.text),
          decoration: InputDecoration(
            labelText: context.t('lock.key.pin'),
            helperText: _keyAnswered ? ' ' : context.t('lock.key.pinNote'),
            contentPadding: const EdgeInsets.fromLTRB(16, 19, 0, 19),
            border: round(fields.border),
            enabledBorder: round(fields.enabledBorder),
            disabledBorder: round(fields.disabledBorder),
            focusedBorder: round(fields.focusedBorder),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton(
                onPressed: idle ? _readKey : null,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(46),
                  minimumSize: const Size.square(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  backgroundColor: p.primary,
                  foregroundColor: p.onPrimary,
                  disabledBackgroundColor: b.raised,
                  disabledForegroundColor: b.faint,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(Icons.arrow_forward_rounded, semanticLabel: context.t('lock.key.read')),
              ),
            ),
          ),
        ),
        if (reading) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(semanticsLabel: context.t('securityKeys.activity.working')),
          Center(
            child: TextButton(onPressed: () => unawaited(_reader.cancel()), child: Text(context.t('export.cancel'))),
          ),
        ] else ...[
          const SizedBox(height: 10),
          TextButton(
            onPressed: idle ? _recover : null,
            style: TextButton.styleFrom(foregroundColor: b.accentText),
            child: Text(context.t('lock.key.lost')),
          ),
          TextButton(
            onPressed: idle ? _leaveKeyStep : null,
            style: TextButton.styleFrom(foregroundColor: p.textSecondary),
            child: Text(context.t('lock.key.another')),
          ),
        ],
      ],
    );
  }
}

/// How many wrong passwords were typed on the slot on screen since it last
/// opened, when the last was, and what the count doesn't stop.
class _FailuresNote extends ConsumerWidget {
  const _FailuresNote({required this.failures, required this.phone});

  final UnlockFailures failures;

  /// The phone's count, the lock screen listing no vault.
  final bool phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = failuresArgs(failures, now: ref.read(clockProvider)(), locale: Localizations.localeOf(context).toLanguageTag());
    return AppAlert(
      severity: AlertSeverity.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(context.t(phone ? 'lock.failures.phone' : 'lock.failures', args)),
          Text(context.t('lock.failures.limit'), style: AppType.caption),
        ],
      ),
    );
  }
}

/// The way out for a forgotten password: the Recovery Kit, or wiping every
/// vault. An info alert without its icon.
class _ForgotBox extends StatelessWidget {
  const _ForgotBox({required this.onRecover, required this.onReset});

  final VoidCallback onRecover;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: b.accentSoft, borderRadius: BorderRadius.circular(appRadius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('unlock.error.forgotPassword'), style: AppType.body2.copyWith(color: b.accentText)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(style: smallButtonStyle, onPressed: onRecover, child: Text(context.t('recovery.unlock.open'))),
              TextButton(
                style: smallButtonStyle.merge(TextButton.styleFrom(foregroundColor: p.error)),
                onPressed: onReset,
                child: Text(context.t('unlock.error.resetLink')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The listed vaults, as a row of chips to pick one from.
class _VaultPicker extends StatelessWidget {
  const _VaultPicker({required this.ids, required this.chosen, required this.nameOf, required this.onChoose});

  final List<String> ids;
  final String? chosen;
  final String Function(String id) nameOf;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    role: SemanticsRole.radioGroup,
    label: context.t('vaults.lock.choose'),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [for (final id in ids) _VaultChip(label: nameOf(id), selected: id == chosen, onTap: () => onChoose(id))],
    ),
  );
}

/// One vault to pick: filled Azure when chosen, outlined otherwise.
class _VaultChip extends StatelessWidget {
  const _VaultChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final duration = Motion.reduced(context) ? Duration.zero : Motion.colour;
    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: PressScale(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? p.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? p.primary : b.line2),
            ),
            child: Center(
              widthFactor: 1,
              child: AnimatedDefaultTextStyle(
                duration: duration,
                style: TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: selected ? p.onPrimary : p.text),
                child: Text(label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Biometric unlock: the round button with halos spreading from it, or a
/// spinning arc while the prompt is up, and the way back to the password.
class _QuickUnlock extends StatelessWidget {
  const _QuickUnlock({required this.phase, required this.label, required this.onQuick, required this.onUsePassword});

  final _Phase phase;
  final String label;
  final VoidCallback onQuick;
  final VoidCallback onUsePassword;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final idle = phase == _Phase.idle;
    Widget halo(Duration delay) => Positioned.fill(
      child: ExcludeSemantics(
        child: Halo(
          delay: delay,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: b.accentLine, width: 1.5),
            ),
          ),
        ),
      ),
    );
    return Column(
      children: [
        SizedBox.square(
          dimension: 78,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (idle) ...[halo(Duration.zero), halo(const Duration(milliseconds: 1400))],
              if (phase == _Phase.quick)
                Positioned(
                  left: -6,
                  top: -6,
                  width: 90,
                  height: 90,
                  child: SpinningArc(color: p.primary, radius: 43, strokeWidth: 2.5, length: 60),
                ),
              Semantics(
                button: true,
                enabled: idle,
                label: label,
                onTap: idle ? onQuick : null,
                excludeSemantics: true,
                child: PressScale(
                  scale: 0.95,
                  enabled: idle,
                  child: GestureDetector(
                    onTap: idle ? onQuick : null,
                    child: Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        color: p.paper,
                        shape: BoxShape.circle,
                        border: Border.all(color: b.line2),
                        boxShadow: b.shadow,
                      ),
                      child: Icon(Icons.face_rounded, size: 34, color: b.accentText),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ExcludeSemantics(
          child: Text(
            label,
            style: AppType.body2.copyWith(color: p.textSecondary, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 22),
        TextButton(
          onPressed: onUsePassword,
          style: TextButton.styleFrom(foregroundColor: b.accentText),
          child: Text(context.t('unlock.usePassword')),
        ),
      ],
    );
  }
}
