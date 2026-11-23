/// The sync sheet's Vaultwarden parts: setting sync up ([VaultwardenSetup])
/// and what the sheet shows once it's on ([VaultwardenOn]).
///
/// Setup goes: the server, email and master password (or a personal API
/// key); the second step, when the account has one; trusting a self-signed
/// certificate, when the phone doesn't; how Vaultwarden keeps the codes,
/// sealed or plain; where, in a home found in the vault or a new one, with
/// the sealing passphrase or the plain storage's acknowledgement; and what
/// the first sync will do, before anything is written. The master password
/// is used once and never kept.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ids.dart';
import '../../../core/providers.dart';
import '../../../core/public_suffixes.dart';
import '../../../i18n/messages.dart';
import '../../../models/otp_account.dart';
import '../../../platform/network.dart';
import '../../../platform/security_keys.dart';
import '../../../security_key/connection.dart';
import '../../../security_key/fido/client_pin.dart';
import '../../../security_key/fido/ctap.dart';
import '../../../security_key/otp_message.dart';
import '../../../ui/ui.dart';
import '../../../vault/vault_controller.dart';
import '../../../vault/vault_providers.dart';
import '../../accounts/otp.dart';
import '../../security_keys/key_widgets.dart';
import '../../security_keys/pin_forms.dart';
import '../../settings/auto_lock.dart';
import '../../settings/offline_alert.dart';
import '../sync.dart';
import '../sync_kdf.dart';
import '../sync_merge.dart';
import '../sync_messages.dart';
import '../sync_sheet_frame.dart';
import '../sync_store.dart';
import 'vw_api.dart';
import 'vw_backend.dart';
import 'vw_codec.dart';
import 'vw_formats.dart';
import 'vw_http.dart';
import 'vw_kemlock_offer.dart';
import 'vw_key_step.dart';
import 'vw_models.dart';
import 'vw_sync.dart';

/// Finds the fingerprint of a certificate the phone doesn't trust, or null.
/// It passes the network gate first, so it throws an `OfflineException`
/// while offline mode is on. Tests override it, as they have no TLS server.
final vwCertificateProbeProvider = Provider<Future<String?> Function(Uri server)>((ref) {
  final gate = ref.watch(networkGateProvider);
  return (server) async {
    gate.check(server);
    return untrustedCertificate(server);
  };
});

/// How setup turns the master password into keys. Widget tests override it
/// with a cheap one, as their fake time can't wait for an isolate.
final vwKeyDerivationProvider = Provider<VwKeyDerivation>((ref) => const VwKeyDerivation());

/// The words for what went wrong talking to Vaultwarden during setup.
String vwProblemText(BuildContext context, Object error) => switch (error) {
  VwError(:final problem) => switch (problem) {
    VwProblem.insecure => context.t('sync.problem.insecure'),
    VwProblem.address => context.t('sync.problem.address'),
    VwProblem.auth => context.t('vaultwarden.problem.auth'),
    VwProblem.code => context.t('vaultwarden.problem.code'),
    VwProblem.signedOut => context.t('sync.problem.signedOut'),
    VwProblem.outOfDate => context.t('sync.problem.conflict'),
    VwProblem.network => context.t('vaultwarden.problem.network'),
    VwProblem.unsupported => context.t('sync.problem.unsupported'),
    VwProblem.server => context.t('vaultwarden.problem.server'),
  },
  VwPassphraseError() => context.t('vaultwarden.error.passphrase'),
  VwKeyStepError(:final problem, :final rpId) => context.t('vaultwarden.key.${problem.name}', {'host': rpId ?? ''}),
  VwKeyRefused(:final rpId) => context.t('vaultwarden.key.refused', {'host': rpId}),
  SecurityKeyError() || PinError() || CtapError() => keyErrorText(context, error) ?? '',
  _ => problemText(context, problemOf(error)),
};

/// The button that cancels the wait for a security key, beside the
/// sheet's own Cancel.
const vwKeyCancelKey = Key('vaultwarden-key-cancel');

/// A YubiKey held to the phone gave no one-time password.
class _NoOtp implements Exception {
  const _NoOtp();
}

/// The key answered and the server refused its answer. [rpId] is the name
/// the server asked the key about.
class VwKeyRefused implements Exception {
  const VwKeyRefused(this.rpId);

  final String rpId;

  @override
  String toString() => 'VwKeyRefused($rpId)';
}

/// "3 accounts, 2 keys and 1 note": [counts] by kind, the ones above zero,
/// in the order of the kinds.
String vwCounts(BuildContext context, Map<EntryKind, int> counts) {
  final parts = [
    for (final kind in EntryKind.values)
      if ((counts[kind] ?? 0) > 0) context.t(_countMessage(kind), {'count': counts[kind]}),
  ];
  return switch (parts) {
    [] => '',
    [final one] => one,
    [final first, final second] => context.t('vaultwarden.summary.and', {'first': first, 'second': second}),
    _ => context.t('vaultwarden.summary.list', {'items': parts.sublist(0, parts.length - 1).join(', '), 'last': parts.last}),
  };
}

String _countMessage(EntryKind kind) => switch (kind) {
  EntryKind.account => 'vaultwarden.summary.accounts',
  EntryKind.backupService => 'vaultwarden.summary.services',
  EntryKind.key => 'vaultwarden.summary.keys',
  EntryKind.note => 'vaultwarden.summary.notes',
  EntryKind.passkey => 'vaultwarden.summary.passkeys',
  EntryKind.contact => 'vaultwarden.summary.contacts',
};

/// What a plain home is waiting to be agreed to write: how many keys, notes,
/// contacts
/// and passkeys, and that every app signed in to [email] reads them.
class _ConsentAlert extends StatelessWidget {
  const _ConsentAlert({required this.paused, required this.email});

  final Map<EntryKind, int> paused;
  final String email;

  @override
  Widget build(BuildContext context) => AppAlert(
    severity: AlertSeverity.warning,
    child: Text(
      '${context.t('vaultwarden.consent.waiting', {'what': vwCounts(context, paused)})} '
      '${context.t('vaultwarden.consent.body', {'email': email})}'
      // The keys are public; whose keys the person keeps is not
      '${paused.containsKey(EntryKind.contact) ? ' ${context.t('vaultwarden.consent.contacts')}' : ''}',
    ),
  );
}

/// The entries too long for the server's notes, by name: they stay on the
/// phone and in its other backups.
class _TooLongAlert extends ConsumerWidget {
  const _TooLongAlert({required this.ids});

  final List<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(vaultControllerProvider).lists;
    final names = <String, String>{
      for (final account in lists.accounts) account.id: account.issuer.isNotEmpty ? account.issuer : account.label,
      for (final key in lists.keys) key.id: key.name,
      for (final note in lists.notes) note.id: note.title,
      for (final passkey in lists.passkeys) passkey.id: passkey.displayName,
      for (final contact in lists.contacts) contact.id: contact.name,
    };
    final named = [
      for (final id in ids)
        if (names[id] case final name? when name.trim().isNotEmpty) name,
    ];
    return AppAlert(severity: AlertSeverity.warning, child: Text(context.t('vaultwarden.tooLong', {'names': named.join(', ')})));
  }
}

/// The word for a storage, as status lines put it: "sealed", "plain".
String vwModeWord(BuildContext context, VaultwardenMode mode) => context.t('vaultwarden.mode.${mode.name}');

