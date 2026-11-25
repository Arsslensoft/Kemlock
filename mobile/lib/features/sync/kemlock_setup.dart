/// The setup sheet of Kemlock Server sync (add-kemlock-server-sync, task 5.2),
/// adapted from the design canvas's SignIn sheet to the phone's sheets.
///
/// The steps: the server's address and the email; the ways in the server
/// offers that email (SSO first when the domain uses it, then a security key,
/// then the master password; only SSO where "Require SSO" applies); the second
/// step when the account owes one; trusting a self-signed certificate when the
/// phone doesn't; and, for a sign-in that left the account closed (SSO, or a
/// key without PRF), opening it by an approval from another device or by the
/// master password. An account that SSO just made has no keys: this phone makes
/// them and opens it, with no further step. "Trust this phone" is on by default. The master password
/// is used once and never kept.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/public_suffixes.dart';
import '../../i18n/messages.dart';
import '../../platform/browser_auth.dart';
import '../../platform/device_keys.dart';
import '../../platform/network.dart';
import '../../platform/platform_passkeys.dart';
import '../../platform/push.dart';
import '../../platform/security_keys.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../../vault/vault_providers.dart';
import '../generator/word_list.dart';
import '../security_keys/pin_forms.dart';
import '../settings/auto_lock.dart';
import '../settings/offline_alert.dart';
import '../spaces/space_policies_provider.dart';
import 'kemlock/km_account.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_approvals.dart';
import 'kemlock/km_auth_api.dart';
import 'kemlock/km_models.dart' show KemlockTarget;
import 'kemlock/km_move_end.dart' show kmMoveSourceOf;
import 'kemlock/km_platform_passkey.dart';
import 'kemlock/km_session.dart';
import 'kemlock/km_signin.dart';
import 'kemlock_flow.dart';
import 'kemlock_host_factory.dart';
import 'kemlock_key_step.dart';
import 'kemlock_move_sheet.dart';
import 'sync.dart';
import 'sync_sheet_frame.dart';
import 'sync_store.dart';
import 'vaultwarden/vaultwarden_sheet.dart' show vwCertificateProbeProvider, vwProblemText;
import 'vaultwarden/vw_backend.dart' show keyVaultwardenSession;
import 'vaultwarden/vw_key_step.dart' show VwKeyStatus, vwCanReachKey;
import 'vaultwarden/vw_models.dart' show VwCredentials;

enum _Step { address, ways, secondStep, certificate, open, approval }

/// The words for what stopped a Kemlock Server sign-in. [host] is the server the person typed, which the refused
/// downgrade names.
String kemlockProblemText(BuildContext context, Object error, {String host = ''}) => switch (error) {
  KmSignInError(:final issue, :final detail) => context.t('kemlock.signin.${issue.name}', {'host': host, 'methods': detail ?? ''}),
  KmApprovalError(:final issue) => context.t('kemlock.approval.problem.${issue.name}'),
  KmError(problem: KmProblem.auth) => context.t('kemlock.signin.wrongPassword'),
  KmError(problem: KmProblem.rateLimited) => context.t('kemlock.problem.rateLimited'),
  KmPlatformPasskeyError(code: 'noCredential') => context.t('kemlock.passkey.noCredential'),
  KmPlatformPasskeyError(:final code, :final message) => context.t('kemlock.passkey.failed', {'reason': message ?? code}),
  _ => vwProblemText(context, error),
};

/// Turns Kemlock Server sync on. [top] sits above the first step's fields (the sync sheet's choice of backend).
class KemlockSetup extends ConsumerStatefulWidget {
  const KemlockSetup({super.key, required this.onClose, this.top, this.address, this.email});

  final VoidCallback onClose;
  final Widget? top;

  /// The server and email to start from, when the sign-in is the move from a Vaultwarden on the same server.
  final String? address;
  final String? email;

  @override
  ConsumerState<KemlockSetup> createState() => _KemlockSetupState();
}

