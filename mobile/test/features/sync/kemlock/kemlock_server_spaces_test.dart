// The server spaces on the Spaces sheet (docs/plans/add-server-spaces.md, task 5.1): a vault signed in to Kemlock Server
// lists its spaces beside its WebDAV ones, each with its chain read and checked and the account's role in it; a vault
// without Kemlock Server shows none. The server is the fake one of the Kemlock Server sync tests, with the routes of a
// space's list and chain, and the chain's signatures are the tests' cheap ones.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/server_spaces_list.dart';
import 'package:kemlock/features/spaces/space_head_store.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/spaces/space_verify.dart' show ChainAnchor;
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_sync.dart' show KmAnchors;
import 'package:kemlock/features/sync/kemlock_server_spaces.dart';
import 'package:kemlock/features/sync/spaces_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';

import '../../../helpers/test_app.dart';
import '../../spaces/chain_kit.dart';
import '../sync_screen_kit.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';
import 'km_phone_kit.dart';

/// The account of the phone, which is also the maker of the space the server lists.
final _account = uuid(1);
final _space = uuid(0x5a);
final _everyone = uuid(0xe0);

final _target = KemlockTarget(
  accountId: _account,
  email: 'me@example.com',
  servers: const [KemlockServer(url: 'https://kem.example.com')],
  deviceId: FakeKemlockServer.deviceId,
);

late KmTestAccount _test;

/// The fake server with the routes of the list of an account's spaces and of a space's chain.
class _SpacesServer extends FakeKemlockServer {
  _SpacesServer(this.chains, {super.userId});

  /// The chain of each space the account is in.
  final Map<String, ChainBuilder> chains;

  http.Response _body(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  @override
  Future<http.Response?> tokenRoute(http.Request request, String route) async {
    if (request.method != 'GET') {
      return null;
    }
    if (route == '/spaces') {
      // The server's shape: each space with the asking account's own member record. No name is given, so the row
      // shows the start of the id
      return _body([
        for (final id in chains.keys)
          {
            'space': {'id': id, 'keyVersion': 1, 'createdAt': '2026-11-22T10:00:00Z'},
            'member': {
              'user': _account,
              'role': 'owner',
              'custom': <String>[],
              'state': 'confirmed',
              'invitedBy': _account,
              'invitedAt': 1,
            },
          },
      ]);
    }
    final chain = RegExp(r'^/spaces/([^/]+)/chain$').firstMatch(route);
    if (chain == null) {
      return null;
    }
    final builder = chains[chain[1]];
    if (builder == null) {
      return problem(404, 'not-found');
    }
    return _body([for (final signed in builder.entries) signed.toJson()]);
  }
}

Space _webDavSpace() => Space(
  id: 'family-space',
  name: 'Family',
  target: SyncTarget(
    dav: const DavAccount(url: folder, username: 'me', password: 'app-pw'),
    file: spaceFile('family-space'),
    key: b64(randomBytes(32)),
  ),
  joinedAt: 1,
);

/// Opens the Spaces sheet of a vault with a WebDAV space, signed in to Kemlock Server when [signedIn], whose phone compared
/// the server space's fingerprint when [compared] (its anchor is then kept with the record of the comparison).
Future<ProviderContainer> _open(WidgetTester tester, {required bool signedIn, bool compared = true}) async {
  final chain = ChainBuilder(_space)..create(Person(1), collection: _everyone);
  final server = _SpacesServer({_space: chain}, userId: _account);
  Map<String, Object?>? held = compared
      ? SpaceAnchors({_space: ChainAnchor.of(chain.state, chain.entries)!}, const {}, {_space}).toJson()
      : null;
  final host = await signedInHost(
    server,
    _test,
    anchors: KmAnchors(load: () async => held, save: (value) async => held = value),
  );
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSpacesSheet,
    overrides: [
      if (signedIn) kemlockHostProvider.overrideWith(() => KmHostHolder(host)),
      spaceChainCryptoProvider.overrideWithValue(const FakeChainCrypto()),
    ],
  );
  await kit.save(SyncSettings(spaces: [_webDavSpace()], kemlock: signedIn ? _target : null));
  await tester.tap(find.byKey(openSheetKey));
  // The list reads each chain in several steps, with a progress bar that never settles until it has, so the
  // frames are pumped a few at a time: one long pump runs only the first step
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  return kit.container;
}

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create(_account);
  });

  testWidgets('a vault signed in to Kemlock Server lists its server spaces beside its WebDAV ones', (tester) async {
    await _open(tester, signedIn: true);

    expect(find.text(t('spaces.webdav.title')), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text(t('spaces.server.title')), findsOneWidget);
    expect(find.byKey(ValueKey('server-space-open-$_space')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(ValueKey('server-space-status-$_space'))).data,
      t('spaces.server.row', {'status': SpaceRole.owner.wire}),
    );
    expect(find.text(t('spaces.server.failed')), findsNothing);
  });

  testWidgets('a server space whose fingerprint this phone never compared asks for the comparison, not a role', (tester) async {
    await _open(tester, signedIn: true, compared: false);

    expect(
      tester.widget<Text>(find.byKey(ValueKey('server-space-status-$_space'))).data,
      t('spaces.server.row', {'status': 'compare'}),
      reason: 'listing a space makes no anchor, so it is no space this phone trusts',
    );
  });

  testWidgets('the source an open sheet holds outlives the provider that made it: a disposed ref is never read', (tester) async {
    final container = await _open(tester, signedIn: true);
    final source = container.read(kemlockServerSpacesSourceProvider)! as KmServerSpaces;

    // The provider rebuilds on every settings save (`KemlockTarget` has no `==`), while the sheet keeps this source and its
    // closures, whose ref is disposed from then on
    container.invalidate(kemlockServerSpacesSourceProvider);
    expect(container.read(kemlockServerSpacesSourceProvider), isNot(same(source)));

    final chain = (ChainBuilder(_space)..create(Person(1), collection: _everyone)).state;
    expect(source.leaveFirstFor!(_space, chain), isNull);
    expect(source.noticesSeen!(), isEmpty);
    await source.markNoticeSeen!('chain:$_space:duplicateMatching', 1);
  });

  testWidgets('a vault without Kemlock Server shows no server spaces', (tester) async {
    await _open(tester, signedIn: false);

    expect(find.text('Family'), findsOneWidget);
    expect(find.byType(ServerSpacesList), findsNothing);
    expect(find.text(t('spaces.server.title')), findsNothing);
    expect(find.text(t('spaces.webdav.title')), findsNothing);
    expect(find.byKey(ValueKey('server-space-open-$_space')), findsNothing);
  });
}
