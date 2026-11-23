// What the tests of moving a WebDAV space to Kemlock Server share (docs/plans/add-server-spaces.md, tasks 8.1 to 8.5): an
// account with real keys, a phone of it on the fake server, the WebDAV space of the plan's example, and a family of entries
// whose ids are the ones a WebDAV space really holds: UUIDs, 16-hex ids and 0.1.0's `acc-1`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:kemlock/crypto/account/bundle.dart';
import 'package:kemlock/crypto/account/encoding.dart' show uuidBytes;
import 'package:kemlock/crypto/account/kx1.dart';
import 'package:kemlock/crypto/account/sig1.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/server_spaces.dart';
import 'package:kemlock/features/spaces/space_head_store.dart' show SpaceAnchors;
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart' show ChainAnchor;
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_cache.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

/// The WebDAV id of the plan's example space, which is no UUID: every member computes its server UUID from it.
const familyId = 'fam-01';

/// The server UUID of [familyId], from `crypto.md`'s legacy ids.
final familyUuid = serverSpaceUuid(familyId);

/// The folder of the fake WebDAV server (`FakeWebDav`) and the path of the family's file in it.
const familyDav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const familyFilePath = '/files/me/Kemlock/backmycodes-space-$familyId.json';

/// The WebDAV space [familyId] with the key [key] (base64) of its file.
Space familySpace(String key, {String name = 'Family'}) => Space(
  id: familyId,
  name: name,
  target: SyncTarget(dav: familyDav, file: spaceFile(familyId), key: key),
  joinedAt: 1,
);

/// An account whose keys are real, so the chain and the boxes are the ones the app makes.
Future<KmAccount> realAccount(int n) async {
  final sigKeys = await Sig1.generate();
  final kxPrivate = Uint8List.fromList(List.generate(Kx1.privateKeyLength, (i) => (i * 7 + n) & 0xff));
  return KmAccount(
    accountId: uuid(n),
    keyVersion: 1,
    rootKey: Uint8List(64),
    kx1PrivateKey: kxPrivate,
    sig1PrivateKey: sigKeys.privateKey,
    kx1PublicKey: await Kx1.publicKeyOf(kxPrivate),
    sig1PublicKey: sigKeys.publicKey,
  );
}

/// One phone of [account] talking to [server]: `store` holds the vault's sealed values (each space's cache, the anchors),
/// as the phone's vault does.
KmServerSpaces sourceOn(
  FakeSpaceServer server,
  KmAccount account,
  Map<String, Object?> store, {
  DateTime Function()? clock,
  String? Function()? homeDown,
}) {
  final connection = KmConnection(
    api: KmApi(server.client),
    server: FakeSpaceServer.url,
    session: KmSession(
      userId: account.accountId,
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: account.accountId, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    ),
    save: (_) async {},
  );
  return KmServerSpaces(
    accountId: account.accountId,
    run: <T>(action) => action(connection, account),
    loadValue: (key) async => store[key] == null ? null : jsonDecode(jsonEncode(store[key])),
    saveValue: (key, value) async => store[key] = jsonDecode(jsonEncode(value)),
    loadAnchors: () async => store['anchors'] is Map<String, Object?> ? store['anchors']! as Map<String, Object?> : null,
    saveAnchors: (anchors) async => store['anchors'] = jsonDecode(jsonEncode(anchors)),
    clock: clock ?? () => DateTime.utc(2026, 11, 22, 12),
    homeDown: homeDown,
  );
}

/// A phone of [account] that already compared a fingerprint for the family's server space: its anchor is stored, as the accept
/// screen or the anchors the account's other devices carry leave it. A phone without one has seen the space for the first time.
Future<KmServerSpaces> anchoredSourceOn(FakeSpaceServer server, KmAccount account, Map<String, Object?> store) async {
  final source = sourceOn(server, account, store);
  final contact = await source.readContact(familyUuid);
  await source.rememberAnchor(familyUuid, contact.anchor!);
  return source;
}

