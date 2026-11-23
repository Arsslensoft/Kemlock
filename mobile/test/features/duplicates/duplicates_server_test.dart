// The groups Kemlock Server suggests, as the cleaner takes them (add-duplicate-cleaner, task 7.3): hints that are
// opened and compared on the phone before any shows, a "Not duplicates" that another phone shared, and the answers a
// phone shares and takes back.
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/legacy_ids.dart';
import 'package:kemlock/features/duplicates/dedup_cache.dart';
import 'package:kemlock/features/duplicates/dedup_store.dart';
import 'package:kemlock/features/duplicates/dedup_tagger.dart';
import 'package:kemlock/features/duplicates/duplicate_matcher.dart';
import 'package:kemlock/features/duplicates/duplicate_merge.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/features/duplicates/duplicate_server.dart';
import 'package:kemlock/features/duplicates/duplicates_provider.dart';
import 'package:kemlock/features/sync/kemlock/km_dedup_api.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock_matching.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/secure_note.dart';

import '../sync/kemlock/fake_dedup_server.dart';
import '../sync/kemlock/fake_kemlock_accounts.dart';
import '../sync/kemlock/fake_kemlock_server.dart';
import '../sync/kemlock/km_phone_kit.dart';
import '../sync/sync_screen_kit.dart';

const _account = '00000000-0000-4000-8000-000000000001';
const _a = '3f2c9a71-e4b0-4856-8a00-0000000000a1';
const _b = '3f2c9a71-e4b0-4856-8a00-0000000000b2';
const _c = '3f2c9a71-e4b0-4856-8a00-0000000000c3';

Login _login(String id, {String site = 'larkspur.example', String username = 'sam', String password = 'hunter2', int at = 100}) =>
    Login(id: id, name: 'Larkspur $id', username: username, password: password, websites: [site], addedAt: at);

List<DedupItem> _items(List<Login> logins) => dedupItems(logins: logins);

KmHints _hints(List<List<String>> groups, {Set<String> tagged = const {}, int at = 1000, bool enabled = true}) =>
    KmHints(owner: 'user:$_account', enabled: enabled, tagVersion: 1, groups: groups, waiting: 0, tagged: tagged, at: at);

DuplicateGroup _sameSignIn(List<DedupItem> items) => DuplicateGroup(reason: DuplicateReason.sameSignIn, items: items);

