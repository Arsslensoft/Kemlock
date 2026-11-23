/// The inbox a passkey made while the vault is locked waits in.
///
/// The passkey provider can't open the vault, so it seals each new passkey
/// to the vault's *inbox key*, a P-256 key pair whose private half is in
/// the vault (`backmycodes_passkey_inbox`) and whose public half the app
/// hands the phone with the autofill copy. One inbox file per passkey:
///
/// ```text
/// {"v": 1, "epk": base64(ephemeral public point, 65 bytes),
///  "nonce": base64(12 bytes), "ct": base64(AES-256-GCM ciphertext || tag)}
/// key = HKDF-SHA-256(ikm = ECDH(ephemeral, inbox key),
///                    salt = epk || inbox public point,
///                    info = "kemlock-passkey-inbox-v1", 32 bytes)
/// plaintext = the passkey record's JSON, see [InboxRecord]
/// ```
///
/// The app opens the files when the vault is next open, adds the passkeys
/// and only then asks the phone to delete them. Swift and Kotlin seal the
/// same way; the fixtures in test/fixtures/passkeys pin it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../crypto/aes_gcm.dart';
import '../../crypto/bytes.dart';
import '../../crypto/p256.dart';
import '../../models/passkey.dart';

/// The HKDF info of an inbox file's key.
const inboxInfo = 'kemlock-passkey-inbox-v1';

/// The inbox file format's version.
const inboxVersion = 1;

/// A passkey as the provider seals it: what the site registered, and its key.
class InboxRecord {
  const InboxRecord({
    required this.credentialId,
    required this.rpId,
    this.rpName,
    required this.userHandle,
    required this.userName,
    this.userDisplayName,
    required this.privateKey,
    required this.createdAt,
  });

  factory InboxRecord.fromJson(Map<String, Object?> json) {
    String text(String key) =>
        json[key] is String && (json[key]! as String).isNotEmpty ? json[key]! as String : throw FormatException('no $key');
    String? optional(String key) => json[key] is String && (json[key]! as String).isNotEmpty ? json[key]! as String : null;
    return InboxRecord(
      credentialId: text('credentialId'),
      rpId: text('rpId'),
      rpName: optional('rpName'),
      userHandle: text('userHandle'),
      userName: json['userName'] is String ? json['userName']! as String : '',
      userDisplayName: optional('userDisplayName'),
      privateKey: text('privateKey'),
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// base64url, no padding.
  final String credentialId;
  final String rpId;
  final String? rpName;

  /// base64url, no padding.
  final String userHandle;
  final String userName;
  final String? userDisplayName;

  /// PKCS#8 DER, base64.
  final String privateKey;

  /// Epoch ms the passkey was made.
  final int createdAt;

  Map<String, Object?> toJson() => {
    'credentialId': credentialId,
    'rpId': rpId,
    'rpName': ?rpName,
    'userHandle': userHandle,
    'userName': userName,
    'userDisplayName': ?userDisplayName,
    'privateKey': privateKey,
    'createdAt': createdAt,
  };

  /// The passkey the vault keeps, under the new [id].
  Passkey toPasskey(String id) => Passkey(
    id: id,
    credentialId: credentialId,
    rpId: rpId,
    rpName: rpName,
    userHandle: userHandle,
    userName: userName,
    userDisplayName: userDisplayName,
    privateKey: privateKey,
    addedAt: createdAt,
  );
}

/// An inbox file that doesn't open with the inbox key, or holds no record.
class InboxFileError implements Exception {
  const InboxFileError(this.reason);

  final String reason;

  @override
  String toString() => 'InboxFileError: $reason';
}

/// HKDF-SHA-256 (RFC 5869) of [ikm], 32 bytes.
Uint8List hkdfSha256(Uint8List ikm, {required Uint8List salt, required Uint8List info, int length = 32}) {
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  final out = BytesBuilder(copy: false);
  var block = <int>[];
  for (var i = 1; out.length < length; i++) {
    block = Hmac(sha256, prk).convert([...block, ...info, i]).bytes;
    out.add(block);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// The AES key of an inbox file whose ephemeral point is [epk], for the inbox key at [recipient].
Uint8List _fileKey(Uint8List shared, Uint8List epk, Uint8List recipient) =>
    hkdfSha256(shared, salt: Uint8List.fromList([...epk, ...recipient]), info: Uint8List.fromList(utf8.encode(inboxInfo)));

/// [record] sealed to the inbox key whose public point is [recipient]. The
/// [ephemeral] key and [nonce] are fresh unless given, as the fixtures do.
Future<String> sealInboxRecord(InboxRecord record, Uint8List recipient, {P256KeyPair? ephemeral, Uint8List? nonce}) async {
  final eph = ephemeral ?? newP256KeyPair();
  final key = _fileKey(p256SharedSecret(eph.d, recipient), eph.point, recipient);
  final sealed = await aesGcmEncrypt(key, utf8.encode(jsonEncode(record.toJson())), nonce: nonce);
  return jsonEncode({'v': inboxVersion, 'epk': b64(eph.point), 'nonce': b64(sealed.nonce), 'ct': b64(sealed.ct)});
}

/// Opens an inbox [file] with the [inbox] key. Throws [InboxFileError] for
/// one that isn't an inbox file of this version, doesn't open, or holds no
/// passkey record.
Future<InboxRecord> openInboxRecord(String file, P256KeyPair inbox) async {
  final Map<String, Object?> json;
  try {
    json = jsonDecode(file) as Map<String, Object?>;
  } catch (_) {
    throw const InboxFileError('not JSON');
  }
  if (json['v'] != inboxVersion) throw const InboxFileError('another version');
  try {
    final epk = unb64(json['epk']! as String);
    final key = _fileKey(p256SharedSecret(inbox.d, epk), epk, inbox.point);
    final plain = await aesGcmDecrypt(key, unb64(json['nonce']! as String), unb64(json['ct']! as String));
    return InboxRecord.fromJson(jsonDecode(utf8.decode(plain)) as Map<String, Object?>);
  } on InboxFileError {
    rethrow;
  } catch (_) {
    throw const InboxFileError('does not open');
  }
}
