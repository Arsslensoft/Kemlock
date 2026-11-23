import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/account/encoding.dart';
import '../features/sync/kemlock/km_device_key.dart';
import '../features/sync/kemlock/km_trust.dart' show KmKeyWrapper, KmTrustUnavailable;

/// Why the phone's hardware key didn't give or keep what was asked of it.
enum DeviceKeyProblem {
  /// The phone has no hardware key to hold it (a simulator, some older phones), or a build without
  /// the native side. The software key takes its place and the sheet says so.
  unavailable,

  /// There is no key under that tag: it was never made, or the phone lost it.
  missing,

  /// The Keychain or the Keystore failed.
  failed,
}

/// The hardware key didn't do what was asked.
class DeviceKeyError implements Exception {
  const DeviceKeyError(this.problem, [this.message]);

  final DeviceKeyProblem problem;
  final String? message;

  @override
  String toString() => 'DeviceKeyError(${problem.name}${message != null ? ': $message' : ''})';
}

/// What a key is for: a P-256 key that signs DPoP proofs, or a key that wraps the trusted-device key
/// (`crypto/account/trusted_device.dart`'s K_td). The same tag may not hold both.
enum DeviceKeyUse { signing, wrapping }

/// A key the phone's hardware made: its public point when it has one, and where it lives.
class DeviceKeyInfo {
  const DeviceKeyInfo({required this.protection, this.point});

  /// One of [DeviceKeyProtection].
  final String protection;

  /// The public point, 65 bytes (0x04, x, y), of a signing key; null for a wrapping key.
  final Uint8List? point;
}

/// The phone's side of the device keys the Kemlock Server session uses: a Secure Enclave P-256 key on
/// iOS (`ios/Runner/DeviceKeyChannel.swift`, accessible after the first unlock, this device only, with
/// no user presence, so a sync needs no prompt) and an Android Keystore key
/// (`android/.../devicekeys/DeviceKeyChannel.kt`, in StrongBox where the phone has one, with no user
/// authentication). The private half never leaves the hardware. Keys are tagged by vault and account, so
/// vaults stay apart.
abstract interface class DeviceKeys {
  /// Whether the phone has a hardware key to hold these.
  Future<bool> hardware();

  /// Makes the key for [tag], replacing any earlier one. Throws a [DeviceKeyError]; `unavailable`
  /// when the phone has no hardware key.
  Future<DeviceKeyInfo> create(String tag, DeviceKeyUse use);

  /// The key under [tag], or null when there is none.
  Future<DeviceKeyInfo?> info(String tag);

  /// An ECDSA P-256 signature over SHA-256 of [message] by the signing key under [tag], DER encoded.
  Future<Uint8List> sign(String tag, Uint8List message);

  /// Wraps [key] under the wrapping key under [tag]: ECIES on iOS, AES-256-GCM on Android. Only this
  /// phone's hardware opens it again.
  Future<Uint8List> wrap(String tag, Uint8List key);

  /// Opens what [wrap] returned.
  Future<Uint8List> unwrap(String tag, Uint8List wrapped);

  /// Deletes the key under [tag], if there is one.
  Future<void> delete(String tag);
}

/// [DeviceKeys] over the app's method channel. A build without the native side, such as the tests', has
/// no hardware key.
class ChannelDeviceKeys implements DeviceKeys {
  const ChannelDeviceKeys();

  static const _channel = MethodChannel('com.kemlock.app/device_keys');

  @override
  Future<bool> hardware() async {
    try {
      return await _channel.invokeMethod<bool>('hardware') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<DeviceKeyInfo> create(String tag, DeviceKeyUse use) async {
    final answer = await _call<Map<Object?, Object?>>('create', {'tag': tag, 'use': use.name});
    final info = _info(answer);
    if (info == null) throw const DeviceKeyError(DeviceKeyProblem.failed, 'The phone gave back no key.');
    return info;
  }

  @override
  Future<DeviceKeyInfo?> info(String tag) async => _info(await _call<Map<Object?, Object?>>('info', {'tag': tag}));

  @override
  Future<Uint8List> sign(String tag, Uint8List message) async {
    final signature = await _call<Uint8List>('sign', {'tag': tag, 'message': message});
    if (signature == null || signature.isEmpty) throw const DeviceKeyError(DeviceKeyProblem.failed, 'The phone gave back no signature.');
    return signature;
  }

  @override
  Future<Uint8List> wrap(String tag, Uint8List key) async {
    final wrapped = await _call<Uint8List>('wrap', {'tag': tag, 'data': key});
    if (wrapped == null || wrapped.isEmpty) throw const DeviceKeyError(DeviceKeyProblem.failed, 'The phone wrapped nothing.');
    return wrapped;
  }

  @override
  Future<Uint8List> unwrap(String tag, Uint8List wrapped) async {
    final key = await _call<Uint8List>('unwrap', {'tag': tag, 'data': wrapped});
    if (key == null) throw const DeviceKeyError(DeviceKeyProblem.failed, 'The phone gave back no key.');
    return key;
  }

  @override
  Future<void> delete(String tag) async {
    try {
      await _channel.invokeMethod<void>('delete', {'tag': tag});
    } on MissingPluginException {
      // No native side: no key to delete.
    } on PlatformException catch (e) {
      throw _error(e);
    }
  }

  DeviceKeyInfo? _info(Map<Object?, Object?>? answer) {
    if (answer == null) return null;
    final protection = answer['protection'];
    if (protection is! String) return null;
    final point = answer['point'];
    return DeviceKeyInfo(protection: protection, point: point is Uint8List && point.isNotEmpty ? point : null);
  }

  Future<T?> _call<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const DeviceKeyError(DeviceKeyProblem.unavailable);
    } on PlatformException catch (e) {
      throw _error(e);
    }
  }

