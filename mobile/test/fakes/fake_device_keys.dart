import 'dart:typed_data';

import 'package:kemlock/crypto/aes_gcm.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/platform/device_keys.dart';

/// Stands in for the phone's hardware keys: a P-256 key per signing tag, an AES-256-GCM key per
/// wrapping tag, all in memory. [hasHardware] false answers `unavailable` as a simulator does, and
/// [failNext] makes the next call fail.
class FakeDeviceKeys implements DeviceKeys {
  FakeDeviceKeys({this.hasHardware = true, this.protection = 'secure-enclave'});

  /// What [hardware] answers; false makes [create] throw `unavailable`.
  bool hasHardware;

  /// The `protection` the keys report.
  final String protection;

  /// The signing keys, by tag.
  final Map<String, P256KeyPair> signing = {};

  /// The wrapping keys, by tag.
  final Map<String, Uint8List> wrapping = {};

  /// Every call, in order: `create <tag> <use>`, `sign <tag>`, `wrap <tag>`, `unwrap <tag>`, `delete <tag>`.
  final List<String> calls = [];

  /// The problem the next call throws, once.
  DeviceKeyProblem? failNext;

  void _maybeFail() {
    final problem = failNext;
    failNext = null;
    if (problem != null) throw DeviceKeyError(problem, 'failed on purpose');
  }

  @override
  Future<bool> hardware() async => hasHardware;

  @override
  Future<DeviceKeyInfo> create(String tag, DeviceKeyUse use) async {
    calls.add('create $tag ${use.name}');
    _maybeFail();
    if (!hasHardware) throw const DeviceKeyError(DeviceKeyProblem.unavailable);
    signing.remove(tag);
    wrapping.remove(tag);
    if (use == DeviceKeyUse.signing) {
      final pair = signing[tag] = newP256KeyPair();
      return DeviceKeyInfo(protection: protection, point: pair.point);
    }
    wrapping[tag] = randomBytes(32);
    return DeviceKeyInfo(protection: protection);
  }

  @override
  Future<DeviceKeyInfo?> info(String tag) async {
    _maybeFail();
    final pair = signing[tag];
    if (pair != null) return DeviceKeyInfo(protection: protection, point: pair.point);
    return wrapping.containsKey(tag) ? DeviceKeyInfo(protection: protection) : null;
  }

  @override
  Future<Uint8List> sign(String tag, Uint8List message) async {
    calls.add('sign $tag');
    _maybeFail();
    final pair = signing[tag];
    if (pair == null) throw const DeviceKeyError(DeviceKeyProblem.missing);
    return es256Sign(pair, message);
  }

  @override
  Future<Uint8List> wrap(String tag, Uint8List key) async {
    calls.add('wrap $tag');
    _maybeFail();
    final wrapKey = wrapping[tag];
    if (wrapKey == null) throw const DeviceKeyError(DeviceKeyProblem.missing);
    final sealed = await aesGcmEncrypt(wrapKey, key);
    return concatBytes([sealed.nonce, sealed.ct]);
  }

  @override
  Future<Uint8List> unwrap(String tag, Uint8List wrapped) async {
    calls.add('unwrap $tag');
    _maybeFail();
    final wrapKey = wrapping[tag];
    if (wrapKey == null) throw const DeviceKeyError(DeviceKeyProblem.missing);
    try {
      return await aesGcmDecrypt(wrapKey, wrapped.sublist(0, 12), wrapped.sublist(12));
    } on AesGcmAuthError {
      throw const DeviceKeyError(DeviceKeyProblem.failed, 'does not open');
    }
  }

  @override
  Future<void> delete(String tag) async {
    calls.add('delete $tag');
    signing.remove(tag);
    wrapping.remove(tag);
  }
}
