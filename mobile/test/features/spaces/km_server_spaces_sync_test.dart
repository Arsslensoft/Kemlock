import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_session.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// What the scheduler asks of an account's spaces (docs/plans/add-server-spaces.md, "Server spaces as a sync scope"): the
// spaces the server lists with the account confirmed, and one run of a space, which reports each chain it verified to
// `hiddenPasswordsProvider` through `onChain` before it does anything else. The run's own cases are in
// `server_spaces_test.dart`.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);

  /// Alice made the space, and invited Bob, who has not been confirmed.
  ChainBuilder invited() => ChainBuilder(space)
    ..create(alice, collection: everyone)
    ..invite(alice, bob, grants: {everyone: CollectionPermission.viewHidePasswords});

  /// [who]'s spaces on a server whose chain is [chain], reporting each verified chain to [container].
  KmServerSpaces sourceOf(Person who, ChainBuilder chain, ProviderContainer container) {
    final server = FakeSpaceServer(space, chain);
    final account = KmAccount(
      accountId: who.id,
      keyVersion: who.keyVersion,
      rootKey: Uint8List(64),
      kx1PrivateKey: Uint8List(64),
      sig1PrivateKey: Uint8List(64),
      kx1PublicKey: who.bundle.kx1PublicKey,
      sig1PublicKey: who.bundle.sig1PublicKey,
    );
    final connection = KmConnection(
      api: KmApi(MockClient(server.handle)),
      server: FakeSpaceServer.url,
      session: KmSession(
        userId: who.id,
        deviceId: '00000000-0000-4000-8000-0000000000d1',
        tokens: KmTokens(access: who.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
      ),
      save: (_) async {},
    );
    final store = <String, Object?>{};
    return KmServerSpaces(
      accountId: who.id,
      run: <T>(action) => action(connection, account),
      loadValue: (key) async => store[key],
      saveValue: (key, value) async => store[key] = value,
      chainCrypto: const FakeChainCrypto(),
      onChain: (space, account, chain, {collections}) =>
          container.read(hiddenPasswordsProvider.notifier).report(space, account, chain, collections: collections),
    );
  }

  ProviderContainer containerOf() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('the spaces the scheduler runs', () {
    test('are the ones the server lists with the account confirmed', () async {
      final container = containerOf();

      expect(await sourceOf(alice, invited(), container).confirmedSpaces(), [space], reason: 'Alice made the space');
      expect(await sourceOf(bob, invited(), container).confirmedSpaces(), isEmpty, reason: 'Bob’s invitation waits to be confirmed');
    });

    test('include a space once its member is confirmed', () async {
      final container = containerOf();
      final chain = invited()..confirm(alice, bob);

      expect(await sourceOf(bob, chain, container).confirmedSpaces(), [space]);
    });
  });

  group('a run of a space', () {
    test('reports the chain it verified to hiddenPasswordsProvider, whatever the run then does', () async {
      final container = containerOf();
      expect(container.read(hiddenPasswordsProvider).spaces, isEmpty);

      final result = await sourceOf(
        bob,
        invited(),
        container,
      ).syncSpace(space, const Lists(), const ScopeState(known: []), now: 1700000000000);

      final hold = container.read(hiddenPasswordsProvider).spaces[space];
      expect(hold, isNotNull, reason: 'the verified chain was reported');
      expect(hold!.account, bob.id);
      expect(hold.chain.accessOf(bob.id, everyone)?.hidePasswords, isTrue);
      expect(result.doc.accounts, isEmpty, reason: 'a member who isn’t confirmed holds nothing of the space');
      expect(result.known, isEmpty);
    });

    test('follows a grant that the next run finds changed', () async {
      final container = containerOf();
      await sourceOf(bob, invited(), container).syncSpace(space, const Lists(), const ScopeState(known: []), now: 1700000000000);
      expect(container.read(hiddenPasswordsProvider).spaces[space]!.chain.accessOf(bob.id, everyone)?.hidePasswords, isTrue);

      final changed = ChainBuilder(space)
        ..create(alice, collection: everyone)
        ..invite(alice, bob, grants: {everyone: CollectionPermission.edit});
      await sourceOf(bob, changed, container).syncSpace(space, const Lists(), const ScopeState(known: []), now: 1700000001000);

      expect(container.read(hiddenPasswordsProvider).spaces[space]!.chain.accessOf(bob.id, everyone)?.hidePasswords, isFalse);
    });

    test('refuses an id that is not a space’s UUID before asking the server anything', () async {
      final container = containerOf();

      await expectLater(
        sourceOf(bob, invited(), container).syncSpace('personal', const Lists(), const ScopeState(known: []), now: 1),
        throwsArgumentError,
      );
      expect(container.read(hiddenPasswordsProvider).spaces, isEmpty);
    });
  });
}