  DeviceKeyError _error(PlatformException e) => switch (e.code) {
    'unavailable' => DeviceKeyError(DeviceKeyProblem.unavailable, e.message),
    'missing' => DeviceKeyError(DeviceKeyProblem.missing, e.message),
    _ => DeviceKeyError(DeviceKeyProblem.failed, e.message),
  };
}

/// The phone's hardware keys for Kemlock Server; tests put a fake in its place.
final deviceKeysProvider = Provider<DeviceKeys>((ref) => const ChannelDeviceKeys());

/// A signing key in the phone's hardware, as a [DeviceKey] that signs DPoP proofs: the private half stays
/// there, and each signature is DER from the hardware, made the 64 raw bytes a JWS carries.
class HardwareDeviceKey implements DeviceKey {
  HardwareDeviceKey(this._keys, this.tag, DeviceKeyInfo info)
    : protection = info.protection,
      publicJwk = p256Jwk(info.point ?? (throw ArgumentError('a signing key has a public point')));

  final DeviceKeys _keys;

  /// The tag the hardware keeps the key under.
  final String tag;

  @override
  final String protection;

  @override
  final Map<String, String> publicJwk;

  @override
  Future<Uint8List> sign(Uint8List message) async => derToRawEs256(await _keys.sign(tag, message));
}

/// A device key and how it is kept.
class DeviceKeyChoice {
  const DeviceKeyChoice(this.key, this.reference);

  final DeviceKey key;

  /// What the sealed session keeps to find the key again: `{protection, tag}` for a hardware key, and for
  /// the software key, which is sealed in the vault with the session, `{protection: software, scalar}`.
  final Map<String, Object?> reference;

  /// Whether the phone has no hardware key and a software one signs instead: the sign-in sheet says so
  /// (`kemlock.deviceKey.software`), as a token bound to it is only as safe as the vault is.
  bool get software => key.protection == DeviceKeyProtection.software;
}

/// Makes the device key for [tag]: in the phone's hardware when it has any, else a software P-256 key
/// (owner decision 6). Any other failure of the hardware is rethrown, not hidden by a weaker key.
Future<DeviceKeyChoice> createDeviceKey(DeviceKeys keys, String tag) async {
  try {
    final info = await keys.create(tag, DeviceKeyUse.signing);
    return DeviceKeyChoice(HardwareDeviceKey(keys, tag, info), {'protection': info.protection, 'tag': tag});
  } on DeviceKeyError catch (e) {
    if (e.problem != DeviceKeyProblem.unavailable) rethrow;
    final key = SoftwareDeviceKey.generate();
    return DeviceKeyChoice(key, {'protection': DeviceKeyProtection.software, 'scalar': b64urlEncode(key.scalar)});
  }
}

/// The device key a session's [reference] names, or null when there is none to find: no reference, a key
/// the phone lost, or a reference this version can't read.
Future<DeviceKeyChoice?> openDeviceKey(DeviceKeys keys, Map<String, Object?>? reference) async {
  if (reference == null) return null;
  if (reference['protection'] == DeviceKeyProtection.software) {
    final scalar = reference['scalar'];
    if (scalar is! String) return null;
    try {
      return DeviceKeyChoice(SoftwareDeviceKey.fromScalar(b64urlDecode(scalar)), reference);
    } on Object {
      return null;
    }
  }
  final tag = reference['tag'];
  if (tag is! String) return null;
  final info = await keys.info(tag);
  if (info == null || info.point == null) return null;
  return DeviceKeyChoice(HardwareDeviceKey(keys, tag, info), reference);
}

/// [DeviceKeys] as the hardware side of "Trust this phone" (`km_trust.dart`): a wrapping key per tag.
class DeviceKeysWrapper implements KmKeyWrapper {
  DeviceKeysWrapper(this._keys, {required this.protection});

  /// The wrapper for the phone this runs on: the Secure Enclave on iOS, the Keystore on Android.
  factory DeviceKeysWrapper.forPlatform(DeviceKeys keys) =>
      DeviceKeysWrapper(keys, protection: Platform.isIOS ? DeviceKeyProtection.secureEnclave : DeviceKeyProtection.keystore);

  final DeviceKeys _keys;

  @override
  final String protection;

  @override
  Future<void> create(String tag) async {
    try {
      await _keys.create(tag, DeviceKeyUse.wrapping);
    } on DeviceKeyError catch (e) {
      if (e.problem == DeviceKeyProblem.unavailable) throw const KmTrustUnavailable();
      rethrow;
    }
  }

  @override
  Future<bool> exists(String tag) async => await _keys.info(tag) != null;

  @override
  Future<Uint8List> wrap(String tag, Uint8List key) => _keys.wrap(tag, key);

  @override
  Future<Uint8List> unwrap(String tag, Uint8List wrapped) => _keys.unwrap(tag, wrapped);

  @override
  Future<void> delete(String tag) => _keys.delete(tag);
}
