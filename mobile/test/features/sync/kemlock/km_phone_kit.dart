// A signed-in phone for widget tests of the Kemlock Server sheets: the vault's
// sealed values in memory, and a host over a fake server with a session bound
// to a software device key.
import 'dart:convert';

import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/kemlock/km_sync.dart' show KmAnchors;
import 'package:kemlock/features/sync/sync_store.dart';

import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';

/// The vault's sealed values, in memory as JSON, as the vault keeps them.
class KmMemoryValues implements KmVaultValues {
  final values = <String, Object?>{};

  @override
  Future<Object?> load(String key) async => values[key] == null ? null : jsonDecode(jsonEncode(values[key]));

  @override
  Future<void> save(String key, Object? value) async => values[key] = jsonDecode(jsonEncode(value));

  @override
  void remove(String key) => values.remove(key);
}

/// The holder of the open vault's host, with [host] in it, for a provider override.
class KmHostHolder extends KemlockHostHolder {
  KmHostHolder(this.host);

  final KmHost host;

  @override
  KmHost? build() => host;
}

/// A host over [server] for an account that signed in with a software key, keeping its spaces' [anchors] when given.
Future<KmHost> signedInHost(FakeKemlockServer server, KmTestAccount account, {KmAnchors? anchors}) async {
  final key = SoftwareDeviceKey.generate();
  final tokens = server.issueTokens(FakeKemlockServer.thumbprint(key.publicJwk));
  final values = KmMemoryValues();
  await values.save(
    keyKemlockSession,
    KmSession(
      userId: account.userId,
      deviceId: FakeKemlockServer.deviceId,
      tokens: KmTokens(
        access: tokens['accessToken']! as String,
        refresh: tokens['refreshToken']! as String,
        accessExpiresAt: 1 << 50,
        refreshExpiresAt: 1 << 50,
      ),
      deviceKey: const {'protection': 'software'},
    ).toJson(),
  );
  await values.save(
    keyKemlockAccount,
    KmAccount(
      accountId: account.userId,
      keyVersion: 1,
      rootKey: account.root,
      kx1PrivateKey: account.kx1.privateKey,
      sig1PrivateKey: account.sig1.privateKey,
      kx1PublicKey: account.kx1.publicKey,
      sig1PublicKey: account.sig1.publicKey,
      opaqueEnrolled: true,
    ).toJson(),
  );
  return KmHost(values: values, clientFor: (pin) => server.client, proofsFor: (session) async => KmDpop(key), anchors: anchors);
}
