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
import 'package:kemlock/models/login.dart';

import 'chain_kit.dart';
import 'fake_space_server.dart';

// What feeds `hiddenPasswordsProvider` (docs/plans/add-server-spaces.md, task 5.5): each verified chain a read or a run of a
// space reports, with the member's access per collection, and the logins of the collections that hide passwords are the
// ones the login sheet, the edit sheet, health and exports keep the password of out of sight.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final finance = uuid(0xf1);
  final alice = Person(1);
  final bob = Person(2);

  Login login(String id) => Login(id: id, name: 'Site $id', username: 'me', password: 'pw-$id', addedAt: 1, spaceId: space);

  /// The chain in which Bob holds [permission] on "Everyone", and edit on "Finance".
  ChainBuilder chainFor(CollectionPermission permission) => ChainBuilder(space)
    ..create(alice, collection: everyone)
    ..collection(alice, finance)
    ..invite(alice, bob, grants: {everyone: permission, finance: CollectionPermission.edit});

  ProviderContainer containerOf() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('the notifier', () {
    test('hides the logins of a collection granted view, passwords hidden, and none of another', () {
      final container = containerOf();
      container
          .read(hiddenPasswordsProvider.notifier)
          .report(space, bob.id, chainFor(CollectionPermission.viewHidePasswords).state, collections: {'l1': everyone, 'l2': finance});

      final hidden = container.read(hiddenPasswordsProvider);
      expect(hidden.hides(login('l1')), isTrue);
      expect(hidden.hides(login('l2')), isFalse);
    });

    test('follows a grant that changed with the next chain, and keeps the collections a read of the chain alone doesn’t know', () {
      final container = containerOf();
      final notifier = container.read(hiddenPasswordsProvider.notifier);
      notifier.report(space, bob.id, chainFor(CollectionPermission.edit).state, collections: {'l1': everyone, 'l2': finance});
      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isFalse);

      // The next read of the chain finds the grant now hides passwords, and knows no entry's collection
      notifier.report(space, bob.id, chainFor(CollectionPermission.viewHidePasswords).state);
      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isTrue, reason: 'l1 is still in "Everyone"');
      expect(container.read(hiddenPasswordsProvider).hides(login('l2')), isFalse, reason: 'l2 is still in "Finance"');

      // And the grant is taken back
      notifier.report(space, bob.id, chainFor(CollectionPermission.view).state);
      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isFalse);
    });
  });

  group('a space read through the account’s source', () {
    /// Bob's source of spaces on a server whose chain is [chain], reporting each verified chain to the provider.
    KmServerSpaces sourceOf(ChainBuilder chain, ProviderContainer container) {
      final server = FakeSpaceServer(space, chain);
      final account = KmAccount(
        accountId: bob.id,
        keyVersion: bob.keyVersion,
        rootKey: Uint8List(64),
        kx1PrivateKey: Uint8List(64),
        sig1PrivateKey: Uint8List(64),
        kx1PublicKey: bob.bundle.kx1PublicKey,
        sig1PublicKey: bob.bundle.sig1PublicKey,
      );
      final connection = KmConnection(
        api: KmApi(MockClient(server.handle)),
        server: FakeSpaceServer.url,
        session: KmSession(
          userId: bob.id,
          deviceId: '00000000-0000-4000-8000-0000000000d1',
          tokens: KmTokens(access: bob.id, refresh: 'refresh', accessExpiresAt: 1 << 50, refreshExpiresAt: 1 << 50),
        ),
        save: (_) async {},
      );
      final store = <String, Object?>{};
      return KmServerSpaces(
        accountId: bob.id,
        run: <T>(action) => action(connection, account),
        loadValue: (key) async => store[key],
        saveValue: (key, value) async => store[key] = value,
        chainCrypto: const FakeChainCrypto(),
        onChain: (space, account, chain, {collections}) =>
            container.read(hiddenPasswordsProvider.notifier).report(space, account, chain, collections: collections),
      );
    }

    test('hides the password of a login of a space whose chain grants view, passwords hidden', () async {
      final container = containerOf();
      expect(
        container.read(hiddenPasswordsProvider).hides(login('l1')),
        isTrue,
        reason: 'a space login stays hidden until its chain is read',
      );

      await sourceOf(chainFor(CollectionPermission.viewHidePasswords), container).load();

      final hold = container.read(hiddenPasswordsProvider).spaces[space];
      expect(hold, isNotNull, reason: 'the verified chain was reported');
      expect(hold!.account, bob.id);
      expect(hold.chain.accessOf(bob.id, everyone)?.hidePasswords, isTrue);
      // Each collection holds a grant that doesn't hide, so an entry of an unknown collection shows
      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isFalse);
      container.read(hiddenPasswordsProvider.notifier).report(space, bob.id, hold.chain, collections: {'l1': everyone, 'l2': finance});
      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isTrue);
      expect(container.read(hiddenPasswordsProvider).hides(login('l2')), isFalse);
    });

    test('shows the password again once the chain grants edit', () async {
      final container = containerOf();
      await sourceOf(chainFor(CollectionPermission.viewHidePasswords), container).load();
      container
          .read(hiddenPasswordsProvider.notifier)
          .report(space, bob.id, container.read(hiddenPasswordsProvider).spaces[space]!.chain, collections: {'l1': everyone});
      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isTrue);

      await sourceOf(chainFor(CollectionPermission.edit), container).load();

      expect(container.read(hiddenPasswordsProvider).hides(login('l1')), isFalse);
      expect(container.read(hiddenPasswordsProvider).spaces[space]!.collections, {
        'l1': everyone,
      }, reason: 'a read of the chain keeps the entries’ collections');
    });
  });
}
