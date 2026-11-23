import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../platform/security_keys.dart';
import '../../security_key/connection.dart';
import '../../security_key/fido/client_pin.dart';
import '../../security_key/fido/ctap.dart';
import '../../security_key/fido/get_info.dart';
import '../../security_key/hmac_secret.dart';
import '../../vault/key_unlock.dart';
import '../settings/auto_lock.dart';

/// Whether the exchange behind opening a vault with a key is proven on
/// iPhone (openspec: add-security-key-unlock, decision 12). An iPhone
/// reaches a FIDO2 key over NFC only and no SDK gives an app `hmac-secret`
/// there, so the change starts with a prototype on a real iPhone and real
/// keys. That prototype has not been run: this stays false, and the two
/// ways of opening that need a key show as not available on iPhone, until
/// its verdict is "iPhone goes ahead".
const iPhoneKeyExchangeProven = false;

/// [iPhoneKeyExchangeProven], for tests to put the other verdict in its place.
final iPhoneKeyExchangeProvider = Provider<bool>((ref) => iPhoneKeyExchangeProven);

/// Whether this phone and build can open a vault with a security key.
enum KeyUnlockAvailability {
  available,

  /// The device can reach no security key that speaks FIDO2: no NFC and no
  /// USB hosting, or an iPad, which gives apps FIDO2 over NFC only and has
  /// no NFC reader.
  noKeyReachable,

  /// An iPhone, before the exchange is proven there.
  notOnIPhoneYet,
}

/// What [capabilities] and the build allow.
KeyUnlockAvailability keyUnlockAvailability(SecurityKeyCapabilities capabilities, {required bool iPhoneProven}) {
  if (capabilities.readsOnRequest) {
    if (!capabilities.nfc) return KeyUnlockAvailability.noKeyReachable;
    return iPhoneProven ? KeyUnlockAvailability.available : KeyUnlockAvailability.notOnIPhoneYet;
  }
  return capabilities.nfc || capabilities.usb ? KeyUnlockAvailability.available : KeyUnlockAvailability.noKeyReachable;
}

/// Why a key gave no secret (decision 7). A [SecurityKeyError], such as
/// the person cancelling or the key leaving, and a [CtapError] for a
/// refusal with no case here, pass through as they are.
sealed class KeyReadError implements Exception {
  const KeyReadError();
}

/// The key cannot give a secret: it has no `hmac-secret`, or no FIDO2 on
/// this link at all.
class KeyCannotGiveSecret extends KeyReadError {
  const KeyCannotGiveSecret();
}

/// The key has neither a PIN nor a fingerprint on it, so it cannot check
/// its owner. It is not enrolled; its PIN is to be set first.
class KeyHasNoPin extends KeyReadError {
  const KeyHasNoPin();
}

/// No PIN was typed, and the key has no fingerprint reader to use instead.
class KeyPinNeeded extends KeyReadError {
  const KeyPinNeeded();
}

/// The PIN is not the key's. [retries] is how many tries the key says are left.
class KeyPinWrong extends KeyReadError {
  const KeyPinWrong(this.retries);

  final int? retries;
}

/// The key has one PIN try left. Nothing was sent: the person is asked
/// first, and the read is run again with `lastTryConfirmed`.
class KeyPinLastTry extends KeyReadError {
  const KeyPinLastTry();
}

/// The key takes no more PINs until it is taken away and presented again.
class KeyPinPaused extends KeyReadError {
  const KeyPinPaused();
}

/// The key has locked its PIN for good. Only a reset, which erases what
/// opens the vault, clears that.
class KeyPinBlocked extends KeyReadError {
  const KeyPinBlocked();
}

/// The key holds none of the vault's credentials: it does not open this vault.
class KeyNotEnrolled extends KeyReadError {
  const KeyNotEnrolled();
}

/// The key already opens this vault, and is not enrolled a second time.
class KeyAlreadyEnrolled extends KeyReadError {
  const KeyAlreadyEnrolled();
}

/// The key gave two different secrets in two reads, or answered without
/// having verified its owner. It is not used.
class KeyNotSteady extends KeyReadError {
  const KeyNotSteady();
}

/// What enrolling made on a key and read from it.
class KeyEnrolment {
  KeyEnrolment({required this.credential, required this.output, required this.pinBound, this.productName});

  final Uint8List credential;

  /// The key's secret for the vault's salt, the same in two reads.
  final Uint8List output;

  /// Whether the key ties that secret to its PIN or fingerprint (decision 6).
  final bool pinBound;

  /// The name the key gives over USB; over NFC it gives none.
  final String? productName;

  /// Clears the secret once it was used.
  void wipe() => output.fillRange(0, output.length, 0);
}

/// What an enrolled key gave.
class KeyOutput {
  KeyOutput({required this.credential, required this.output});

  final Uint8List credential;
  final Uint8List output;