/// A backend for the open vault, for one action of the sheet.
VaultwardenBackend _backend(WidgetRef ref) => VaultwardenBackend(
  vault: ref.read(vaultStoreProvider),
  session: ref.read(vaultControllerProvider).session!,
  clientFor: ref.read(vwClientFactoryProvider),
  clock: ref.read(clockProvider),
);

enum _Step { signIn, secondStep, certificate, storage, home, summary }

/// Turns Vaultwarden sync on. [top] sits above the first step's fields
/// (the sync sheet's WebDAV-or-Vaultwarden choice). With [again], only signs
/// in again to that target's account, and stores the new session.
class VaultwardenSetup extends ConsumerStatefulWidget {
  const VaultwardenSetup({super.key, required this.onClose, this.top, this.again});

  final VoidCallback onClose;
  final Widget? top;
  final VaultwardenTarget? again;

  @override
  ConsumerState<VaultwardenSetup> createState() => _VaultwardenSetupState();
}

class _VaultwardenSetupState extends ConsumerState<VaultwardenSetup> {
  var _step = _Step.signIn;
  late final _server = TextEditingController(text: widget.again?.server ?? '');
  late final _email = TextEditingController(text: widget.again?.email ?? '');
  final _password = TextEditingController();
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _code = TextEditingController();
  final _passphrase = TextEditingController();
  var _apiKey = false;
  var _busy = false;
  var _deriving = false;
  Object? _error;

  late String? _pin = widget.again?.pin;
  String? _untrusted;
  VwAccountSetup? _setup;
  String? _deviceId;
  String? _rememberToken;
  VwSignInNeedsStep? _needs;
  int? _provider;
  var _remember = true;
  var _emailSent = false;

  /// What this phone can reach a security key with; read before signing in.
  var _reach = SecurityKeyCapabilities.none;
  VwKeyStep? _keyStep;

  /// What the security key step waits on, while it talks to a key.
  VwKeyStatus? _keyStatus;

  /// What reads a YubiKey's one-time password over NFC, while it waits.
  SecurityKeyHub? _otpHub;

  /// Whether a try already reached a key with the challenge in [_needs].
  var _keyChallengeSpent = false;

  /// The name the server expects security keys at, when it is not the one typed.
  String? _useAddress;
  VwCredentials? _credentials;
  VwVaultInfo? _vault;
  var _mode = VaultwardenMode.sealed;
  var _agreed = false;
  VwHomeInfo? _home;
  var _pickUp = false;
  VaultwardenTarget? _joined;
  VwSyncPreview? _preview;

  /// Whether the user agreed, in the summary, to have the keys, notes and
  /// passkeys it counts written plain.
  var _consent = false;

  @override
  void initState() {
    super.initState();
    for (final controller in [_server, _email, _password, _clientId, _clientSecret, _code, _passphrase]) {
      controller.addListener(() => setState(() {}));
    }
    unawaited(_loadDevice());
  }