/// The store of a phone that compared the fingerprint of the family's server space as it stands on [server]: its anchor is kept with the
/// record of the comparison. A phone that began on the server has done that at its first contact.
Map<String, Object?> comparedStore(FakeSpaceServer server) => {
  'anchors': jsonDecode(
    jsonEncode(SpaceAnchors({familyUuid: ChainAnchor.of(server.state, server.chain.entries)!}, const {}, {familyUuid}).toJson()),
  ),
};

/// The entries of the family: [accounts] with 0.1.0's ids (`acc-1`, never a UUID) and as many logins, the first half with
/// UUID ids and the rest with 16-hex ids, every one with the space [familyId] as its `spaceId`.
({List<OtpAccount> accounts, List<Login> logins}) familyEntries({int accounts = 20, int logins = 20, int at = 100}) => (
  accounts: [
    for (var i = 1; i <= accounts; i++)
      OtpAccount(id: 'acc-$i', issuer: 'Issuer $i', label: 'me', secret: 'JBSWY3DPEHPK3PXP', spaceId: familyId, addedAt: at, updatedAt: at),
  ],
  logins: [
    for (var i = 1; i <= logins; i++)
      Login(
        id: i <= logins ~/ 2 ? uuid(0x1000 + i) : '3f2c9a71e4b0d8${i.toRadixString(16).padLeft(2, '0')}',
        name: 'Site $i',
        username: 'me',
        password: 'pw-$i',
        spaceId: familyId,
        addedAt: at,
        updatedAt: at,
      ),
  ],
);

/// The ids of [lists], sorted.
List<String> idsOf(Lists lists) => [...lists.ids]..sort();

/// A file key: the 32 bytes of a space file, base64.
String newFileKey() => base64Encode(Uint8List.fromList(List.generate(32, (i) => (i * 5 + 1) & 0xff)));

/// An engine of [account] for the family's server space, whose actions a member's sheet runs: invite, confirm, remove. It keeps
/// what it caches in [store] and the anchors nowhere, as a phone that has not seen the space before.
KmSpaceSync syncFor(
  FakeSpaceServer server,
  KmAccount account,
  Map<String, Object?> store, {
  String? Function()? homeDown,
  Uri Function()? homeUrl,
  bool compared = false,
}) {
  final connection = KmConnection(
    api: KmApi(server.client),
    server: FakeSpaceServer.url,
    session: KmSession(
      userId: account.accountId,
      deviceId: '00000000-0000-4000-8000-0000000000d1',
      tokens: KmTokens(access: account.accountId, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
    ),
    save: (_) async {},
  );
  return KmSpaceSync(
    connection: connection,
    server: FakeSpaceServer.url,
    account: account,
    space: familyUuid,
    loadCache: () async => KmCache.fromJson(store['cache'] == null ? null : jsonDecode(jsonEncode(store['cache']))),
    saveCache: (cache) async => store['cache'] = jsonDecode(jsonEncode(cache.toJson())),
    loadAnchor: (space) async => compared ? ChainAnchor.of(server.state, server.chain.entries) : null,
    loadCompared: (space) async => compared,
    saveAnchor: (space, anchor, {afterFence = false, compared = false}) async {},
    homeDown: homeDown,
    homeUrl: homeUrl,
  );
}

/// Invites [other], confirms them and removes them again from the family's server space, as [owner]'s sheet does: the removal
/// marks the keys they held for replacement.
Future<void> removeMember(FakeSpaceServer server, KmAccount owner, KmAccount other) async {
  final actions = syncFor(server, owner, {}).actions();
  final bundle = KeyBundle(
    accountId: uuidBytes(other.accountId),
    keyVersion: other.keyVersion,
    kx1PublicKey: other.kx1PublicKey,
    sig1PublicKey: other.sig1PublicKey,
  );
  await actions.invite(other.accountId, SpaceRole.member, grants: {server.state.collections.keys.single: CollectionPermission.edit});
  await actions.confirm(
    member: other.accountId,
    bundle: bundle,
    bundleSignature: await signBundle(bundle, other.sig1PrivateKey),
    confirmerSig1PrivateKey: owner.sig1PrivateKey,
  );
  await actions.remove(other.accountId);
}