  /// Clears the secret once it was used.
  void wipe() => output.fillRange(0, output.length, 0);
}

/// What the reader is doing, for the screen to say.
enum KeyReadStage {
  idle,

  /// Waiting for a key to be held to the phone or plugged in.
  waiting,

  /// Talking to the key.
  working,

  /// The key waits for a touch.
  touch,
}

/// The texts of iPhone's NFC sheet, in the person's language.
typedef KeyPrompts = ({String nfcMessage, String nfcFailure});

/// Reads a vault's secret from a security key, for the lock screen and the
/// "How this vault opens" sheet: it waits for a key, asks what it supports,
/// trades the PIN for a token and runs the `hmac-secret` exchange. The PIN
/// is typed before the key is asked for, and is cleared, with the token,
/// when the read ends; nothing is kept between reads.
abstract interface class KeyReader {
  /// What the phone can reach a key with.
  Future<SecurityKeyCapabilities> capabilities();

  /// What the reader is doing now.
  ValueListenable<KeyReadStage> get stage;

  /// Whether the system's NFC sheet or USB question covers the app, which
  /// hides it for the key's sake and nothing else.
  bool get coveredBySystem;

  /// Makes the vault's credential on the key presented next and reads its
  /// secret for [salt] twice. [exclude] holds the vault's credentials, so
  /// a key that already opens it is refused. An empty [pin] asks for the
  /// key's own fingerprint reader. [pin] is cleared when this ends.
  Future<KeyEnrolment> enrol({
    required Uint8List pin,
    required Uint8List salt,
    required List<Uint8List> exclude,
    required KeyPrompts prompts,
    bool lastTryConfirmed = false,
  });

  /// Reads the secret the key presented next gives for [salt] with
  /// whichever of the credentials [allow] it holds. [pin] as for [enrol].
  Future<KeyOutput> read({
    required Uint8List pin,
    required Uint8List salt,
    required List<Uint8List> allow,
    required KeyPrompts prompts,
    bool lastTryConfirmed = false,
  });

  /// The person cancels the wait for a key, or the exchange under way.
  Future<void> cancel();
}

/// [KeyReader] over the app's own CTAP2 code.
class CtapKeyReader implements KeyReader {
  CtapKeyReader(this._keys, {this._hold, this._now = DateTime.now});

  final SecurityKeys _keys;
  final void Function() Function()? _hold;
  final DateTime Function() _now;
  final ValueNotifier<KeyReadStage> _stage = ValueNotifier(KeyReadStage.idle);
  SecurityKeyHub? _hub;

  @override
  Future<SecurityKeyCapabilities> capabilities() => _keys.capabilities();

  @override
  ValueListenable<KeyReadStage> get stage => _stage;

  @override
  bool get coveredBySystem => _hub != null && (_hub!.nfcSheetUp || _hub!.askingPermission);

  @override
  Future<void> cancel() async => _hub?.cancel();

  @override
  Future<KeyEnrolment> enrol({
    required Uint8List pin,
    required Uint8List salt,
    required List<Uint8List> exclude,
    required KeyPrompts prompts,
    bool lastTryConfirmed = false,
  }) => _onKey(pin, prompts, lastTryConfirmed, (connection, exchange, token) async {
    final made = await exchange.makeCredential(token: await token(PinPermission.makeCredential), exclude: exclude);
    // The same secret in two separate reads, or the key is not one to lock a vault with.
    final first = await exchange.read(token: await token(PinPermission.getAssertion), allow: [made.id], salt: salt);
    final second = await exchange.read(token: await token(PinPermission.getAssertion), allow: [made.id], salt: salt);
    final steady = sameBytes(first.output, second.output);
    second.output.fillRange(0, second.output.length, 0);
    if (!steady) {
      first.output.fillRange(0, first.output.length, 0);
      throw const KeyNotSteady();
    }
    return KeyEnrolment(
      credential: made.id,
      output: first.output,
      pinBound: tiesSecretToOwner(exchange.info, made),
      productName: connection.device.productName,
    );
  });

  @override
  Future<KeyOutput> read({
    required Uint8List pin,
    required Uint8List salt,
    required List<Uint8List> allow,
    required KeyPrompts prompts,
    bool lastTryConfirmed = false,
  }) => _onKey(pin, prompts, lastTryConfirmed, (connection, exchange, token) async {
    final reading = await exchange.read(token: await token(PinPermission.getAssertion), allow: allow, salt: salt);
    return KeyOutput(credential: reading.credential, output: reading.output);
  });