  @override
  void dispose() {
    for (final controller in [_server, _email, _password, _clientId, _clientSecret, _code, _passphrase]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The vault's device id and remember token, kept from an earlier sign-in.
  Future<void> _loadDevice() async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    final backend = _backend(ref);
    final stored = await backend.loadCredentials();
    if (!mounted) return;
    _deviceId = stored?.deviceId;
    _rememberToken = stored?.rememberToken;
  }

  /// A setup for the server typed, told whether this phone can reach a
  /// security key, which decides whether one is offered as the second step.
  Future<VwAccountSetup> _newSetup() async {
    final reach = await ref.read(securityKeysProvider).capabilities();
    if (mounted) setState(() => _reach = reach);
    return VwAccountSetup(
      VwApi(ref.read(vwClientFactoryProvider)(_pin), clock: ref.read(clockProvider), info: ref.read(vwClientInfoProvider)),
      clock: ref.read(clockProvider),
      derive: ref.read(vwKeyDerivationProvider),
    )..canReachKey = vwCanReachKey(reach);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deriving = false;
        });
      }
    }
  }

  bool get _canSignIn =>
      !_busy &&
      _server.text.trim().isNotEmpty &&
      _email.text.trim().isNotEmpty &&
      _password.text.isNotEmpty &&
      (!_apiKey || (_clientId.text.trim().isNotEmpty && _clientSecret.text.trim().isNotEmpty));

  Future<void> _signIn() => _run(() async {
    final setup = _setup = await _newSetup();
    try {
      await setup.connect(_server.text, _email.text);
    } on VwError catch (e) {
      // Only a handshake the phone broke off may be over a self-signed certificate; no other failure
      // is a reason to offer trusting one, and the probe tells whether the certificate is the cause
      if (e.problem != VwProblem.network || !e.handshakeFailed) rethrow;
      final fingerprint = await ref.read(vwCertificateProbeProvider)(vwServerUrl(_server.text));
      if (fingerprint == null || !mounted) rethrow;
      setState(() {
        _untrusted = fingerprint;
        _step = _Step.certificate;
      });
      return;
    }
    await _signInWith(setup);
  });

  Future<void> _signInWith(VwAccountSetup setup, {VwSecondStep? step}) async {
    final deviceId = _deviceId ??= newUuid();
    setState(() => _deriving = true);
    final result = _apiKey
        ? await setup.signInWithApiKey(_clientId.text, _clientSecret.text, _password.text, deviceId: deviceId)
        : await setup.signIn(_password.text, deviceId: deviceId, step: step, rememberToken: _rememberToken);
    if (!mounted) return;
    switch (result) {
      case VwSignInNeedsStep():
        setState(() {
          _needs = result;
          _provider = result.supported.firstOrNull;
          _keyChallengeSpent = false;
          _step = _Step.secondStep;
        });
      case VwSignInDone(:final credentials):
        await _signedIn(setup, credentials);
    }
  }

  Future<void> _signedIn(VwAccountSetup setup, VwCredentials credentials) async {
    if (widget.again != null) {
      // Signing in again: keep the session and sync with it
      await _backend(ref).saveCredentials(credentials);
      ref.read(syncProvider.notifier).requestSync();
      widget.onClose();
      return;
    }
    final vault = await setup.readVault(setup.connection(credentials));
    if (!mounted) return;
    setState(() {
      _credentials = credentials;
      _vault = vault;
      _password.clear();
      _step = _Step.storage;
    });
  }

  Future<void> _trust() => _run(() async {
    setState(() => _pin = _untrusted);
    final setup = _setup = await _newSetup();
    await setup.connect(_server.text, _email.text);
    setState(() => _step = _Step.signIn);
    await _signInWith(setup);
  });

  Future<void> _sendEmail() => _run(() async {
    await _setup!.sendEmailCode();
    if (mounted) setState(() => _emailSent = true);
  });

  Future<void> _secondStep() => _run(() async {
    final provider = _provider;
    if (provider == null) return;
    await _signInWith(
      _setup!,
      step: VwSecondStep(provider: provider, code: _code.text, remember: _remember),
    );
  });

  /// The security key step: a challenge the server still keeps, the key's
  /// answer to it, and the sign-in with that answer. Each try that reached
  /// a key uses its challenge up, so the next one fetches another, with
  /// the master key already derived.
  Future<void> _useKey() => _run(() async {
    final setup = _setup!;
    final clock = ref.read(clockProvider);
    final nfcMessage = context.t('vaultwarden.key.hold.ios');
    final nfcFailure = context.t('securityKeys.nfc.failed');
    setState(() {
      _useAddress = null;
      _keyStatus = VwKeyStatus.waiting;
    });
    try {
      var challenge = _needs?.keyChallenge;
      if (challenge == null || _keyChallengeSpent || !challenge.isFresh(clock())) {
        final again = await setup.askStepAgain(_password.text, deviceId: _deviceId ??= newUuid(), rememberToken: _rememberToken);
        if (!mounted) return;
        switch (again) {
          case VwSignInDone(:final credentials):
            await _signedIn(setup, credentials);
            return;
          case VwSignInNeedsStep():
            challenge = again.keyChallenge;
            setState(() {
              _needs = again;
              _keyChallengeSpent = false;
              // The server no longer offers a key: back to what it does offer
              if (!again.supported.contains(VwTwoFactor.webauthn)) _provider = again.supported.firstOrNull;
            });
            if (challenge == null || _provider != VwTwoFactor.webauthn) return;
        }
      }
      // Which parent domain of the address the server may name for the key; the host alone without the list
      final suffixes = await ref.read(publicSuffixListProvider.future);
      if (!mounted) return;
      final rpId = challenge.rpId;
      final step = _keyStep = VwKeyStep(
        keys: ref.read(securityKeysProvider),
        hold: ref.read(autoLockHoldsProvider).hold,
        nfcMessage: nfcMessage,
        nfcFailure: nfcFailure,
        now: clock,
        suffixes: suffixes,
        onStatus: (status) {
          if (mounted) setState(() => _keyStatus = status);
        },
        askPin: (wrong) async => mounted ? showKeyPinPromptFor(context, body: context.t('vaultwarden.key.pin'), wrong: wrong) : null,
      );
      final String token;
      try {
        token = await step.answer(challenge, setup.server);
      } on SecurityKeyCancelled {
        // Nothing was sent to the server: the screen is as it was
        _keyChallengeSpent = true;
        return;
      } on VwKeyStepError catch (e) {
        // A challenge for another site never reached a key, and stays good
        if (e.problem == VwKeyProblem.otherAddress) {
          _offerAddress(rpId);
        } else {
          _keyChallengeSpent = true;
        }
        rethrow;
      } catch (_) {
        _keyChallengeSpent = true;
        rethrow;
      }
      _keyChallengeSpent = true;
      if (!mounted) return;
      setState(() => _keyStatus = null);
      try {
        await _signInWith(
          setup,
          step: VwSecondStep(provider: VwTwoFactor.webauthn, code: token, remember: _remember),
        );
      } on VwError catch (e) {
        if (e.problem != VwProblem.code) rethrow;
        // The key answered and the server refused: most often it is set up under another address
        _offerAddress(rpId);
        throw VwKeyRefused(rpId);
      }
    } finally {
      _keyStep = null;
      if (mounted) setState(() => _keyStatus = null);
    }
  });

  /// Offers to sign in at [rpId], the name the server gave, when that is
  /// not the host typed. Signing in again keeps its target's address.
  void _offerAddress(String rpId) {
    if (widget.again != null || !mounted) return;
    final host = Uri.tryParse(_server.text.trim())?.host.toLowerCase();
    if (host != rpId) setState(() => _useAddress = rpId);
  }

  /// Goes back to the sign-in step with the server field set to [host].
  void _signInAt(String host) => setState(() {
    _server.text = 'https://$host';
    _useAddress = null;
    _error = null;
    _step = _Step.signIn;
  });

  /// Fills the code field with the one-time password a YubiKey held to the
  /// phone gives over NFC. A key that gives none is said to, and the field
  /// is left as it was.
  Future<void> _readOtp() => _run(() async {
    final nfcMessage = context.t('vaultwarden.key.hold.ios');
    final nfcFailure = context.t('securityKeys.nfc.failed');
    final noCode = context.t('vaultwarden.step.yubikeyNoCode');
    setState(() => _keyStatus = VwKeyStatus.waiting);
    try {
      final code = await runOnKey(
        ref.read(securityKeysProvider),
        // No code ends iPhone's NFC sheet with a cross, not a tick
        (connection) async => await readOtpMessage(connection) ?? (throw const _NoOtp()),
        viaNfc: true,
        nfcMessage: nfcMessage,
        nfcFailure: nfcFailure,
        hold: ref.read(autoLockHoldsProvider).hold,
        onHub: (hub) => _otpHub = hub,
        now: ref.read(clockProvider),
      );
      if (mounted) _code.text = code;
    } on _NoOtp {
      if (mounted) setState(() => _error = noCode);
    } on SecurityKeyCancelled {
      // Nothing to say: the field is as it was
    } finally {
      _otpHub = null;
      if (mounted) setState(() => _keyStatus = null);
    }
  });

  /// The person cancels the wait for a key, or the exchange with it.
  void _cancelKey() {
    unawaited(_keyStep?.cancel());
    unawaited(_otpHub?.cancel());
  }

  List<VwHomeInfo> get _homes => [
    for (final home in _vault?.homes ?? const <VwHomeInfo>[])
      if (home.home.mode == _mode) home,
  ];

  bool get _canReview {
    if (_busy) return false;
    if (_mode == VaultwardenMode.plain) return _agreed;
    return _passphrase.text.isNotEmpty;
  }

  /// Works out what the first sync will do, after joining the home chosen
  /// (which checks a sealed home's passphrase), and shows it.
  Future<void> _review() async {
    if (_mode == VaultwardenMode.sealed && _home == null && _passphrase.text.length < 8) {
      setState(() => _error = context.t('sync.error.shortPassphrase'));
      return;
    }
    await _run(() async {
      final setup = _setup!;
      final home = _home;
      final joined = home == null
          ? null
          : await setup.joinHome(
              home,
              passphrase: _mode == VaultwardenMode.sealed ? _passphrase.text : null,
              derive: ref.read(syncDeriveKeyProvider),
              pickUp: _pickUp,
              pin: _pin,
            );
      final preview = await setup.previewFirstSync(
        setup.connection(_credentials!),
        scopeLists(ref.read(vaultControllerProvider).lists, null),
        target: joined,
        mode: _mode,
        pickUp: _pickUp,
      );
      if (!mounted) return;
      setState(() {
        _joined = joined;
        _preview = preview;
        _step = _Step.summary;
      });
    });
  }

  Future<void> _turnOn() => _run(() async {
    final setup = _setup!;
    final credentials = _credentials!;
    final target =
        _joined ??
        await setup.createHome(
          setup.connection(credentials),
          mode: _mode,
          passphrase: _mode == VaultwardenMode.sealed ? _passphrase.text : null,
          derive: ref.read(syncDeriveKeyProvider),
          pickUp: _pickUp,
          pin: _pin,
        );
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    await _backend(ref).saveCredentials(credentials);
    final store = ref.read(syncProvider.notifier);
    await store.forgetScope(vaultwardenScope, session);
    final settings = store.snapshot.settings ?? noSync;
    if (settings.personal != null) await store.forgetScope(personalScope, session);
    final paused = _preview?.paused.keys ?? const <EntryKind>[];
    final agreed = _consent && _mode == VaultwardenMode.plain
        ? target.copyWith(plainKinds: {...target.plainKinds, for (final kind in paused) kind.name})
        : target;
    await store.saveSettings(settings.copyWith(personal: null, vaultwarden: agreed), session);
    if (mounted) _passphrase.clear();
  });

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    // Every step talks to the server, so none is offered while offline mode is on
    child: ref.watch(offlineProvider)
        ? _pausedStep(context)
        : switch (_step) {
            _Step.signIn => _signInStep(context),
            _Step.secondStep => _secondStepView(context),
            _Step.certificate => _certificateStep(context),
            _Step.storage => _storageStep(context),
            _Step.home => _homeStep(context),
            _Step.summary => _summaryStep(context),
          },
  );

  Widget? get _errorAlert => switch (_error) {
    null => null,
    final String text => AppAlert(severity: AlertSeverity.error, child: Text(text)),
    final error => AppAlert(severity: AlertSeverity.error, child: Text(vwProblemText(context, error))),
  };

  Widget _progress() => _deriving
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            const LinearProgressIndicator(),
            Text(context.t('vaultwarden.deriving'), style: AppType.caption.copyWith(color: context.palette.textSecondary)),
          ],
        )
      : const LinearProgressIndicator();

  Widget _frame(BuildContext context, {required List<Widget> children, required List<Widget> actions, Widget? leading}) => SyncSheetFrame(
    icon: const Icon(Icons.shield_outlined),
    title: context.t('vaultwarden.title'),
    leading: leading,
    actions: actions,
    children: children,
  );

  Widget _cancel(BuildContext context) =>
      TextButton(style: inheritButtonStyle(context), onPressed: _busy ? null : widget.onClose, child: Text(context.t('changePw.cancel')));

  Widget _back(BuildContext context, _Step to) => TextButton(
    style: inheritButtonStyle(context),
    onPressed: _busy ? null : () => setState(() => _step = to),
    child: Text(context.t('vaultwarden.back')),
  );

  Widget _pausedStep(BuildContext context) => _frame(
    context,
    actions: [
      _cancel(context),
      FilledButton(onPressed: null, child: Text(context.t('vaultwarden.signIn'))),
    ],
    children: [?widget.top, SheetText(context.t('vaultwarden.body')), OfflineAlert(context.t('sync.offline.setup'))],
  );

  Widget _signInStep(BuildContext context) => _frame(
    context,
    actions: [
      _cancel(context),
      FilledButton(onPressed: _canSignIn ? _signIn : null, child: Text(context.t('vaultwarden.signIn'))),
    ],
    children: [
      ?widget.top,
      SheetText(context.t('vaultwarden.body')),
      ?_errorAlert,
      AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _server,
              enabled: !_busy && widget.again == null,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.url],
              decoration: InputDecoration(
                labelText: context.t('vaultwarden.field.server'),
                hintText: 'https://vault.example.com',
                helperText: context.t('vaultwarden.field.serverHelper'),
                helperMaxLines: 2,
              ),
            ),
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _email,
              enabled: !_busy && widget.again == null,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(labelText: context.t('vaultwarden.field.email')),
            ),
            if (_apiKey) ...[
              TextField(
                enableIMEPersonalizedLearning: false,
                controller: _clientId,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: context.t('vaultwarden.field.clientId')),
              ),
              TextField(
                enableIMEPersonalizedLearning: false,
                controller: _clientSecret,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: context.t('vaultwarden.field.clientSecret'),
                  helperText: context.t('vaultwarden.apiKey.helper'),
                  helperMaxLines: 4,
                ),
              ),
            ],
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _canSignIn ? _signIn() : null,
              decoration: InputDecoration(
                labelText: context.t('vaultwarden.field.password'),
                helperText: context.t('vaultwarden.field.passwordHelper'),
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: _busy ? null : () => setState(() => _apiKey = !_apiKey),
          child: Text(context.t(_apiKey ? 'vaultwarden.apiKey.back' : 'vaultwarden.apiKey.use')),
        ),
      ),
      if (_busy) _progress(),
    ],
  );

  /// An account in this vault whose code is likely the server's own second
  /// step: its issuer or label names the server's host, Vaultwarden or Bitwarden.
  OtpAccount? _serverAccount() {
    final host = Uri.tryParse(_server.text.trim())?.host.toLowerCase() ?? '';
    final words = {if (host.isNotEmpty) host, if (host.isNotEmpty) host.split('.').first, 'vaultwarden', 'bitwarden'};
    for (final account in ref.read(vaultControllerProvider).accounts) {
      if (account.kind == OtpType.hotp || account.spaceId != null) continue;
      final name = '${account.issuer} ${account.label}'.toLowerCase();
      if (words.any(name.contains)) return account;
    }
    return null;
  }

  Widget _secondStepView(BuildContext context) {
    final needs = _needs!;
    final supported = needs.supported;
    final provider = _provider;
    final match = provider == VwTwoFactor.authenticator ? _serverAccount() : null;
    final byKey = provider == VwTwoFactor.webauthn;
    final useAddress = _useAddress;
    // Why a security key the account has is not among the methods, if it is not
    final keyMissing = switch (needs.keyOffer) {
      VwKeyOffer.noReach => context.t('vaultwarden.key.noReach'),
      VwKeyOffer.noChallenge => context.t('vaultwarden.key.noChallenge'),
      _ => null,
    };
    return _frame(
      context,
      leading: _back(context, _Step.signIn),
      actions: [
        _cancel(context),
        if (byKey)
          FilledButton(onPressed: _busy ? null : _useKey, child: Text(context.t('vaultwarden.key.use')))
        else
          FilledButton(
            onPressed: !_busy && provider != null && _code.text.trim().isNotEmpty ? _secondStep : null,
            child: Text(context.t('vaultwarden.continue')),
          ),
      ],
      children: [
        Text(context.t('vaultwarden.step.title'), style: AppType.h6),
        ?_errorAlert,
        if (useAddress != null && _error != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(onPressed: _busy ? null : () => _signInAt(useAddress), child: Text(context.t('vaultwarden.key.useAddress'))),
          ),
        if (supported.isEmpty)
          AppAlert(severity: AlertSeverity.warning, child: Text(keyMissing ?? context.t('vaultwarden.step.unsupported')))
        else ...[
          if (supported.length > 1)
            SegmentedControl<int>(
              semanticLabel: context.t('vaultwarden.step.method'),
              value: provider ?? supported.first,
              onChanged: (value) {
                if (_busy) return;
                setState(() {
                  _provider = value;
                  _code.clear();
                  _error = null;
                  _useAddress = null;
                });
              },
              options: [
                for (final option in supported)
                  SegmentOption(
                    value: option,
                    label: context.t(switch (option) {
                      VwTwoFactor.email => 'vaultwarden.step.email',
                      VwTwoFactor.yubikey => 'vaultwarden.step.yubikey',
                      VwTwoFactor.webauthn => 'vaultwarden.step.securityKey',
                      _ => 'vaultwarden.step.authenticator',
                    }),
                  ),
              ],
            ),
          if (byKey) ...[
            SheetText(context.t(_reach.readsOnRequest ? 'vaultwarden.key.hold.ios' : 'vaultwarden.key.hold.android')),
            _keyStatusLine(context),
          ] else ...[
            if (provider == VwTwoFactor.email)
              Row(
                children: [
                  Expanded(
                    child: SheetText(
                      _emailSent
                          ? context.t('vaultwarden.step.emailSent', {'email': needs.emailHint ?? _email.text})
                          : (needs.emailHint ?? ''),
                    ),
                  ),
                  TextButton(onPressed: _busy ? null : _sendEmail, child: Text(context.t('vaultwarden.step.send'))),
                ],
              ),
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _code,
              enabled: !_busy,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: provider == VwTwoFactor.yubikey ? TextInputType.text : TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _code.text.trim().isNotEmpty ? _secondStep() : null,
              decoration: InputDecoration(
                labelText: context.t('vaultwarden.step.code'),
                helperText: provider == VwTwoFactor.yubikey ? context.t('vaultwarden.step.yubikeyHelper') : null,
              ),
            ),
            if (match != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _code.text = codeAt(match, ref.read(clockProvider)().millisecondsSinceEpoch ~/ 1000),
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: Text(context.t('vaultwarden.step.fromVault', {'name': match.issuer.isNotEmpty ? match.issuer : match.label})),
                ),
              ),
            // A YubiKey gives its one-time password over NFC too
            if (provider == VwTwoFactor.yubikey && _reach.nfc) ...[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _busy ? null : _readOtp,
                  icon: const Icon(Icons.nfc_rounded, size: 18),
                  label: Text(context.t('vaultwarden.step.yubikeyNfc')),
                ),
              ),
              if (_keyStatus != null) _keyStatusLine(context),
            ],
          ],
          _CheckRow(
            value: _remember,
            onChanged: _busy ? null : (value) => setState(() => _remember = value ?? false),
            label: context.t('vaultwarden.step.remember'),
          ),
          // The account has a key too, and it cannot be used here: said, with the other methods still on
          if (keyMissing != null) AppAlert(severity: AlertSeverity.info, child: Text(keyMissing)),
        ],
        if (_busy) _progress(),
      ],
    );
  }

  /// What the security key step waits on, read out as it changes: empty
  /// until the step starts, then "Waiting for your key", "Touch your key"
  /// and "Signing in". While a key is waited on it can be cancelled.
  Widget _keyStatusLine(BuildContext context) {
    final status = _keyStatus;
    final text = switch (status) {
      VwKeyStatus.waiting => context.t('vaultwarden.key.status.waiting'),
      VwKeyStatus.touch => context.t('vaultwarden.key.status.touch'),
      null => _busy ? context.t('vaultwarden.key.status.signingIn') : '',
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: AppType.body2.copyWith(color: context.bmc.accentText)),
          ),
          if (status != null) TextButton(key: vwKeyCancelKey, onPressed: _cancelKey, child: Text(context.t('changePw.cancel'))),
        ],
      ),
    );
  }

  Widget _certificateStep(BuildContext context) => _frame(
    context,
    leading: _back(context, _Step.signIn),
    actions: [
      _cancel(context),
      FilledButton(onPressed: _busy ? null : _trust, child: Text(context.t('vaultwarden.cert.trust'))),
    ],
    children: [
      Text(context.t('vaultwarden.cert.title'), style: AppType.h6),
      SheetText(context.t('vaultwarden.cert.body')),
      AppAlert(severity: AlertSeverity.warning, child: Text(context.t('vaultwarden.cert.warning'))),
      ?_errorAlert,
      SelectableText(_untrusted ?? '', style: AppType.mono(fontSize: 13, color: context.palette.text)),
      if (_busy) _progress(),
    ],
  );

  Widget _storageStep(BuildContext context) => _frame(
    context,
    actions: [
      _cancel(context),
      FilledButton(
        onPressed: _busy || (_mode == VaultwardenMode.plain && !_agreed)
            ? null
            : () => setState(() {
                _home = _homes.firstOrNull;
                _step = _Step.home;
              }),
        child: Text(context.t('vaultwarden.continue')),
      ),
    ],
    children: [
      Text(context.t('vaultwarden.storage.title'), style: AppType.h6),
      _ChoiceCard(
        selected: _mode == VaultwardenMode.sealed,
        title: context.t('vaultwarden.storage.sealed'),
        badge: context.t('vaultwarden.storage.recommended'),
        body: context.t('vaultwarden.storage.sealedBody'),
        onTap: () => setState(() => _mode = VaultwardenMode.sealed),
      ),
      _ChoiceCard(
        selected: _mode == VaultwardenMode.plain,
        title: context.t('vaultwarden.storage.plain'),
        body: context.t('vaultwarden.storage.plainBody'),
        onTap: () => setState(() => _mode = VaultwardenMode.plain),
      ),
      if (_mode == VaultwardenMode.plain)
        _CheckRow(
          value: _agreed,
          onChanged: (value) => setState(() => _agreed = value ?? false),
          label: context.t('vaultwarden.storage.plainAgree'),
        ),
      AppAlert(severity: AlertSeverity.info, child: Text(context.t('vaultwarden.session'))),
      if (_serverAccount() != null) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('vaultwarden.lockout'))),
    ],
  );

  Widget _homeStep(BuildContext context) {
    final homes = _homes;
    final sealed = _mode == VaultwardenMode.sealed;
    final foreign = _vault?.foreignLogins ?? 0;
    return _frame(
      context,
      leading: _back(context, _Step.storage),
      actions: [
        _cancel(context),
        FilledButton(onPressed: _canReview ? _review : null, child: Text(context.t('vaultwarden.continue'))),
      ],
      children: [
        Text(context.t('vaultwarden.home.title'), style: AppType.h6),
        ?_errorAlert,
        for (final home in homes)
          _ChoiceCard(
            selected: _home == home,
            title: context.t('vaultwarden.home.existing', {
              'name': home.home.name.isEmpty ? defaultFolderName : home.home.name,
              'mode': vwModeWord(context, home.home.mode),
              'count': home.entries,
            }),
            onTap: () => setState(() {
              _home = home;
              _error = null;
            }),
          ),
        _ChoiceCard(
          selected: _home == null,
          title: context.t('vaultwarden.home.new'),
          onTap: () => setState(() {
            _home = null;
            _error = null;
          }),
        ),
        if (sealed)
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _passphrase,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: _home == null ? const [AutofillHints.newPassword] : const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: context.t('vaultwarden.field.passphrase'),
              helperText: context.t(_home == null ? 'vaultwarden.field.passphraseNew' : 'vaultwarden.field.passphraseJoin'),
              helperMaxLines: 3,
            ),
          ),
        if (!sealed && foreign > 0)
          _CheckRow(
            value: _pickUp,
            onChanged: _busy ? null : (value) => setState(() => _pickUp = value ?? false),
            label: context.t('vaultwarden.pickUp', {'count': foreign}),
          ),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }

  Widget _summaryStep(BuildContext context) {
    final preview = _preview!;
    return _frame(
      context,
      leading: _back(context, _Step.home),
      actions: [
        _cancel(context),
        FilledButton(onPressed: _busy ? null : _turnOn, child: Text(context.t('vaultwarden.turnOn'))),
      ],
      children: [
        Text(context.t('vaultwarden.summary.title'), style: AppType.h6),
        ?_errorAlert,
        if (preview.isEmpty && preview.paused.isEmpty) SheetText(context.t('vaultwarden.summary.nothing')),
        if (preview.toVault.isNotEmpty)
          _SummaryRow(
            icon: Icons.north_east_rounded,
            text: context.t('vaultwarden.summary.to', {'what': vwCounts(context, preview.toVault)}),
          ),
        if (preview.fromVault.isNotEmpty)
          _SummaryRow(
            icon: Icons.south_west_rounded,
            text: context.t('vaultwarden.summary.from', {'what': vwCounts(context, preview.fromVault)}),
          ),
        if (preview.removedHere > 0)
          _SummaryRow(
            icon: Icons.remove_circle_outline_rounded,
            text: context.t('vaultwarden.summary.removedHere', {'count': preview.removedHere}),
          ),
        if (preview.removedThere > 0)
          _SummaryRow(
            icon: Icons.remove_circle_outline_rounded,
            text: context.t('vaultwarden.summary.removedThere', {'count': preview.removedThere}),
          ),
        if (preview.skipped > 0) SheetText(context.t('vaultwarden.on.skipped', {'count': preview.skipped})),
        const _LoginsStayAlert(),
        const _CardsStayAlert(),
        const _IdentitiesStayAlert(),
        if (preview.paused.isNotEmpty) ...[
          _ConsentAlert(paused: preview.paused, email: _email.text.trim()),
          _CheckRow(
            value: _consent,
            onChanged: _busy ? null : (value) => setState(() => _consent = value ?? false),
            label: context.t('vaultwarden.consent.setup'),
          ),
        ],
        if (preview.tooLong.isNotEmpty) _TooLongAlert(ids: preview.tooLong),
        SheetText(context.t('vaultwarden.summary.hint')),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}

/// How many of the vault's logins Vaultwarden sync leaves on the phone, as
/// it doesn't carry logins yet (openspec: add-passwords); nothing when the
/// vault has none.
class _LoginsStayAlert extends ConsumerWidget {
  const _LoginsStayAlert();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(vaultControllerProvider.select((state) => inScope(state.logins, null).length));
    if (count == 0) return const SizedBox.shrink();
    return AppAlert(severity: AlertSeverity.info, child: Text(context.t('vaultwarden.logins.stay', {'count': count})));
  }
}

/// How many of the vault's cards Vaultwarden sync leaves on the phone, as it
/// doesn't carry cards (the add-cards-identities-and-websites plan); nothing
/// when the vault has none.
class _CardsStayAlert extends ConsumerWidget {
  const _CardsStayAlert();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(vaultControllerProvider.select((state) => inScope(state.cards, null).length));
    if (count == 0) return const SizedBox.shrink();
    return AppAlert(severity: AlertSeverity.info, child: Text(context.t('vaultwarden.cards.stay', {'count': count})));
  }
}