late KmTestAccount _test;

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create(_account);
  });

  group('a server group is a hint', () {
    test('a group of two logins with different passwords is not shown', () {
      final items = _items([
        _login(_a, site: 'alpha.example', username: 'ann', password: 'one'),
        _login(_b, site: 'beta.example', username: 'bob', password: 'two'),
      ]);

      final shown = withServerHints(
        found: const [],
        items: items,
        hints: _hints([
          [_a, _b],
        ]),
        accountId: _account,
      );

      expect(shown, isEmpty);
    });

    test('one site and username with two passwords shows as the same account, never as the same sign-in', () {
      final items = _items([_login(_a, password: 'one'), _login(_b, password: 'two')]);

      final shown = withServerHints(
        found: const [],
        items: items,
        hints: _hints([
          [_a, _b],
        ]),
        accountId: _account,
      );

      expect(shown, hasLength(1));
      expect(shown.single.reason, DuplicateReason.sameAccount);
      expect(shown.single.items.map((item) => item.id), [_a, _b]);
    });

    test('two logins with one site, username and password show once the phone has compared them', () {
      final items = _items([_login(_a), _login(_b)]);

      final shown = withServerHints(
        found: const [],
        items: items,
        hints: _hints([
          [_a, _b],
        ]),
        accountId: _account,
      );

      expect(shown.single.reason, DuplicateReason.sameSignIn);
    });

    test('a group the phone found itself is not shown twice', () {
      final items = _items([_login(_a), _login(_b)]);
      final found = [_sameSignIn(items)];

      final shown = withServerHints(
        found: found,
        items: items,
        hints: _hints([
          [_a, _b],
        ]),
        accountId: _account,
      );

      expect(shown, hasLength(1));
    });

    test('an id the vault doesn’t hold, a note and a login in a space are left out of a hint', () {
      final items = dedupItems(
        logins: [
          _login(_a),
          _login(_b).copyWith(spaceId: 'team'),
        ],
        notes: [const SecureNote(id: _c, title: 'Wifi', text: 'fridge', addedAt: 1)],
      );

      final shown = withServerHints(
        found: const [],
        items: items,
        hints: _hints([
          [_a, _b, _c, '3f2c9a71-e4b0-4856-8a00-0000000000ff'],
        ]),
        accountId: _account,
      );

      expect(shown, isEmpty);
    });

    test('a login whose id is a legacy one is found by the server id it has in the vault', () {
      final items = _items([_login('acc-1'), _login(_b)]);
      final legacy = itemUuid('acc-1', Owner.user(_account));

      final shown = withServerHints(
        found: const [],
        items: items,
        hints: _hints([
          [legacy, _b],
        ]),
        accountId: _account,
      );

      expect(shown.single.items.map((item) => item.id), ['acc-1', _b]);
      expect(serverItemIds(items, _account), {legacy: 0, _b: 1});
    });

    test('hints that say matching is off change nothing', () {
      final items = _items([_login(_a), _login(_b)]);

      final shown = withServerHints(
        found: const [],
        items: items,
        hints: _hints([
          [_a, _b],
        ], enabled: false),
        accountId: _account,
      );

      expect(shown, isEmpty);
    });

    test('verifyHints splits a hint by the kind of item and keeps only what the values bear out', () {
      final items = dedupItems(
        logins: [_login(_a), _login(_b)],
        notes: [const SecureNote(id: _c, title: 'Wifi', text: 'fridge', addedAt: 1)],
      );

      final groups = verifyHints(
        items: items,
        hints: [
          [0, 1, 2],
          [1, 7],
        ],
      );

      expect(groups, hasLength(1));
      expect(groups.single.items.map((item) => item.id), [_a, _b]);
    });
  });

  group('a "Not duplicates" another phone shared', () {
    List<DedupItem> items() => _items([_login(_a), _login(_b)]);

    test('hides a same-sign-in group the server leaves out, once every login of it is tagged there', () {
      final found = [_sameSignIn(items())];

      final shown = withServerHints(
        found: found,
        items: items(),
        hints: _hints(const [], tagged: {_a, _b}),
        accountId: _account,
      );

      expect(shown, isEmpty);
    });

    test('keeps it while the server lists it', () {
      final found = [_sameSignIn(items())];

      final shown = withServerHints(
        found: found,
        items: items(),
        hints: _hints(
          [
            [_a, _b],
          ],
          tagged: {_a, _b},
        ),
        accountId: _account,
      );

      expect(shown, hasLength(1));
    });

    test('keeps it when a login of it isn’t known to be tagged on the server', () {
      final found = [_sameSignIn(items())];

      final shown = withServerHints(
        found: found,
        items: items(),
        hints: _hints(const [], tagged: {_a}),
        accountId: _account,
      );

      expect(shown, hasLength(1));
    });

    test('keeps it when a login changed after the groups were read', () {
      final changed = _items([_login(_a), _login(_b, at: 5000)]);
      final found = [_sameSignIn(changed)];

      final shown = withServerHints(
        found: found,
        items: changed,
        hints: _hints(const [], tagged: {_a, _b}, at: 1000),
        accountId: _account,
      );

      expect(shown, hasLength(1));
    });

    test('keeps a group that grew: it is listed, because the answer covered fewer logins', () {
      final three = _items([_login(_a), _login(_b), _login(_c)]);
      final found = [_sameSignIn(three)];

      final shown = withServerHints(
        found: found,
        items: three,
        hints: _hints(
          [
            [_a, _b, _c],
          ],
          tagged: {_a, _b, _c},
        ),
        accountId: _account,
      );

      expect(shown, hasLength(1));
    });

    test('leaves a same-account group alone, which the server never groups', () {
      final two = _items([_login(_a, password: 'one'), _login(_b, password: 'two')]);
      final found = [DuplicateGroup(reason: DuplicateReason.sameAccount, items: two)];

      final shown = withServerHints(
        found: found,
        items: two,
        hints: _hints(const [], tagged: {_a, _b}),
        accountId: _account,
      );

      expect(shown, hasLength(1));
    });
  });

  test('the answers keep the ids of the dismissals shared with the server, and drop them with the dismissal', () {
    const answers = DedupAnswers();

    final shared = answers.withDismissed('a|b').withShared('a|b', 'dismissal-1');

    expect(shared.sharedDismissals, {'a|b': 'dismissal-1'});
    expect(shared.dismissed, ['a|b']);
    expect(DedupAnswers.fromJson(shared.toJson()).sharedDismissals, {'a|b': 'dismissal-1'}, reason: 'kept as stored');
    final back = shared.withoutDismissal('a|b');
    expect(back.dismissed, isEmpty);
    expect(back.sharedDismissals, isEmpty);
    expect(back.isEmpty, isTrue);
  });

  group('the Duplicates check with the server on', () {
    Future<({SyncSheetKit kit, FakeDedupServer server})> open(WidgetTester tester, {bool matching = true}) async {
      final server = FakeDedupServer(userId: _test.userId);
      final host = await signedInHost(server, _test);
      final kit = SyncSheetKit();
      await kit.pump(
        tester,
        (context) async {},
        overrides: [kemlockHostProvider.overrideWith(() => KmHostHolder(host)), suffixListHashProvider.overrideWith((ref) async => 'none')],
      );
      await kit.save(
        SyncSettings(
          kemlock: KemlockTarget(
            accountId: _account,
            email: 'me@example.com',
            servers: const [KemlockServer(url: 'https://kem.example.com')],
            deviceId: FakeKemlockServer.deviceId,
            matching: matching,
          ),
        ),
      );
      for (final login in [_login(_a), _login(_b)]) {
        await kit.vault.addLogin(login.copyWith(updatedAt: 100));
      }
      return (kit: kit, server: server);
    }

    testWidgets('reads the groups the server left out, and the groups it lists, as the other phone answered them', (tester) async {
      final opened = await open(tester);
      final duplicates = opened.kit.container.read(duplicatesProvider.notifier);

      await duplicates.check();
      expect(opened.kit.container.read(duplicatesProvider).groups, hasLength(1), reason: 'the phone finds it without a server');

      // The server read the groups after another phone said "Not duplicates": it lists none, and this phone has tagged both logins
      opened.kit.container.read(kemlockHintsProvider.notifier).set(_hints(const [], tagged: {_a, _b}, at: 1 << 50));
      await duplicates.check();
      expect(opened.kit.container.read(duplicatesProvider).groups, isEmpty);

      // The dismissal was taken back, or a new login joined the group: the server lists it again
      opened.kit.container
          .read(kemlockHintsProvider.notifier)
          .set(
            _hints(
              [
                [_a, _b],
              ],
              tagged: {_a, _b},
              at: 1 << 50,
            ),
          );
      await duplicates.check();
      expect(opened.kit.container.read(duplicatesProvider).groups.single.reason, DuplicateReason.sameSignIn);
    });

    testWidgets('a server that says nothing leaves what the phone found as it is, and matching off ignores the hints', (tester) async {
      final opened = await open(tester, matching: false);
      opened.kit.container.read(kemlockHintsProvider.notifier).set(_hints(const [], tagged: {_a, _b}, at: 1 << 50));

      await opened.kit.container.read(duplicatesProvider.notifier).check();

      expect(opened.kit.container.read(duplicatesProvider).groups, hasLength(1));
    });

    testWidgets('"Not duplicates" on a same-sign-in group is shared with the server, and restore takes it back', (tester) async {
      final opened = await open(tester);
      final duplicates = opened.kit.container.read(duplicatesProvider.notifier);
      await duplicates.check();
      final group = opened.kit.container.read(duplicatesProvider).groups.single;

      expect(await duplicates.dismiss(group), isTrue);
      await tester.pumpAndSettle();

      expect(opened.server.dismissals.values.single, [_a, _b]);
      final store = DedupStore(opened.kit.vaultStore);
      final shared = (await store.loadAnswers(opened.kit.session)).sharedDismissals;
      expect(shared.keys, [group.key]);
      expect(shared.values.single, opened.server.dismissals.keys.single);
      expect(opened.kit.container.read(duplicatesProvider).groups, isEmpty);

      expect(await duplicates.restore(group.key), isTrue);
      await tester.pumpAndSettle();

      expect(opened.server.dismissals, isEmpty);
      expect((await store.loadAnswers(opened.kit.session)).dismissed, isEmpty);
      expect(opened.kit.container.read(duplicatesProvider).groups, hasLength(1), reason: 'asked again');
    });

    testWidgets('with matching off, "Not duplicates" stays on the phone', (tester) async {
      final opened = await open(tester, matching: false);
      final duplicates = opened.kit.container.read(duplicatesProvider.notifier);
      await duplicates.check();

      await duplicates.dismiss(opened.kit.container.read(duplicatesProvider).groups.single);
      await tester.pumpAndSettle();

      expect(opened.server.requests, isEmpty);
      expect(opened.server.dismissals, isEmpty);
    });
  });
}
