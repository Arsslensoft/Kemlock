/// What the Kemlock Server setup sheet drives: one sign-in attempt, from the
/// typed address to a sealed session and the target the settings keep
/// (add-kemlock-server-sync, task 5.2). It makes the device key and the
/// proofs it signs, [KmSignIn] over them, and keeps the finished sign-in
/// sealed in the open vault. The sheet is a plain view of its steps.
///
/// The master password and the keys derived from it live in [KmSignIn] and
/// are wiped when its sign-in ends; nothing here keeps either.
library;

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../crypto/account/argon2id.dart';
import '../../crypto/account/prf_wrap.dart' show prfEvalInput;
import '../../crypto/bitwarden.dart';
import '../../platform/device_keys.dart';
import 'kemlock/km_account.dart';
import 'kemlock/km_api.dart';
import 'kemlock/km_approvals.dart';
import 'kemlock/km_auth_api.dart';
import 'kemlock/km_dpop.dart';
import 'kemlock/km_host.dart';
import 'kemlock/km_models.dart';
import 'kemlock/km_passkey.dart';
import 'kemlock/km_platform_passkey.dart';
import 'kemlock/km_session.dart';
import 'kemlock/km_signin.dart';
import 'kemlock/km_sso.dart';
import 'kemlock/km_trust.dart';

/// What setup needs beside the vault: OPAQUE and the key derivations (tests give cheap ones), and how this
/// phone names itself to the server.
class KmSetupParts {
  const KmSetupParts({
    required this.opaque,
    required this.deviceName,
    required this.deviceKind,
    this.argon2 = isolateArgon2id,
    this.bitwardenKey = bwMasterKey,
  });

  final KmOpaque opaque;

  /// "Kemlock on Android": the phone's model isn't read, as no plugin gives it.
  final String deviceName;

  /// `kemlock-ios` or `kemlock-android`.
  final String deviceKind;
  final Argon2idRunner argon2;
  final Future<Uint8List> Function(String password, String email, BwKdf kdf) bitwardenKey;
}

/// What setup uses beside the vault; tests put cheap key derivations and a fake OPAQUE in its place.
final kemlockSetupPartsProvider = Provider<KmSetupParts>(
  (ref) => KmSetupParts(
    opaque: OpaqueKmOpaque(),
    deviceName: Platform.isIOS ? 'Kemlock on iPhone' : 'Kemlock on Android',
    deviceKind: Platform.isIOS ? 'kemlock-ios' : 'kemlock-android',
  ),
);

/// "Trust this phone" over the phone's hardware keys; tests put a fake wrapper in its place.
final kemlockTrustProvider = Provider<KmTrust>((ref) => KmTrust(wrapper: DeviceKeysWrapper.forPlatform(ref.watch(deviceKeysProvider))));

/// The tag of the vault's device key. Keys are tagged by vault; the account isn't known before the first
/// sign-in, so a later sign-in of the same vault replaces the key of the one before.
String kmDeviceKeyTag(String vaultId) => 'dpop.$vaultId';

/// One sign-in attempt for the open vault.
class KmSetupFlow {
  KmSetupFlow({
    required this.vaultId,
    required this.values,
    required this.clientFor,
    required this.deviceKeys,
    required this.trust,
    required this.parts,
    required this.browser,
    this.bitwardenDeviceId,
    this.clock = DateTime.now,
  });

  final String vaultId;
  final KmVaultValues values;
  final http.Client Function(String? pin) clientFor;
  final DeviceKeys deviceKeys;
  final KmTrust trust;
  final KmSetupParts parts;
  final KmBrowserAuth browser;

  /// The vault's Vaultwarden device identifier, when it syncs or synced with Vaultwarden on this server, so the
  /// server shows one device for both APIs.
  final String? bitwardenDeviceId;

  final DateTime Function() clock;

  http.Client? _client;
  KmSignIn? _signIn;
  DeviceKeyChoice? _choice;
  Uri? _server;
  String? _pin;
  var _email = '';

  /// The sign-in attempt, once [connect] ran.
  KmSignIn get signIn => _signIn!;
  Uri get server => _server!;
  String get email => _email;

  /// Whether a software key, sealed in the vault, binds the tokens because the phone has no hardware key: the
  /// sheet says so.
  bool get softwareKey => _choice?.software ?? false;

  /// Reads the server's config and the ways [email] has in. Throws an `insecure` [KmError] for a plain http
  /// address and an `address` one for a server that isn't a Kemlock Server, before anything else is sent.
  /// [pin] is the certificate the person compared and trusted, when the system doesn't.
  Future<KmMethods> connect(String address, String email, {String? pin}) async {
    close();
    final url = kmServerUrl(address);
    final client = _client = clientFor(pin);
    final choice = _choice = await createDeviceKey(deviceKeys, kmDeviceKeyTag(vaultId));
    _server = url;
    _pin = pin;
    _email = email.trim();
    final signIn = _signIn = KmSignIn(
      api: KmApi(
        client,
        proofs: KmDpop(choice.key, clock: clock),
        clock: clock,
      ),
      server: url,
      device: KmDeviceInfo(name: parts.deviceName, kind: parts.deviceKind, bitwardenDeviceId: bitwardenDeviceId),
      opaque: parts.opaque,
      deviceKey: choice.reference,
      opaqueSeen: await kmOpaqueSeen(values),
      rememberOpaque: () => kmRememberOpaque(values),
      argon2: parts.argon2,
      bitwardenKey: parts.bitwardenKey,
      clock: clock,
    );
    return signIn.ways(_email);
  }