/// The same for the vault's identities.
class _IdentitiesStayAlert extends ConsumerWidget {
  const _IdentitiesStayAlert();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(vaultControllerProvider.select((state) => inScope(state.identities, null).length));
    if (count == 0) return const SizedBox.shrink();
    return AppAlert(severity: AlertSeverity.info, child: Text(context.t('vaultwarden.identities.stay', {'count': count})));
  }
}

/// One line of setup's summary: an icon and what goes where.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 12,
    children: [
      Icon(icon, size: 20, color: context.palette.primary),
      Expanded(
        child: Text(text, style: AppType.body1.copyWith(color: context.palette.text)),
      ),
    ],
  );
}

/// A checkbox and its label, the whole row tappable, with a Material of its
/// own so its ink shows in dialogs too.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.value, required this.onChanged, required this.label});

  final bool value;
  final ValueChanged<bool?>? onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: CheckboxListTile(
      value: value,
      onChanged: onChanged,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: AppType.body2.copyWith(color: context.palette.text)),
    ),
  );
}

/// One choice among a few, as a card: its title (and a badge), what it
/// means, and a check when it's the one chosen.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.selected, required this.title, required this.onTap, this.body, this.badge});

  final bool selected;
  final String title;
  final String? body;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: Material(
        color: selected ? b.accentSoft : b.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? p.primary : p.divider, width: selected ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? p.primary : p.textSecondary,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(title, style: AppType.subtitle1.copyWith(color: p.text, height: 1.35)),
                          if (badge case final badge?)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: p.primary, borderRadius: BorderRadius.circular(8)),
                              child: Text(
                                badge,
                                style: AppType.caption.copyWith(color: p.onPrimary, fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      ),
                      if (body case final body?) Text(body, style: AppType.body2.copyWith(color: p.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the sync sheet shows while the vault syncs with Vaultwarden: where,
/// how the last sync went, what to do about a problem, Sync now, Change
/// storage and Turn off.
class VaultwardenOn extends ConsumerStatefulWidget {
  const VaultwardenOn({super.key, required this.target, required this.onClose});

  final VaultwardenTarget target;
  final VoidCallback onClose;

  @override
  ConsumerState<VaultwardenOn> createState() => _VaultwardenOnState();
}

class _VaultwardenOnState extends ConsumerState<VaultwardenOn> {
  var _signingIn = false;
  var _busy = false;
  Object? _error;
  final _passphrase = TextEditingController();
  var _agreed = false;

  /// The storage the home switched to on another phone, once read.
  VaultwardenMode? _follow;
  HomeNote? _followHome;

  /// What the last sync left to say, read from its state when it changes.
  VwRunReport _report = const VwRunReport();
  int? _reportOf;
  var _reportAsked = false;

  /// What the server offers beside the Bitwarden API: Kemlock's own, to move to. Shown at most once a day.
  KemlockOffer? _offer;

  /// What the server offers a phone whose home another phone closed, read once the sync stops at "home gone": when
  /// it speaks Kemlock's own API, the problem line says the vault moved, with Sign in.
  KemlockOffer? _moved;
  var _movedAsked = false;

  @override
  void initState() {
    super.initState();
    _passphrase.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_readOffer()));
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  VaultwardenTarget get _target => widget.target;

  /// Reads the server's `/api/config` for a `kemlock` member, unless offline mode is on or the offer was shown
  /// today, and shows the offer when there is one (add-kemlock-server-sync, task 12.2). The day it is shown is
  /// kept, so the offer comes back no sooner than the next day, and a server with no offer costs one small
  /// request each time the sheet opens and changes nothing. Not reaching the server shows nothing.
  Future<void> _readOffer() async {
    if (!mounted || ref.read(offlineProvider)) {
      return;
    }
    final now = ref.read(clockProvider)();
    if (!offerDue(_target, now)) {
      return;
    }
    final KemlockOffer? offer;
    try {
      final api = VwApi(
        ref.read(vwClientFactoryProvider)(_target.pin),
        clock: ref.read(clockProvider),
        info: ref.read(vwClientInfoProvider),
      );
      offer = KemlockOffer.fromConfig(await api.config(Uri.parse(_target.server)));
    } on Object {
      return;
    }
    if (!mounted || offer == null) {
      return;
    }
    setState(() => _offer = offer);
    await _save(_target.copyWith(kemlockOfferDay: offerDay(now)));
  }

  /// Reads the server's `/api/config` after a sync stopped because the home is gone (move-off-vaultwarden-sync,
  /// design 11, task 5.2). A server with no Kemlock member, or one that can't be reached, leaves today's problem.
  Future<void> _readMoved() async {
    if (!mounted || ref.read(offlineProvider)) {
      return;
    }
    final KemlockOffer? offer;
    try {
      final api = VwApi(
        ref.read(vwClientFactoryProvider)(_target.pin),
        clock: ref.read(clockProvider),
        info: ref.read(vwClientInfoProvider),
      );
      offer = KemlockOffer.fromConfig(await api.config(Uri.parse(_target.server)));
    } on Object {
      return;
    }
    if (mounted && offer != null) {
      setState(() => _moved = offer);
    }
  }

  /// Hands the move to `move-off-vaultwarden-sync`'s sheet, through [moveOffVaultwardenProvider].
  Future<void> _moveOff() async {
    final offer = _offer;
    if (offer == null) {
      return;
    }
    await ref.read(moveOffVaultwardenProvider)(context, _target, offer);
  }

  /// Reads what the sync that ended [at] left to say.
  Future<void> _readReport(int? at) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    final states = await ref.read(syncProvider.notifier).loadScopeStates(session);
    final report = VwRunReport.fromState(states[vaultwardenScope]?.extra ?? const {});
    if (mounted && _reportOf == at) setState(() => _report = report);
  }

  /// Agrees to the kinds the last sync held back, and syncs them.
  Future<void> _agree() => _run((backend) async {
    await _save(_target.copyWith(plainKinds: {..._target.plainKinds, for (final kind in _report.paused.keys) kind.name}));
    ref.read(syncProvider.notifier).requestSync();
  });

  Future<void> _run(Future<void> Function(VaultwardenBackend backend) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final backend = _backend(ref);
    try {
      await action(backend);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      backend.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(VaultwardenTarget next) async {
    final session = ref.read(vaultControllerProvider).session;
    if (session == null) return;
    final store = ref.read(syncProvider.notifier);
    await store.saveSettings((store.snapshot.settings ?? noSync).copyWith(vaultwarden: next), session);
  }

  /// Reads how the home keeps its entries now, to follow another phone.
  Future<void> _readHome() => _run((backend) async {
    final connection = await backend.connect(_target);
    final read = await VwReader(connection.credentials.key).read(await connection.ciphers());
    final home = read.homes.where((claim) => claim.home.id == _target.home && !claim.cipher.inTrash).firstOrNull;
    if (home == null) throw const VwSyncError(VwSyncIssue.homeMissing);
    if (mounted) {
      setState(() {
        _followHome = home.home;
        _follow = home.home.mode;
      });
    }
  });

  Future<void> _followMode() => _run((backend) async {
    final home = _followHome!;
    var next = _target.copyWith(mode: home.mode);
    if (home.mode == VaultwardenMode.sealed) {
      next = next.copyWith(seal: await VwAccountSetup.openSeal(home, _passphrase.text, ref.read(syncDeriveKeyProvider)));
    }
    await _save(next);
    if (mounted) {
      setState(() {
        _follow = null;
        _followHome = null;
        _passphrase.clear();
      });
    }
  });

  /// The passphrase again, when the home was sealed again elsewhere.
  Future<void> _reseal() => _run((backend) async {
    final connection = await backend.connect(_target);
    final read = await VwReader(connection.credentials.key).read(await connection.ciphers());
    final home = read.homes.where((claim) => claim.home.id == _target.home).firstOrNull;
    if (home == null) throw const VwSyncError(VwSyncIssue.homeMissing);
    await _save(_target.copyWith(seal: await VwAccountSetup.openSeal(home.home, _passphrase.text, ref.read(syncDeriveKeyProvider))));
    if (mounted) _passphrase.clear();
  });

  Future<void> _changeStorage() async {
    final toPlain = _target.mode == VaultwardenMode.sealed;
    // The new passphrase going sealed, or '' going plain; null when cancelled
    final passphrase = await showAppDialog<String>(context, builder: (context) => _ChangeStorageDialog(toPlain: toPlain));
    if (passphrase == null || !mounted) return;
    await _run((backend) async {
      final connection = await backend.connect(_target);
      final next = await VwAccountSetup.changeMode(
        connection,
        _target,
        toPlain ? VaultwardenMode.plain : VaultwardenMode.sealed,
        passphrase: toPlain ? null : passphrase,
        derive: ref.read(syncDeriveKeyProvider),
      );
      await _save(next);
    });
  }

  Future<void> _turnOff() async {
    final choice = await showAppDialog<bool>(context, builder: (context) => const _TurnOffDialog());
    if (choice == null || !mounted) return;
    await _run((backend) async {
      if (choice) {
        await VwAccountSetup.removeFromVault(await backend.connect(_target), _target);
      }
      final session = ref.read(vaultControllerProvider).session;
      if (session == null) return;
      final store = ref.read(syncProvider.notifier);
      await store.saveSettings((store.snapshot.settings ?? noSync).copyWith(vaultwarden: null), session);
      await store.forgetScope(vaultwardenScope, session);
      backend.forgetAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_signingIn) {
      return VaultwardenSetup(again: _target, onClose: () => setState(() => _signingIn = false));
    }
    final p = context.palette;
    // Paused: the last sync's result stays, and nothing that would contact the server is offered
    final offline = ref.watch(offlineProvider);
    final sync = ref.watch(syncProvider);
    final status = sync.status[vaultwardenScope];
    final problem = status?.problem;
    final at = status?.lastSyncAt;
    if (!_reportAsked || _reportOf != at) {
      _reportAsked = true;
      _reportOf = at;
      unawaited(Future(() => _readReport(at)));
    }
    if (problem == SyncProblem.homeMissing && !_movedAsked && !offline) {
      _movedAsked = true;
      unawaited(Future(_readMoved));
    }
    final report = _report;
    final waiting = _target.mode == VaultwardenMode.plain
        ? {
            for (final MapEntry(:key, :value) in report.paused.entries)
              if (!_target.plainKinds.contains(key.name)) key: value,
          }
        : const <EntryKind, int>{};
    return PopScope(
      canPop: !_busy,
      child: SyncSheetFrame(
        icon: const Icon(Icons.shield_outlined),
        title: context.t('vaultwarden.title'),
        leading: TextButton(
          style: TextButton.styleFrom(foregroundColor: p.error),
          onPressed: _busy || offline ? null : _turnOff,
          child: Text(context.t('sync.off')),
        ),
        actions: [
          TextButton.icon(
            onPressed: sync.running || _busy || offline ? null : ref.read(syncProvider.notifier).requestSync,
            icon: const Icon(Icons.sync_rounded, size: 20),
            label: Text(context.t('sync.now')),
          ),
          FilledButton(onPressed: _busy ? null : widget.onClose, child: Text(context.t('export.close'))),
        ],
        children: [
          SheetText(
            context.t('vaultwarden.on.body', {
              'host': vwHost(_target.server),
              'email': _target.email,
              'mode': vwModeWord(context, _target.mode),
            }),
          ),
          if (offline) OfflineAlert(context.t('sync.offline')),
          if (!offline && _offer != null) _MoveOffer(onMove: _busy ? null : _moveOff, onLater: () => setState(() => _offer = null)),
          Semantics(
            liveRegion: true,
            child: AppAlert(
              severity: problem != null ? AlertSeverity.error : AlertSeverity.success,
              child: Text(
                problem == SyncProblem.homeMissing && _moved != null ? context.t('vaultwarden.moved.title') : statusText(context, status),
              ),
            ),
          ),
          if (problem == null && (status?.count ?? 0) > 0)
            AppAlert(severity: AlertSeverity.warning, child: Text(context.t('vaultwarden.on.skipped', {'count': status!.count}))),
          const _LoginsStayAlert(),
          const _CardsStayAlert(),
          const _IdentitiesStayAlert(),
          if (!offline && problem == null && waiting.isNotEmpty) ...[
            _ConsentAlert(paused: waiting, email: _target.email),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(onPressed: _busy ? null : _agree, child: Text(context.t('vaultwarden.consent.agree'))),
            ),
          ],
          if (problem == null && report.tooLong.isNotEmpty) _TooLongAlert(ids: report.tooLong),
          if (report.noFiles case final reason? when problem == null)
            AppAlert(
              severity: AlertSeverity.info,
              child: Text(
                context.t(switch (reason) {
                  VwFilesRefusal.none => 'vaultwarden.noFiles.none',
                  VwFilesRefusal.elsewhere => 'vaultwarden.noFiles.elsewhere',
                }),
              ),
            ),
          if (_error case final error?) AppAlert(severity: AlertSeverity.error, child: Text(vwProblemText(context, error))),
          if (!offline) ..._problemActions(context, problem, status?.count ?? 0),
          if (sync.running || _busy) LinearProgressIndicator(semanticsLabel: context.t('sync.running')),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy || offline || problem == SyncProblem.modeChanged ? null : _changeStorage,
              icon: const Icon(Icons.swap_horiz_rounded, size: 20),
              label: Text(context.t('vaultwarden.change')),
            ),
          ),
          Text(context.t('vaultwarden.on.hint'), style: AppType.caption.copyWith(color: p.textSecondary)),
        ],
      ),
    );
  }

  List<Widget> _problemActions(BuildContext context, SyncProblem? problem, int count) {
    final store = ref.read(syncProvider.notifier);
    switch (problem) {
      case SyncProblem.homeMissing:
        final moved = _moved;
        if (moved == null) {
          return const [];
        }
        return [
          SheetText(context.t('vaultwarden.moved.body')),
          FilledButton.tonal(
            onPressed: _busy ? null : () => unawaited(ref.read(moveOffVaultwardenProvider)(context, _target, moved)),
            child: Text(context.t('vaultwarden.moved.signIn')),
          ),
        ];
      case SyncProblem.signedOut:
        return [
          FilledButton.tonal(
            onPressed: _busy ? null : () => setState(() => _signingIn = true),
            child: Text(context.t('vaultwarden.signInAgain')),
          ),
        ];
      case SyncProblem.removals:
        return [
          SheetText(context.t('vaultwarden.removals.body', {'count': count})),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () => store.decideRemovals(RemovalChoice.keep),
                child: Text(context.t('vaultwarden.removals.keep')),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: context.palette.error),
                onPressed: () => store.decideRemovals(RemovalChoice.remove),
                child: Text(context.t('vaultwarden.removals.remove')),
              ),
            ],
          ),
        ];
      case SyncProblem.modeChanged:
        final follow = _follow;
        if (follow == null) {
          return [FilledButton.tonal(onPressed: _busy ? null : _readHome, child: Text(context.t('vaultwarden.follow')))];
        }
        return [
          SheetText(context.t(follow == VaultwardenMode.plain ? 'vaultwarden.storage.plainBody' : 'vaultwarden.storage.sealedBody')),
          if (follow == VaultwardenMode.plain)
            _CheckRow(
              value: _agreed,
              onChanged: (value) => setState(() => _agreed = value ?? false),
              label: context.t('vaultwarden.storage.plainAgree'),
            )
          else
            _passphraseField(context, join: true),
          FilledButton.tonal(
            onPressed: _busy || (follow == VaultwardenMode.plain ? !_agreed : _passphrase.text.isEmpty) ? null : _followMode,
            child: Text(context.t('vaultwarden.follow')),
          ),
        ];
      case SyncProblem.key:
        return [
          _passphraseField(context, join: true),
          FilledButton.tonal(onPressed: _busy || _passphrase.text.isEmpty ? null : _reseal, child: Text(context.t('vaultwarden.continue'))),
        ];
      default:
        return const [];
    }
  }

  Widget _passphraseField(BuildContext context, {required bool join}) => TextField(
    enableIMEPersonalizedLearning: false,
    controller: _passphrase,
    enabled: !_busy,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(
      labelText: context.t('vaultwarden.field.passphrase'),
      helperText: context.t(join ? 'vaultwarden.field.passphraseJoin' : 'vaultwarden.field.passphraseNew'),
      helperMaxLines: 3,
    ),
  );
}

