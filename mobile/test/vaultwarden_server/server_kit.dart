// A real Vaultwarden for the tests in this folder, which only run when
// VAULTWARDEN_URL is set, e.g.
//
//   VAULTWARDEN_URL=https://localhost:8443 VAULTWARDEN_PIN=AB:CD:… \
//     flutter test test/vaultwarden_server
//
// VAULTWARDEN_PIN is the SHA-256 fingerprint of a self-signed certificate.
// The server needs SIGNUPS_ALLOWED=true and SIGNUPS_VERIFY=false: each run
// registers new accounts through the same routes the Bitwarden clients use.
// Raise its rate limits too (LOGIN_RATELIMIT_* and
// UNAUTHENTICATED_RATELIMIT_*, say a burst of 1000 a second), or a few runs
// in a row get "Too many requests". Set its DOMAIN to VAULTWARDEN_URL itself,
// or the security key tests' answers come from another origin.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_http.dart';

/// The server's address, or null when these tests should be skipped.
Uri? get serverUrl => switch (Platform.environment['VAULTWARDEN_URL']) {
  final url? when url.isNotEmpty => vwServerUrl(url),
  _ => null,
};

/// Why these tests are skipped, or null when they run.
String? get skipServer => serverUrl == null ? 'Set VAULTWARDEN_URL to run against a real Vaultwarden' : null;

String? get serverPin => Platform.environment['VAULTWARDEN_PIN'];

/// A client for the server, pinning its certificate when one is given.
http.Client serverClient() => vwHttpClient(pin: serverPin);

/// An account registered on the server for one test.
class TestAccount {
  TestAccount({required this.email, required this.password, required this.kdf, required this.userKey});

  final String email;
  final String password;
  final BwKdf kdf;
  final BwKey userKey;
}

/// A cheap PBKDF2 (the server's minimum), so tests don't wait.
const cheapPbkdf2 = BwKdf(type: BwKdfType.pbkdf2, iterations: 100000);

/// A cheap Argon2id.
const cheapArgon2id = BwKdf(type: BwKdfType.argon2id, iterations: 2, memory: 16, parallelism: 1);

var _count = 0;

/// Registers a new account with a random email.
Future<TestAccount> registerAccount(http.Client client, {BwKdf kdf = cheapPbkdf2, String password = 'correct horse battery'}) async {
  final server = serverUrl!;
  final email = 'kemlock-${DateTime.now().microsecondsSinceEpoch}-${_count++}@example.com';
  final masterKey = await bwMasterKey(password, email, kdf);
  final hash = await bwMasterPasswordHash(masterKey, password);
  final userKey = BwKey.random();
  final encryptedKey = await bwEncrypt(userKey.bytes, bwStretch(masterKey));

  final verify = await client.post(
    server.replace(path: '${server.path}/identity/accounts/register/send-verification-email'),
    headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    body: jsonEncode({'email': email, 'name': 'Kemlock test', 'receiveMarketingEmails': false}),
  );
  if (verify.statusCode != 200) throw StateError('send-verification-email: ${verify.statusCode} ${verify.body}');
  final token = jsonDecode(verify.body) as String;

  // The official clients won't open an account without its RSA key pair
  final (publicKey, privateKey) = await _rsaKeyPair();
  final finish = await client.post(
    server.replace(path: '${server.path}/identity/accounts/register/finish'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'email': email,
      'emailVerificationToken': token,
      'masterPasswordHash': hash,
      'masterPasswordHint': null,
      'userSymmetricKey': encryptedKey.toString(),
      'userAsymmetricKeys': {'publicKey': b64(publicKey), 'encryptedPrivateKey': (await bwEncrypt(privateKey, userKey)).toString()},
      ...kdf.toJson(),
    }),
  );
  if (finish.statusCode != 200) throw StateError('register/finish: ${finish.statusCode} ${finish.body}');
  return TestAccount(email: email, password: password, kdf: kdf, userKey: userKey);
}

/// An RSA-2048 key pair from `openssl`, as SPKI and PKCS#8 DER.
Future<(Uint8List, Uint8List)> _rsaKeyPair() async {
  final dir = await Directory.systemTemp.createTemp('kemlock-rsa-');
  try {
    final generated = '${dir.path}/generated.pem';
    final private = '${dir.path}/private.der';
    final public = '${dir.path}/public.der';
    Future<void> openssl(List<String> args) async {
      final result = await Process.run('openssl', args);
      if (result.exitCode != 0) throw StateError('openssl ${args.first}: ${result.stderr}');
    }

    await openssl(['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', generated]);
    // LibreSSL, macOS's openssl, writes PKCS#1 DER; Bitwarden wants PKCS#8
    await openssl(['pkcs8', '-topk8', '-nocrypt', '-in', generated, '-outform', 'DER', '-out', private]);
    await openssl(['pkey', '-in', generated, '-pubout', '-outform', 'DER', '-out', public]);
    return (await File(public).readAsBytes(), await File(private).readAsBytes());
  } finally {
    await dir.delete(recursive: true);
  }
}

/// A device for signing in from tests.
VwDevice testDevice([String? id]) => VwDevice(id: id ?? _uuid(), type: 0, name: 'Kemlock tests');

String _uuid() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