  /// Waits for a key, checks what it supports and runs [action], which asks
  /// for a token for [pin] before each credential or read: a CTAP 2.1 key
  /// spends a token on the first one it is used for (CTAP 2.1, sections
  /// 6.1.2 and 6.2.2). Clears the PIN and every token whatever happens.
  Future<T> _onKey<T>(
    Uint8List pin,
    KeyPrompts prompts,
    bool lastTryConfirmed,
    Future<T> Function(SecurityKeyConnection connection, HmacSecret exchange, Future<PinToken?> Function(int permission) token) action,
  ) async {
    final tokens = <PinToken>[];
    try {
      final capabilities = await _keys.capabilities();
      return await runOnKey(
        _keys,
        (connection) async {
          connection.onTouchNeeded = (needed) => _stage.value = needed ? KeyReadStage.touch : KeyReadStage.working;
          _stage.value = KeyReadStage.working;
          final fido = await connection.openFido();
          final info = await getInfo(fido);
          final exchange = HmacSecret(fido, info);
          if (!info.fido2 || !exchange.supported) throw const KeyCannotGiveSecret();
          final clientPin = ClientPin(fido, info);
          // The key's count is read and the last try asked about before the first token only: a
          // right PIN puts the count back to the top.
          Future<PinToken?> token(int permission) async {
            final next = await _token(clientPin, info, pin, permission, lastTryConfirmed, countFirst: tokens.isEmpty);
            if (next != null) tokens.add(next);
            return next;
          }

          return action(connection, exchange, token);
        },
        nfcMessage: prompts.nfcMessage,
        nfcFailure: prompts.nfcFailure,
        // An iPhone gives apps FIDO2 over NFC only, so a plugged-in key is not used there.
        viaNfc: capabilities.readsOnRequest,
        hold: _hold,
        now: _now,
        onHub: (hub) {
          _hub = hub;
          hub.onChanged = () {
            if (hub.isWaiting) _stage.value = KeyReadStage.waiting;
          };
        },
      );
    } on FidoUnavailable {
      throw const KeyCannotGiveSecret();
    } on HmacSecretError catch (error) {
      throw switch (error) {
        KeyLacksHmacSecret() => const KeyCannotGiveSecret(),
        CredentialAlreadyOnKey() => const KeyAlreadyEnrolled(),
        NoCredentialOnKey() => const KeyNotEnrolled(),
        KeyDidNotVerifyOwner() || MalformedKeyAnswer() => const KeyNotSteady(),
      };
    } on CtapError catch (error) {
      // A key that wants its PIN after all, or locks it between the count and the exchange
      throw switch (error.status) {
        CtapStatus.pinRequired || CtapStatus.pinNotSet => pin.isEmpty ? const KeyPinNeeded() : const KeyHasNoPin(),
        CtapStatus.pinAuthBlocked => const KeyPinPaused(),
        CtapStatus.pinBlocked => const KeyPinBlocked(),
        _ => error,
      };
    } finally {
      pin.fillRange(0, pin.length, 0);
      for (final token in tokens) {
        token.token.fillRange(0, token.token.length, 0);
      }
      _hub = null;
      _stage.value = KeyReadStage.idle;
    }
  }

  /// The token that says the key checked [pin], or null when the key's own
  /// fingerprint reader is to check its owner. With [countFirst] the key's
  /// count of tries is read first, and nothing is sent at the last one
  /// unless confirmed.
  Future<PinToken?> _token(
    ClientPin clientPin,
    AuthenticatorInfo info,
    Uint8List pin,
    int permissions,
    bool lastTryConfirmed, {
    required bool countFirst,
  }) async {
    final hasFingerprint = info.options['uv'] ?? false;
    if (info.pin != KeyPinState.set) {
      if (pin.isEmpty && hasFingerprint) return null;
      throw const KeyHasNoPin();
    }
    if (pin.isEmpty) {
      if (hasFingerprint) return null;
      throw const KeyPinNeeded();
    }
    if (!clientPin.supported) throw const KeyCannotGiveSecret();
    int? retries;
    if (countFirst) {
      try {
        retries = await clientPin.retries();
      } on CtapError {
        // A key that will not say: the count is learnt at the first wrong PIN.
      }
    }
    if (retries == 0) throw const KeyPinBlocked();
    if (retries == 1 && !lastTryConfirmed) throw const KeyPinLastTry();
    try {
      return await clientPin.token(pin, permissions: permissions, rpId: vaultUnlockRpId);
    } on PinWrong catch (wrong) {
      throw wrong.retries == 0 ? const KeyPinBlocked() : KeyPinWrong(wrong.retries);
    } on PinLockedUntilReconnected {
      throw const KeyPinPaused();
    } on PinBlocked {
      throw const KeyPinBlocked();
    } on PinNotSet {
      throw const KeyHasNoPin();
    } on PinError {
      // The key wants its PIN changed first, or offers no protocol the app knows
      throw const KeyCannotGiveSecret();
    }
  }
}

/// The reader the lock screen and the unlock sheet use. Tests put a fake
/// phone under it, or a reader of their own in its place.
final keyReaderProvider = Provider<KeyReader>(
  (ref) => CtapKeyReader(ref.watch(securityKeysProvider), hold: ref.watch(autoLockHoldsProvider).hold, now: ref.watch(clockProvider)),
);
