/// Logins AutoFill saved, updated or generated while the vault was locked,
/// as they wait in the vault's inbox (openspec: add-passwords, design
/// decision 9).
///
/// The autofill side can't open the vault, so it seals each record to the
/// vault's inbox key, as the passkey provider does a new passkey
/// (`passkey_inbox.dart`), in a file of its own named `login-<uuid>.json`:
///
/// ```text
/// {"v": 1, "kind": "login", "epk": base64(ephemeral public point, 65 bytes),
///  "nonce": base64(12 bytes), "ct": base64(AES-256-GCM ciphertext || tag)}
/// key = HKDF-SHA-256(ikm = ECDH(ephemeral, inbox key),
///                    salt = epk || inbox public point,
///                    info = "kemlock-login-inbox-v1", 32 bytes)
/// plaintext = the record's JSON, see [LoginInboxRecord]
/// ```
///
/// The outer `kind` tells the app which info opens the file before it is
/// opened; a file without it is a passkey. A version before logins tries a
/// login file as a passkey, fails, and leaves it where it is. Kotlin and
/// Swift seal the same way; test/fixtures/passkeys/logins.json pins it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/aes_gcm.dart';
import '../../crypto/bytes.dart';
import '../../crypto/p256.dart';
import '../../models/login.dart';
import '../passkeys/passkey_inbox.dart' show InboxFileError, hkdfSha256, inboxVersion;

/// The HKDF info of a login file's key.
const loginInboxInfo = 'kemlock-login-inbox-v1';

/// The outer `kind` of a login file.
const loginInboxKind = 'login';

/// Whether an inbox [file] says it holds a login record, which only
/// [openLoginRecord] opens; anything else is tried as a passkey.
bool isLoginFile(String file) {
  try {
    final json = jsonDecode(file);
    return json is Map<String, Object?> && json['kind'] == loginInboxKind;
  } catch (_) {
    return false;
  }
}

/// The app a login was saved in, on Android: its package and the SHA-256 of
/// its original signing certificate, in hex, as a remembered pick holds it.
class InboxApp {
  const InboxApp({required this.package, required this.cert});

  factory InboxApp.fromJson(Map<String, Object?> json) => InboxApp(package: json['package']! as String, cert: json['cert']! as String);

  final String package;
  final String cert;

  Map<String, Object?> toJson() => {'package': package, 'cert': cert};
}

/// What waits in the inbox: a login saved or updated after a form was sent
/// ([isGenerated] false), or a password AutoFill generated and filled, kept
/// even if no save follows ([isGenerated] true, with only [password], [site]
/// and [at]).
class LoginInboxRecord {
  const LoginInboxRecord.login({
    required String this.id,
    required String this.name,
    this.username,
    required this.password,
    this.site,
    this.app,
    this.generated = false,
    required this.at,
  }) : isGenerated = false;

  const LoginInboxRecord.generated({required this.password, this.site, required this.at})
    : isGenerated = true,
      id = null,
      name = null,
      username = null,
      app = null,
      generated = true;

  /// Reads a record; throws [FormatException] for one that is neither kind.
  factory LoginInboxRecord.fromJson(Map<String, Object?> json) {
    String text(String key) =>
        json[key] is String && (json[key]! as String).isNotEmpty ? json[key]! as String : throw FormatException('no $key');
    String? optional(String key) => json[key] is String && (json[key]! as String).isNotEmpty ? json[key]! as String : null;
    final at = (json['at'] as num?)?.toInt() ?? 0;
    return switch (json['kind']) {
      'login' => LoginInboxRecord.login(
        id: text('id'),
        name: text('name'),
        username: optional('username'),
        password: text('password'),
        site: optional('site'),
        app: json['app'] is Map<String, Object?> ? InboxApp.fromJson(json['app']! as Map<String, Object?>) : null,
        generated: json['generated'] == true,
        at: at,
      ),
      'generated' => LoginInboxRecord.generated(password: text('password'), site: optional('site'), at: at),
      _ => throw const FormatException('not a login record'),
    };
  }

  final bool isGenerated;

  /// The id the login takes in the vault, so a pick remembered for it on the phone finds it.
  final String? id;
  final String? name;
  final String? username;
  final String password;

  /// The website's host, when it was saved on one.
  final String? site;
  final InboxApp? app;

  /// For a saved login: its password was one AutoFill generated.
  final bool generated;

  /// Epoch ms it was saved or generated.
  final int at;

  /// The record's JSON, in the order Kotlin and Swift write it.
  Map<String, Object?> toJson() => isGenerated
      ? {'kind': 'generated', 'password': password, 'site': ?site, 'at': at}
      : {
          'kind': 'login',
          'id': id,
          'name': name,
          'username': ?username,
          'password': password,
          'site': ?site,
          'app': ?app?.toJson(),
          'generated': generated,
          'at': at,
        };

  /// The login a saved record becomes when no login of the vault is its own.
  Login toLogin() => Login(
    id: id!,
    name: name!,
    username: username,
    password: password,
    websites: site == null ? null : [site!],
    passwordChangedAt: at,
    source: Login.fromAutofill,
    addedAt: at,
  );
}

Uint8List _fileKey(Uint8List shared, Uint8List epk, Uint8List recipient) =>
    hkdfSha256(shared, salt: Uint8List.fromList([...epk, ...recipient]), info: Uint8List.fromList(utf8.encode(loginInboxInfo)));

/// [record] sealed to the inbox key whose public point is [recipient]. The
/// [ephemeral] key and [nonce] are fresh unless given, as the fixtures do.
Future<String> sealLoginRecord(LoginInboxRecord record, Uint8List recipient, {P256KeyPair? ephemeral, Uint8List? nonce}) async {
  final eph = ephemeral ?? newP256KeyPair();
  final key = _fileKey(p256SharedSecret(eph.d, recipient), eph.point, recipient);
  final sealed = await aesGcmEncrypt(key, utf8.encode(jsonEncode(record.toJson())), nonce: nonce);
  return jsonEncode({'v': inboxVersion, 'kind': loginInboxKind, 'epk': b64(eph.point), 'nonce': b64(sealed.nonce), 'ct': b64(sealed.ct)});
}

/// Opens a login [file] with the [inbox] key. Throws [InboxFileError] for one
/// that isn't a login file of this version, doesn't open, or holds no record.
Future<LoginInboxRecord> openLoginRecord(String file, P256KeyPair inbox) async {
  final Map<String, Object?> json;
  try {
    json = jsonDecode(file) as Map<String, Object?>;
  } catch (_) {
    throw const InboxFileError('not JSON');
  }
  if (json['v'] != inboxVersion || json['kind'] != loginInboxKind) throw const InboxFileError('not a login file of this version');
  try {
    final epk = unb64(json['epk']! as String);
    final key = _fileKey(p256SharedSecret(inbox.d, epk), epk, inbox.point);
    final plain = await aesGcmDecrypt(key, unb64(json['nonce']! as String), unb64(json['ct']! as String));
    return LoginInboxRecord.fromJson(jsonDecode(utf8.decode(plain)) as Map<String, Object?>);
  } catch (_) {
    throw const InboxFileError('does not open');
  }
}
