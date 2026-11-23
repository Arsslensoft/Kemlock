// Home-only writes (docs/plans/add-server-spaces.md, design decision 5 and task 4.4), against the fake server with the account's
// real keys: every chain record and sealed key goes to the home, and while the phone is on a replica and the home isn't known to be
// back, Invite, Confirm, Remove and Replace keys refuse with the message that says so, and nothing is sent or queued. The space's
// items go on syncing through the replica.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/bundle.dart';
import 'package:kemlock/crypto/account/encoding.dart' show uuidBytes;
import 'package:kemlock/features/spaces/space_actions.dart';
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/features/spaces/space_state.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';

import '../spaces/chain_kit.dart' show uuid;
import '../spaces/fake_space_server.dart' show FakeSpaceServer;
import 'space_bridge_kit.dart';

void main() {
  late KmAccount sam;
  late KmAccount bob;
  late KmAccount carol;

  setUpAll(() async {
    sam = await realAccount(1);
    bob = await realAccount(2);
    carol = await realAccount(3);
  });

  const timeout = Timeout(Duration(minutes: 3));
  const home = 'kem.example.com';

  Matcher homeAway() => throwsA(
    isA<SpaceActionError>().having((e) => e.problem, 'problem', SpaceActionProblem.homeAway).having((e) => e.detail, 'detail', home),
  );

  Future<KeyBundle> bundleOf(KmAccount account) async => KeyBundle(
    accountId: uuidBytes(account.accountId),
    keyVersion: account.keyVersion,
    kx1PublicKey: account.kx1PublicKey,
    sig1PublicKey: account.sig1PublicKey,
  );

  group('while the home is away', () {
    test('items go on syncing through the replica', () async {
      final family = await MovedFamily.make(sam);
      final entries = familyEntries();
      final local = rescopedTo(Lists(accounts: entries.accounts, logins: entries.logins), familyUuid);
      final edited = Lists(
        accounts: [
          for (final account in local.accounts)
            if (account.id == 'acc-3') account.copyWith(issuer: 'Edited on the replica', updatedAt: 9000) else account,
        ],
        logins: local.logins,
      );

      final replica = sourceOn(family.server, sam, comparedStore(family.server), homeDown: () => home);
      await replica.syncSpace(familyUuid, edited, ScopeState(known: [...local.ids]), now: 9001);

      final reader = family.serverPhone();
      await reader.run(now: 20000);
      expect(reader.account('acc-3').issuer, 'Edited on the replica');
    }, timeout: timeout);

    test('Invite, Confirm, Remove and Replace keys refuse with the home’s name, and send and queue nothing', () async {
      final family = await MovedFamily.make(sam);
      final server = family.server;
      final collection = server.state.collections.keys.single;
      var away = false;
      final actions = syncFor(server, sam, {}, homeDown: () => away ? home : null).actions();

      // With the home up: Carol is invited. Her invitation is made before any key is marked: once a key awaits its replacement the
      // chain refuses a record that gives access to it, and a confirm waits for the replacement, so none of them would reach the home
      await actions.invite(carol.accountId, SpaceRole.member, grants: {collection: CollectionPermission.edit});
      final records = server.chain.entries.length;
      expect(server.chain.entries.last.entry.epoch, server.state.epoch, reason: 'a record carries the epoch this phone last saw');

      away = true;
      await expectLater(actions.invite(uuid(9), SpaceRole.member), homeAway());
      await expectLater(
        actions.confirm(
          member: carol.accountId,
          bundle: await bundleOf(carol),
          bundleSignature: await signBundle(await bundleOf(carol), carol.sig1PrivateKey),
          confirmerSig1PrivateKey: sam.sig1PrivateKey,
        ),
        homeAway(),
      );
      await expectLater(actions.remove(carol.accountId), homeAway());
      expect(server.chain.entries, hasLength(records), reason: 'nothing reached the server');

      // Bob is invited, confirmed and removed at the home, which marks his keys for replacement: Replace keys has something to do
      away = false;
      await removeMember(server, sam, bob);
      final marked = server.chain.entries.length;
      expect(server.state.keysNeedReplacing, isTrue);
      away = true;
      await expectLater(
        syncFor(server, sam, {}, homeDown: () => away ? home : null).replaceKeys(now: 30000, readNames: (state, keyring) async => {}),
        homeAway(),
      );
      expect(server.chain.entries, hasLength(marked), reason: 'nothing reached the server');

      // Back at the home, only what the person does again is sent: nothing was waiting
      away = false;
      await actions.remove(carol.accountId);
      expect(server.chain.entries, hasLength(marked + 1));
    }, timeout: timeout);
  });

  group('over a connection to a replica', () {
    // The action's connection was made while the phone was on a replica (`KmHost.withAccount` fixes it at the start). The failover
    // may be back on the home by the time the record is sent, which it says by answering no home is away; the record would still go
    // to the replica, so what decides is the server of the connection, and the home is named, not the replica
    final homeAddress = Uri.parse('https://home.example.org');

    test('Invite and Replace keys refuse though the failover says the home is back, and send nothing', () async {
      final family = await MovedFamily.make(sam);
      final server = family.server;
      final records = server.chain.entries.length;
      Matcher homeNamed() => throwsA(
        isA<SpaceActionError>()
            .having((e) => e.problem, 'problem', SpaceActionProblem.homeAway)
            .having((e) => e.detail, 'detail', 'home.example.org'),
      );
      final engine = syncFor(server, sam, {}, homeDown: () => null, homeUrl: () => homeAddress);

      await expectLater(engine.actions().invite(carol.accountId, SpaceRole.member), homeNamed());
      await expectLater(engine.replaceKeys(now: 30000, readNames: (state, keyring) async => {}), homeNamed());
      expect(server.chain.entries, hasLength(records), reason: 'nothing reached the replica');
    }, timeout: timeout);

    test('a connection to the home sends the record, as before', () async {
      final family = await MovedFamily.make(sam);
      final server = family.server;
      final records = server.chain.entries.length;
      final engine = syncFor(server, sam, {}, homeDown: () => null, homeUrl: () => FakeSpaceServer.url);

      await engine.actions().invite(carol.accountId, SpaceRole.member);

      expect(server.chain.entries, hasLength(records + 1));
    }, timeout: timeout);
  });
}