class _KemlockSetupState extends ConsumerState<KemlockSetup> {
  var _step = _Step.address;
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _passwordText = TextEditingController();
  final _code = TextEditingController();
  var _busy = false;
  var _deriving = false;
  Object? _error;
  String? _notice;

  KmSetupFlow? _flow;
  KmMethods? _methods;
  String? _untrusted;
  var _trust = true;
  var _inBrowser = false;
  var _platformPasskey = false;

  /// The server answered a sign-in with `sso-required`: SSO is the only way in offered for this email.
  var _ssoOnly = false;
  var _reach = SecurityKeyCapabilities.none;

  KmSecondStep? _second;
  var _method = 'totp';

  /// Whether this phone waits for another device to approve it.
  var _asking = false;
  KmApprovalFlow? _approval;
  String? _phrase;

  KmKeyStep? _keyStep;
  VwKeyStatus? _keyStatus;

  /// Set once signed in to a server that the vault's old sync can move from: the move's sheet takes this one's place.
  KemlockTarget? _moveTarget;

  @override
  void initState() {
    super.initState();
    _server.text = widget.address ?? '';
    _email.text = widget.email ?? '';
    for (final controller in [_server, _email, _passwordText, _code]) {
      controller.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _flow?.close();
    for (final controller in [_server, _email, _passwordText, _code]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _fail(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deriving = false;
        });
      }
    }
  }

  /// Keeps [e] as the error the sheet shows. A server that requires single sign-on for the account says so after
  /// the sign-in's proof, whichever way was tried: the sheet goes back to the ways in and offers SSO only.
  void _fail(Object e) {
    final error = kmSignInFailure(e);
    _error = error;
    if (error is KmSignInError && error.issue == KmSignInIssue.ssoRequired) {
      _ssoOnly = true;
      _step = _Step.ways;
    }
  }

  /// The Vaultwarden device identifier of this vault, when it syncs with Vaultwarden on the server typed.
  Future<String?> _vaultwardenDeviceId() async {
    final target = ref.read(syncProvider).settings?.vaultwarden;
    final session = ref.read(vaultControllerProvider).session;
    if (target == null || session == null || kmHost(target.server) != kmHost(_server.text)) return null;
    final stored = await ref.read(vaultStoreProvider).loadEncryptedValue(keyVaultwardenSession, session);
    return stored is Map<String, Object?> ? VwCredentials.fromJson(stored).deviceId : null;
  }

  Future<KmSetupFlow> _newFlow() async {
    final session = ref.read(vaultControllerProvider).session!;
    return KmSetupFlow(
      vaultId: ref.read(vaultControllerProvider).vault.id,
      values: VaultKmValues(ref.read(vaultStoreProvider), session),
      clientFor: ref.read(kemlockClientFactoryProvider),
      deviceKeys: ref.read(deviceKeysProvider),
      trust: ref.read(kemlockTrustProvider),
      parts: ref.read(kemlockSetupPartsProvider),
      browser: ref.read(browserAuthProvider),
      bitwardenDeviceId: await _vaultwardenDeviceId(),
      clock: ref.read(clockProvider),
    );
  }

  bool get _canConnect => !_busy && _server.text.trim().isNotEmpty && _email.text.trim().isNotEmpty;

  Future<void> _connect({String? pin}) => _run(() async {
    _flow?.close();
    _ssoOnly = false;
    final flow = _flow = await _newFlow();
    final reach = await ref.read(securityKeysProvider).capabilities();
    try {
      final methods = await flow.connect(_server.text, _email.text, pin: pin);
      final platformPasskey = await flow.platformPasskeyOffered(methods, ref.read(platformPasskeysProvider));
      if (!mounted) return;
      setState(() {
        _methods = methods;
        _reach = reach;
        _platformPasskey = platformPasskey;
        _step = _Step.ways;
      });
    } on KmError catch (e) {
      // Only a handshake the phone broke off may be over a self-signed certificate; the probe tells whether
      // the certificate is the cause
      if (e.problem != KmProblem.network || !e.handshakeFailed || pin != null) rethrow;
      final fingerprint = await ref.read(vwCertificateProbeProvider)(kmServerUrl(_server.text));
      if (fingerprint == null || !mounted) rethrow;
      setState(() {
        _untrusted = fingerprint;
        _step = _Step.certificate;
      });
    }
  });

  Future<void> _trustCertificate() async {
    final fingerprint = _untrusted;
    if (fingerprint == null) return;
    await _connect(pin: fingerprint);
  }

  Future<void> _password() => _run(() async {
    setState(() => _deriving = true);
    await _after(await _flow!.password(_passwordText.text));
  });

  Future<void> _sso() => _run(() async {
    setState(() => _inBrowser = true);
    try {
      await _after(await _flow!.sso());
    } finally {
      if (mounted) setState(() => _inBrowser = false);
    }
  });

  Future<void> _securityKey() => _run(() async {
    final clock = ref.read(clockProvider);
    final nfcMessage = context.t('vaultwarden.key.hold.ios');
    final nfcFailure = context.t('securityKeys.nfc.failed');
    final suffixes = await ref.read(publicSuffixListProvider.future);
    if (!mounted) return;
    final step = _keyStep = KmKeyStep(
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
    try {
      await _after(await _flow!.passkey(step));
    } on SecurityKeyCancelled {
      // Nothing was sent to the server: the screen is as it was
    } finally {
      _keyStep = null;
      if (mounted) setState(() => _keyStatus = null);
    }
  });

  Future<void> _platformSignIn() => _run(() async {
    try {
      await _after(await _flow!.platformPasskey(ref.read(platformPasskeysProvider)));
    } on SecurityKeyCancelled {
      // The person closed the picker: the screen is as it was
    }
  });

  Future<void> _secondStep() => _run(() async => _after(await _flow!.secondStep(_method, _code.text.trim())));

  /// Goes on from a sign-in step: a second step is asked for, a signed-in account that opens is finished, and
  /// one that doesn't open is left for an approval or the master password.
  Future<void> _after(KmSignInStep step) async {
    if (!mounted) return;
    switch (step) {
      case final KmSecondStep second:
        final answerable = [
          for (final method in second.methods)
            if (method == 'totp' || method == 'email') method,
        ];
        if (answerable.isEmpty) {
          throw KmSignInError(KmSignInIssue.webVaultOnly, detail: second.methods.followedBy(second.unsupported).join(', '));
        }
        setState(() {
          _second = second;
          _method = answerable.first;
          _code.clear();
          _step = _Step.secondStep;
        });
      case final KmSignedIn signed:
        // An account with no keys yet (SSO made it) is enrolled by this phone, which holds its copy of the root key
        // from then on; any other account opens with the phone's copy, or is left for an approval or the password
        final enrolled = signed.account == null ? await _flow!.enrolKeys(signed) : null;
        final account = signed.account ?? enrolled ?? await _flow!.openWithTrust(signed.session);
        if (account != null) {
          await _finish(signed.session, account, trustPhone: enrolled == null && _trust);
          return;
        }
        if (!mounted) return;
        setState(() {
          _passwordText.clear();
          _step = _Step.open;
        });
    }
  }

  Future<void> _finish(KmSession session, KmAccount account, {bool? trustPhone}) async {
    final done = await _flow!.finish(session, account, trustPhone: trustPhone ?? _trust);
    final vaultSession = ref.read(vaultControllerProvider).session;
    if (vaultSession == null || !mounted) return;
    final store = ref.read(syncProvider.notifier);
    await store.forgetScope(kemlockScope, vaultSession);
    final settings = store.snapshot.settings ?? noSync;
    // A vault whose own entries sync with a Vaultwarden on this server, or with WebDAV, moves them first: the move's
    // sheet asks, and nothing is saved or written until the person confirms it (move-off-vaultwarden-sync, task 8)
    if (kmMoveSourceOf(settings, done.target) != null) {
      if (mounted) {
        setState(() {
          _passwordText.clear();
          _moveTarget = done.target;
        });
      }
      return;
    }
    await store.saveSettings(settings.copyWith(personal: null, kemlock: done.target), vaultSession);
    if (mounted) _passwordText.clear();
  }

  Future<void> _askApproval() => _run(() async {
    final words = await ref.read(wordListProvider.future);
    final approval = _approval = _flow!.approval(words);
    final phrase = await approval.start(_flow!.email);
    if (!mounted) return;
    setState(() {
      _phrase = phrase;
      _asking = true;
      _step = _Step.approval;
    });
    unawaited(_waitForApproval(approval));
  });

  Future<void> _waitForApproval(KmApprovalFlow approval) async {
    try {
      final outcome = await approval.wait();
      if (!mounted) return;
      switch (outcome) {
        case final KmApproved approved:
          final signed = approved.signedIn;
          await _finish(signed.session, signed.account!);
        case KmApprovalDenied():
          setState(() {
            _notice = context.t('kemlock.approval.denied');
            _step = _Step.open;
          });
        case KmApprovalTimedOut():
          setState(() {
            _notice = context.t('kemlock.approval.timedOut');
            _step = _Step.open;
          });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.open;
          _fail(e);
        });
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  void _cancelApproval() => _approval?.cancel();

  void _cancelKey() => unawaited(_keyStep?.cancel());

  void _cancelSso() => unawaited(_flow?.cancelSso());

  @override
  Widget build(BuildContext context) {
    final move = _moveTarget;
    if (move != null) {
      return KemlockMoveSheet(target: move);
    }
    return _setup(context);
  }

  Widget _setup(BuildContext context) => PopScope(
    canPop: !_busy && !_asking,
    // Every step talks to the server, so none is offered while offline mode is on
    child: ref.watch(offlineProvider)
        ? _frame(
            context,
            actions: [
              _cancel(context),
              FilledButton(onPressed: null, child: Text(context.t('kemlock.continue'))),
            ],
            children: [?widget.top, SheetText(context.t('kemlock.setup.body')), OfflineAlert(context.t('sync.offline.setup'))],
          )
        : switch (_step) {
            _Step.address => _addressStep(context),
            _Step.ways => _waysStep(context),
            _Step.secondStep => _secondStepView(context),
            _Step.certificate => _certificateStep(context),
            _Step.open => _openStep(context),
            _Step.approval => _approvalStep(context),
          },
  );

  Widget? get _alert {
    if (_notice case final notice?) return AppAlert(severity: AlertSeverity.info, child: Text(notice));
    final error = _error;
    if (error == null) return null;
    return AppAlert(
      severity: AlertSeverity.error,
      child: Text(kemlockProblemText(context, error, host: kmHost(_server.text))),
    );
  }

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
    icon: const Icon(Icons.cloud_sync_outlined),
    title: context.t('sync.title'),
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

  Widget _addressStep(BuildContext context) => _frame(
    context,
    actions: [
      _cancel(context),
      FilledButton(onPressed: _canConnect ? _connect : null, child: Text(context.t('kemlock.continue'))),
    ],
    children: [
      ?widget.top,
      SheetText(context.t('kemlock.setup.body')),
      ?_alert,
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: _server,
        enabled: !_busy,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: context.t('kemlock.field.server'),
          hintText: 'https://kemlock.example.com',
          helperText: context.t('kemlock.field.serverHelper'),
          helperMaxLines: 2,
        ),
      ),
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: _email,
        enabled: !_busy,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _canConnect ? _connect() : null,
        decoration: InputDecoration(labelText: context.t('kemlock.field.email')),
      ),
      if (_busy) _progress(),
    ],
  );

  /// The ways in, as the server lists them for the email: SSO first, then a security key, then the password.
  /// Where "Require SSO" applies, SSO is all there is.
  Widget _waysStep(BuildContext context) {
    final methods = _methods!;
    final flow = _flow!;
    final sso = methods.sso || _ssoOnly;
    // "Require SSO" is read from the chains this phone verified, for a Member of the space (an Owner or an Admin keeps
    // every way in), or from a refusal the server made after the person proved who they are. The server's own flag among
    // the ways in is no policy and is never read. A chain was read for the account the vault was signed in as, so it holds
    // only for the email that account signed in with: signing in as someone else isn't held to it.
    final email = _email.text;
    final only = sso && (ref.watch(spacePoliciesProvider.select((policies) => policies.requiresSsoFor(email))) || _ssoOnly);
    final key = !only && methods.passkey && vwCanReachKey(_reach);
    final password = !only && methods.password;
    final platform = !only && _platformPasskey;
    final nothing = !sso && !key && !platform && !password;
    final status = _keyStatus;
    return _frame(
      context,
      leading: _back(context, _Step.address),
      actions: [
        _cancel(context),
        if (password)
          FilledButton(onPressed: !_busy && _passwordText.text.isNotEmpty ? _password : null, child: Text(context.t('kemlock.signIn'))),
      ],
      children: [
        Text(context.t('kemlock.ways.title'), style: AppType.h6),
        ?_alert,
        if (flow.softwareKey) AppAlert(severity: AlertSeverity.info, child: Text(context.t('kemlock.deviceKey.software'))),
        if (nothing) AppAlert(severity: AlertSeverity.warning, child: Text(context.t('kemlock.signin.noWay'))),
        if (sso) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _sso,
            icon: const Icon(Icons.badge_outlined, size: 20),
            label: Text(
              methods.ssoProvider == null || methods.ssoProvider!.isEmpty
                  ? context.t('kemlock.ways.ssoPlain')
                  : context.t('kemlock.ways.sso', {'provider': methods.ssoProvider!}),
            ),
          ),
          if (_inBrowser)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: _cancelSso, child: Text(context.t('changePw.cancel'))),
            ),
        ],
        if (only) AppAlert(severity: AlertSeverity.info, child: Text(context.t('kemlock.ways.ssoRequired'))),
        if (platform)
          OutlinedButton.icon(
            onPressed: _busy ? null : _platformSignIn,
            icon: const Icon(Icons.fingerprint_rounded, size: 20),
            label: Text(context.t('kemlock.ways.passkey')),
          ),
        if (key) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _securityKey,
            icon: const Icon(Icons.nfc_rounded, size: 20),
            label: Text(context.t('kemlock.ways.key')),
          ),
          if (status != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.t(status == VwKeyStatus.touch ? 'vaultwarden.key.status.touch' : 'vaultwarden.key.status.waiting'),
                    style: AppType.body2.copyWith(color: context.bmc.accentText),
                  ),
                ),
                TextButton(onPressed: _cancelKey, child: Text(context.t('changePw.cancel'))),
              ],
            ),
        ],
        if (password) ...[
          if (sso || key || platform) SheetText(context.t('kemlock.ways.password')),
          TextField(
            enableIMEPersonalizedLearning: false,
            controller: _passwordText,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => !_busy && _passwordText.text.isNotEmpty ? _password() : null,
            decoration: InputDecoration(
              labelText: context.t('kemlock.field.password'),
              helperText: context.t('kemlock.field.passwordHelper'),
              helperMaxLines: 3,
            ),
          ),
        ],
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: _trust,
          onChanged: _busy ? null : (on) => setState(() => _trust = on),
          title: Text(context.t('kemlock.ways.trust')),
          subtitle: Text(context.t('kemlock.ways.trustHint')),
        ),
        Text(
          context.t(ref.read(pushTokensProvider).choosesDistributor ? 'kemlock.push.unifiedpush.hint' : 'kemlock.push.hint'),
          style: AppType.caption.copyWith(color: context.palette.textSecondary),
        ),
        if (_busy) _progress(),
      ],
    );
  }

  Widget _secondStepView(BuildContext context) {
    final second = _second!;
    final methods = [
      for (final method in second.methods)
        if (method == 'totp' || method == 'email') method,
    ];
    return _frame(
      context,
      leading: _back(context, _Step.ways),
      actions: [
        _cancel(context),
        FilledButton(onPressed: !_busy && _code.text.trim().isNotEmpty ? _secondStep : null, child: Text(context.t('kemlock.continue'))),
      ],
      children: [
        Text(context.t('kemlock.step.title'), style: AppType.h6),
        ?_alert,
        if (methods.length > 1)
          SegmentedControl<String>(
            semanticLabel: context.t('kemlock.step.method'),
            value: _method,
            onChanged: (value) {
              if (_busy) return;
              setState(() {
                _method = value;
                _code.clear();
                _error = null;
              });
            },
            options: [
              for (final method in methods)
                SegmentOption(value: method, label: context.t(method == 'email' ? 'kemlock.step.email' : 'kemlock.step.totp')),
            ],
          ),
        TextField(
          enableIMEPersonalizedLearning: false,
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => !_busy && _code.text.trim().isNotEmpty ? _secondStep() : null,
          decoration: InputDecoration(labelText: context.t('kemlock.step.code')),
        ),
        if (_busy) _progress(),
      ],
    );
  }

  Widget _certificateStep(BuildContext context) => _frame(
    context,
    leading: _back(context, _Step.address),
    actions: [
      _cancel(context),
      FilledButton(onPressed: _busy ? null : _trustCertificate, child: Text(context.t('vaultwarden.cert.trust'))),
    ],
    children: [
      Text(context.t('vaultwarden.cert.title'), style: AppType.h6),
      SheetText(context.t('vaultwarden.cert.body')),
      AppAlert(severity: AlertSeverity.warning, child: Text(context.t('vaultwarden.cert.warning'))),
      ?_alert,
      SelectableText(_untrusted ?? '', style: AppType.mono(fontSize: 13, color: context.palette.text)),
      if (_busy) _progress(),
    ],
  );

  /// Signed in, with the account still closed: an approval from another device, or the master password.
  Widget _openStep(BuildContext context) => _frame(
    context,
    actions: [
      _cancel(context),
      FilledButton(onPressed: !_busy && _passwordText.text.isNotEmpty ? _password : null, child: Text(context.t('kemlock.open.password'))),
    ],
    children: [
      Text(context.t('kemlock.open.title'), style: AppType.h6),
      SheetText(context.t('kemlock.open.body')),
      ?_alert,
      OutlinedButton.icon(
        onPressed: _busy ? null : _askApproval,
        icon: const Icon(Icons.devices_rounded, size: 20),
        label: Text(context.t('kemlock.open.approval')),
      ),
      TextField(
        enableIMEPersonalizedLearning: false,
        controller: _passwordText,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: const [AutofillHints.password],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => !_busy && _passwordText.text.isNotEmpty ? _password() : null,
        decoration: InputDecoration(labelText: context.t('kemlock.field.password')),
      ),
      if (_busy) _progress(),
    ],
  );

  /// Waiting for another device to approve. The five words are computed on this phone from its one-time key, and
  /// the other device shows the same.
  Widget _approvalStep(BuildContext context) => _frame(
    context,
    actions: [TextButton(style: inheritButtonStyle(context), onPressed: _cancelApproval, child: Text(context.t('changePw.cancel')))],
    children: [
      Text(context.t('kemlock.open.approval'), style: AppType.h6),
      Semantics(
        liveRegion: true,
        child: AppAlert(severity: AlertSeverity.info, child: Text(context.t('kemlock.approval.waiting', {'words': _phrase ?? ''}))),
      ),
      const LinearProgressIndicator(),
    ],
  );
}

/// Opens Kemlock Server's sign-in over the Vaultwarden sheet, at [address] with [email] filled in, as the move from a
/// Vaultwarden on the same server starts (the seam of `vw_kemlock_offer.dart`). The move's own sheet follows the
/// sign-in.
Future<void> showKemlockSignInForMove(BuildContext context, {required String address, required String email}) => showAppBottomSheet<void>(
  context,
  label: context.t('kemlock.move.title'),
  builder: (context) => KemlockSetup(address: address, email: email, onClose: () => Navigator.of(context).pop()),
);
