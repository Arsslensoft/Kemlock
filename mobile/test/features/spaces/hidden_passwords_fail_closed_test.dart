import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/hidden_passwords.dart';
import 'package:kemlock/features/spaces/space_types.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/login.dart';

import 'chain_kit.dart';

// The regression test of the fail-closed fix (docs/plans/add-server-spaces.md, task 5.5): what `HiddenPasswords.hides`
// answers for a login of a space that hasn't reported its chain. The widgets' part is in the logins and export tests.
void main() {
  final space = uuid(0x5a);
  final everyone = uuid(0xe0);
  final alice = Person(1);
  final bob = Person(2);

  Login login({String? spaceId, String id = 'l1'}) => Login(id: id, name: 'Site', password: 'pw', addedAt: 0, spaceId: spaceId);

  SpaceHold holdFor(CollectionPermission permission, {Map<String, String>? collections}) {
    final chain = ChainBuilder(space)
      ..create(alice, collection: everyone)
      ..invite(alice, bob, grants: {everyone: permission});
    return SpaceHold(chain: chain.state, account: bob.id, collections: collections ?? {'l1': everyone});
  }

  Space webDav(String id) => Space(
    id: id,
    name: 'Family',
    target: const SyncTarget(
      dav: DavAccount(url: 'https://dav.example/', username: 'u', password: 'p'),
      file: 'f.json',
      key: 'k',
    ),
    joinedAt: 0,
  );

  test('a login of a space that has not reported its chain is hidden, with no settings loaded or with settings', () {
    expect(const HiddenPasswords().hides(login(spaceId: space)), isTrue);
    expect(const HiddenPasswords().withSettings(const SyncSettings()).hides(login(spaceId: space)), isTrue);
  });

  test('a login with no space, or an empty one, is never hidden', () {
    expect(const HiddenPasswords().hides(login()), isFalse);
    expect(const HiddenPasswords().hides(login(spaceId: '')), isFalse);
  });

  test('a login of a WebDAV space in the settings is never hidden, and one of another space still is', () {
    final settings = SyncSettings(spaces: [webDav('family')]);
    final hidden = const HiddenPasswords().withSettings(settings);

    expect(hidden.hides(login(spaceId: 'family')), isFalse);
    expect(hidden.hides(login(spaceId: space)), isTrue);
  });

  test('only a reported grant without hide-passwords releases a login', () {
    final held = const HiddenPasswords().remembering(space, holdFor(CollectionPermission.edit));
    final hiding = const HiddenPasswords().remembering(space, holdFor(CollectionPermission.editHidePasswords));

    expect(held.hides(login(spaceId: space)), isFalse);
    expect(hiding.hides(login(spaceId: space)), isTrue);
    // An account the chain gives no access to has no real grant to show the password with
    final stranger = const HiddenPasswords().remembering(
      space,
      SpaceHold(chain: held.spaces[space]!.chain, account: uuid(0x99), collections: {'l1': everyone}),
    );
    expect(stranger.hides(login(spaceId: space)), isTrue, reason: 'no grant at all');
    final strangerUnmapped = const HiddenPasswords().remembering(space, SpaceHold(chain: held.spaces[space]!.chain, account: uuid(0x99)));
    expect(strangerUnmapped.hides(login(spaceId: space)), isTrue, reason: 'no grant at all');
  });
}
