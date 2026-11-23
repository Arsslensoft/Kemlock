// A real Kemlock Server for the tests in this folder, which only run when KEMLOCK_URL is set, as the tests of
// test/vaultwarden_server only run when VAULTWARDEN_URL is (add-kemlock-server-sync, task 13.3), e.g.
//
//   KEMLOCK_URL=https://localhost:8443 KEMLOCK_PIN=AB:CD:… \
//   KEMLOCK_EMAIL=me@example.com KEMLOCK_PASSWORD='correct horse battery' \
//     flutter test test/kemlock_server
//
// The server is the development build of kemlock-server, with an account that signs in with its master password
// and no second step, made beforehand through the server's own tooling: this folder registers none, since the
// phone has no registration of its own. Every test adds entries under random ids and deletes them again.
//
// - KEMLOCK_PIN: the SHA-256 fingerprint of a self-signed certificate, when the system doesn't trust it.
// - KEMLOCK_REPLICA_URL and KEMLOCK_REPLICA_PIN: a replica of the same account, for the failover test. With none the
//   test fails over to the same server, by the device key and not the stored session, which still tries the route.
// - The server's approval words are the phone's own, from assets/data/eff_large_wordlist.txt.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:kemlock/core/ids.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_backend.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_failover.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_signin.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_http.dart';
import 'package:kemlock/models/otp_account.dart';

/// The server's address, or null when these tests should be skipped.
Uri? get serverUrl => switch (Platform.environment['KEMLOCK_URL']) {
  final url? when url.isNotEmpty => Uri.parse(url.endsWith('/') ? url.substring(0, url.length - 1) : url),
  _ => null,
};

/// Why these tests are skipped, or null when they run.
String? get skipServer => serverUrl == null
    ? 'Set KEMLOCK_URL (and KEMLOCK_EMAIL and KEMLOCK_PASSWORD) to run against a real Kemlock Server'
    : (email.isEmpty || password.isEmpty ? 'Set KEMLOCK_EMAIL and KEMLOCK_PASSWORD to an account of the server' : null);

String? get serverPin => Platform.environment['KEMLOCK_PIN'];
String get email => Platform.environment['KEMLOCK_EMAIL'] ?? '';
String get password => Platform.environment['KEMLOCK_PASSWORD'] ?? '';

/// The replica's address and pin, or the server itself.
Uri get replicaUrl => switch (Platform.environment['KEMLOCK_REPLICA_URL']) {
  final url? when url.isNotEmpty => Uri.parse(url),
  _ => serverUrl!,
};
String? get replicaPin => Platform.environment['KEMLOCK_REPLICA_URL'] == null ? serverPin : Platform.environment['KEMLOCK_REPLICA_PIN'];

/// A client for the server that pins its certificate when [pin] is given.
http.Client clientFor(String? pin) => vwHttpClient(pin: pin);

/// The vault's sealed values, in memory as JSON, as the vault keeps them.
class MemoryValues implements KmVaultValues {
  final values = <String, Object?>{};

  @override
  Future<Object?> load(String key) async => values[key] == null ? null : jsonDecode(jsonEncode(values[key]));

  @override
  Future<void> save(String key, Object? value) async => values[key] = jsonDecode(jsonEncode(value));

  @override
  void remove(String key) => values.remove(key);
}

/// One simulated phone of the account: its own device key, session and entries, signed in with the master password.
class LivePhone {
  LivePhone._(this.key, this.proofs, this.values, this.signedIn);

  final SoftwareDeviceKey key;
  final KmDpop proofs;
  final MemoryValues values;
  final KmSignedIn signedIn;

  /// This phone's entries and what its last run kept, as the scheduler holds them.
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);

  /// The target this phone syncs: the server itself, as the home.
  KemlockTarget get target => KemlockTarget(
    accountId: signedIn.session.userId,
    email: email,
    servers: [KemlockServer(url: serverUrl.toString(), pin: serverPin)],
    deviceId: signedIn.session.deviceId,
  );

  /// A host over the real server, with [clientFor] making its clients, and [onAway] told where the phone is.
  KmHost host({http.Client Function(String? pin)? clients, void Function(KmAway? away)? onAway}) =>
      KmHost(values: values, clientFor: clients ?? clientFor, proofsFor: (_) async => proofs, onAway: onAway);

  /// Runs one sync against [target] and takes the merged document, as the scheduler does.
  Future<KmSyncResult> sync({KemlockTarget? to, KmHost? through}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = await (through ?? host()).sync(to ?? target, lists, state, now: now);
    lists = result.doc;
    state = ScopeState(known: result.known, lastSyncAt: now, extra: result.state);
    return result;
  }

  /// The ids of this phone's accounts.
  List<String> get accountIds => [for (final account in lists.accounts) account.id];
}

/// Signs a new phone in to the server with the account's master password, or [withPassword].
Future<LivePhone> signInPhone({String? withPassword}) async {
  final key = SoftwareDeviceKey.generate();
  final proofs = KmDpop(key);
  final client = clientFor(serverPin);
  try {
    final signIn = KmSignIn(
      api: KmApi(client, proofs: proofs),
      server: serverUrl!,
      device: KmDeviceInfo(name: 'Kemlock tests', kind: 'kemlock-android', id: newUuid()),
      opaque: OpaqueKmOpaque(),
      deviceKey: const {'protection': 'software'},
    );
    await signIn.ways(email);
    final step = await signIn.password(email, withPassword ?? password);
    if (step is! KmSignedIn) throw StateError('the account asks for more than its password: $step');
    final values = MemoryValues();
    await kmKeepSignIn(values, step);
    return LivePhone._(key, proofs, values, step);
  } finally {
    client.close();
  }
}

/// An entry with a random id, so a run never meets another run's.
OtpAccount testAccount(String label, {int? updatedAt}) => OtpAccount(
  id: newUuid(),
  issuer: 'Kemlock server test',
  label: label,
  secret: 'JBSWY3DPEHPK3PXP',
  addedAt: DateTime.now().millisecondsSinceEpoch,
  updatedAt: updatedAt,
);

/// A client that fails every request as a server that is down does.
class DownClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => Future.error(http.ClientException('the server is down', request.url));
}