/// Asks before changing the storage: plain needs the acknowledgement,
/// sealed a new passphrase. Pops the passphrase (empty going plain) to go
/// ahead, or null.
class _ChangeStorageDialog extends StatefulWidget {
  const _ChangeStorageDialog({required this.toPlain});

  final bool toPlain;

  @override
  State<_ChangeStorageDialog> createState() => _ChangeStorageDialogState();
}

class _ChangeStorageDialogState extends State<_ChangeStorageDialog> {
  var _agreed = false;
  final _passphrase = TextEditingController();

  @override
  void initState() {
    super.initState();
    _passphrase.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ready = widget.toPlain ? _agreed : _passphrase.text.length >= 8;
    return AppDialog(
      semanticLabel: context.t('vaultwarden.change'),
      heading: DialogHeading(title: context.t('vaultwarden.change'), tone: DialogTone.accent),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(
            context.t(widget.toPlain ? 'vaultwarden.change.toPlain' : 'vaultwarden.change.toSealed'),
            style: AppType.body2.copyWith(color: p.textSecondary),
          ),
          if (widget.toPlain)
            _CheckRow(
              value: _agreed,
              onChanged: (value) => setState(() => _agreed = value ?? false),
              label: context.t('vaultwarden.storage.plainAgree'),
            )
          else
            TextField(
              enableIMEPersonalizedLearning: false,
              controller: _passphrase,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: context.t('vaultwarden.field.passphrase'),
                helperText: context.t('vaultwarden.field.passphraseNew'),
                helperMaxLines: 3,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('changePw.cancel')),
        ),
        FilledButton(
          onPressed: ready ? () => Navigator.of(context).pop(widget.toPlain ? '' : _passphrase.text) : null,
          child: Text(context.t('vaultwarden.change.confirm')),
        ),
      ],
    );
  }
}

