import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/legacy_ids.dart';
import 'package:kemlock/features/export/credential_export.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/login.dart';

import 'chain_kit.dart';

// The regression test of the fix for moved spaces (docs/plans/add-server-spaces.md, tasks 5.5 and 8.1): a WebDAV space that moved
// to Kemlock Server keeps its WebDAV id on the phone, so its logins must be told from a WebDAV space's by the settings' note, and
// follow the grants the chain reports under the server's UUID. A move that is only half done leaves them a WebDAV space's.
class _SyncWith extends SyncNotifier {
  _SyncWith(this._settings);

  final SyncSettings _settings;

  @override
  SyncSnapshot build() => SyncSnapshot(settings: _settings);
}

void main() {
  const webDavId = 'fam-01';
  final serverId = spaceUuid(webDavId);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);

  Login login({String id = 'l1'}) => Login(id: id, name: 'Site', password: 'pw', addedAt: 0, spaceId: webDavId);

  Space spaceIn(SpaceCopy? state) {
    final space = Space(
      id: webDavId,
      name: 'Family',
      target: const SyncTarget(
        dav: DavAccount(url: 'https://dav.example/', username: 'u', password: 'p'),
        file: 'f.json',
        key: 'k',
      ),
      joinedAt: 0,
    );
    return state == null ? space : space.withOnServer(SpaceOnServer(state: state, uuid: serverId, at: 1));
  }

  SpaceHold holdFor(CollectionPermission permission) {
    final chain = ChainBuilder(serverId)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: permission});
    return SpaceHold(chain: chain.state, account: bob.id, collections: {'l1': everyone});
  }

  HiddenPasswords hiddenFor(SpaceCopy? state) => const HiddenPasswords().withSettings(SyncSettings(spaces: [spaceIn(state)]));

  group('the passwords of a moved space', () {
    test('are open while the space is a WebDAV space, which includes a move that is only half done or merely offered', () {
      expect(hiddenFor(null).hides(login()), isFalse);
      expect(hiddenFor(SpaceCopy.moving).hides(login()), isFalse, reason: 'nothing is hidden or shown that the file did not show');
      expect(hiddenFor(SpaceCopy.offered).hides(login()), isFalse, reason: 'the person has not agreed to join yet');
    });

    test('stay hidden once the space moved, until its chain has been read: nothing leaks between the two', () {
      for (final state in [SpaceCopy.bridged, SpaceCopy.joining, SpaceCopy.joined, SpaceCopy.closed]) {
        expect(hiddenFor(state).hides(login()), isTrue, reason: state.name);
      }
    });

    test('then follow the grants the chain reports under the server’s UUID, whichever id the logins carry', () {
      final open = hiddenFor(SpaceCopy.bridged).remembering(serverId, holdFor(CollectionPermission.edit));
      final hiding = hiddenFor(SpaceCopy.bridged).remembering(serverId, holdFor(CollectionPermission.editHidePasswords));

      expect(open.hides(login()), isFalse);
      expect(hiding.hides(login()), isTrue);
    });

    test('are left out of an export as a server space’s, and a space that is still moving is not', () {
      bool isServer(SpaceCopy? state, String id) {
        final container = ProviderContainer(
          overrides: [
            syncProvider.overrideWith(() => _SyncWith(SyncSettings(spaces: [spaceIn(state)]))),
          ],
        );
        addTearDown(container.dispose);
        return container.read(serverSpaceItemProvider)(id);
      }

      expect(isServer(null, webDavId), isFalse);
      expect(isServer(SpaceCopy.moving, webDavId), isFalse);
      expect(isServer(SpaceCopy.offered, webDavId), isFalse);
      for (final state in [SpaceCopy.bridged, SpaceCopy.joining, SpaceCopy.joined, SpaceCopy.closed]) {
        expect(isServer(state, webDavId), isTrue, reason: state.name);
      }
    });
  });
}