  /// The master password through OPAQUE.
  Future<KmSignInStep> password(String password) => signIn.password(_email, password);

  /// A code for the second step the server owes.
  Future<KmSignInStep> secondStep(String method, String code) => signIn.secondStep(method, code);

  /// SSO in the system's browser sheet.
  Future<KmSignInStep> sso() => kmSsoSignIn(signIn, browser);

  /// Ends the browser sheet the person cancelled from this sheet.
  Future<void> cancelSso() => browser.cancel();

  /// A passkey or security key, with its PRF when it has one.
  Future<KmSignInStep> passkey(KmPasskeyAsserter asserter) => kmPasskeySignIn(signIn, asserter, _email, prfEvalInput);

  /// Whether to offer the phone's own passkey: the phone's credential provider can be asked (Android 14 and later)
  /// and the server's `assetlinks.json` names this app, which Credential Manager checks itself, so a way in that
  /// can't work isn't shown. Whether the account has a passkey isn't known: the server answers the same for every
  /// email, so [KmMethods.passkey] is always true.
  Future<bool> platformPasskeyOffered(KmMethods methods, KmPlatformPasskeys passkeys) async {
    if (!methods.passkey) return false;
    // A credential provider that doesn't answer within three seconds is taken as none, so it can't hold up
    // signing in
    final info = await passkeys.info().timeout(const Duration(seconds: 3), onTimeout: () => KmPlatformPasskeyInfo.unsupported);
    final package = info.package;
    if (!info.supported || package == null) return false;
    try {
      return assetLinksNameApp(await signIn.api.assetLinks(server, host: _domainHost(signIn.domain)), package);
    } on KmError {
      return false;
    }
  }

  /// A passkey of the phone's credential provider, with its PRF when it has one.
  Future<KmSignInStep> platformPasskey(KmPlatformPasskeys passkeys) => passkey(KmPlatformAsserter(passkeys));

  /// Opens an account that signed in without opening, with this phone's trusted-device key; null when the
  /// phone isn't trusted, or its copy can't be opened, and the person goes on to an approval or the password.
  Future<KmAccount?> openWithTrust(KmSession session) async {
    try {
      return await signIn.openWithTrust(session, trust, kmTrustTag(vaultId, session.userId));
    } on KmTrustUnreadable {
      return null;
    }
  }

  /// Makes the keys of an account that signed in with none (a first single sign-on sign-in made it, or the phone
  /// that did was closed before it enrolled), with this phone's trusted-device copy of the root key, and opens it.
  /// Null when the account has keys, or another device enrolled first: the person goes on with the trusted-device
  /// copy, an approval or the password. The copy is part of the enrolment, so the sheet's "Trust this phone" has
  /// nothing left to do for an account this opens.
  Future<KmAccount?> enrolKeys(KmSignedIn signed) =>
      signIn.enrolKeys(signed.session, trust, kmTrustTag(vaultId, signed.session.userId), newAccount: signed.newAccount);

  /// This phone's own request for approval from another device.
  KmApprovalFlow approval(List<String> words) => KmApprovalFlow(signIn, words: words, clock: clock);

  /// Seals the sign-in and returns the target the settings keep. With [trustPhone], also keeps a copy of the
  /// root key on the server that only this phone's hardware opens; a phone with no hardware key, or a server
  /// that refuses, is left untrusted and the sign-in stands.
  Future<({KemlockTarget target, bool trusted})> finish(KmSession session, KmAccount account, {required bool trustPhone}) async {
    await kmKeepSignIn(values, KmSignedIn(session: session, account: account));
    var trusted = false;
    if (trustPhone) {
      try {
        await signIn.trustThisPhone(session, account, trust, kmTrustTag(vaultId, session.userId));
        trusted = true;
      } on KmTrustUnavailable {
        // No hardware to trust
      } on KmError {
        // Trust is an extra: the sign-in stands without it
      }
    }
    final target = KemlockTarget(
      accountId: session.userId,
      email: _email,
      servers: [KemlockServer(url: server.toString(), role: KemlockServer.home, pin: _pin)],
      deviceId: session.deviceId,
    );
    close();
    return (target: target, trusted: trusted);
  }

  /// Lets go of the attempt: wipes what it holds and closes its client.
  void close() {
    _signIn?.close();
    _signIn = null;
    _client?.close();
    _client = null;
  }
}

/// The host in a config's `domain`, which may be given as a host or as an address.
String? _domainHost(String? domain) {
  if (domain == null || domain.isEmpty) return null;
  final parsed = Uri.tryParse(domain);
  if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) return parsed.host;
  return domain.split('/').first.split(':').first;
}