/// Asks how to turn Vaultwarden sync off: pops false to keep everything in
/// Vaultwarden, true to take Kemlock out of it, null to cancel.
class _TurnOffDialog extends StatelessWidget {
  const _TurnOffDialog();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppDialog(
      semanticLabel: context.t('vaultwarden.off.title'),
      heading: DialogHeading(title: context.t('vaultwarden.off.title'), tone: DialogTone.danger),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(context.t('vaultwarden.off.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
          Text(context.t('vaultwarden.off.removeBody'), style: AppType.caption.copyWith(color: p.textSecondary)),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.text),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('changePw.cancel')),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: p.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.t('vaultwarden.off.remove')),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('vaultwarden.off.keep'))),
      ],
    );
  }
}

/// "This server also speaks Kemlock's own API", with Move and Not now. Not now only hides it: the day it was shown
/// is already kept, so it stays hidden until a later day.
class _MoveOffer extends StatelessWidget {
  const _MoveOffer({required this.onMove, required this.onLater});

  final VoidCallback? onMove;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AppAlert(
        severity: AlertSeverity.info,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('vaultwarden.moveOffer.title'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(context.t('vaultwarden.moveOffer.body')),
          ],
        ),
      ),
      Row(
        children: [
          FilledButton.tonal(onPressed: onMove, child: Text(context.t('vaultwarden.moveOffer.move'))),
          const SizedBox(width: 8),
          TextButton(onPressed: onLater, child: Text(context.t('vaultwarden.moveOffer.later'))),
        ],
      ),
    ],
  );
}
