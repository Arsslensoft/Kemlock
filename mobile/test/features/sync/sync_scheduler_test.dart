// When sync runs and what it takes, ported from the cases of
// src/components/SyncController.test.tsx, with the scheduling the
// controller did through effects and timers: on unlock, two seconds after a
// change, on coming back to the front, every five minutes, and one run at a
// time. Timers are fake; the WebDAV folder is the fake server.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/sync_scheduler.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_store.dart';

import '../../vault/fast_kdf.dart';
import 'fake_webdav.dart';

const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
const path = '/files/me/Kemlock/$syncFile';
final unlockedAt = DateTime.utc(2026, 10, 16, 12);

OtpAccount acct(String id, {String? spaceId}) => OtpAccount(id: id, issuer: id, label: '', secret: 'S$id', spaceId: spaceId, addedAt: 1);

List<String> ids(Iterable<OtpAccount> accounts) => [for (final account in accounts) account.id]..sort();

/// Timers that fire only when the test moves the time on.
class FakeTimers {
  Duration _now = Duration.zero;
  final _timers = <_FakeTimer>[];

  Timer start(Duration delay, void Function() callback) => _add(delay, null, (_) => callback());

  Timer periodic(Duration period, void Function(Timer timer) callback) => _add(period, period, callback);

  Timer _add(Duration delay, Duration? period, void Function(Timer timer) callback) {
    final timer = _FakeTimer(_now + delay, period, callback);
    _timers.add(timer);
    return timer;
  }

  /// Timers still waiting to fire.
  int get pending => _timers.where((t) => t.isActive).length;

  /// Moves the time on by [by], firing each timer that comes due, in order.
  void elapse(Duration by) {
    final until = _now + by;
    while (true) {
      final due = _timers.where((t) => t.isActive && t.due <= until).toList()..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      _now = due.first.due;
      due.first.fire();
    }
    _now = until;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this.period, this.callback);

  Duration due;
  final Duration? period;
  final void Function(Timer timer) callback;
  var _active = true;
  var _tick = 0;

  void fire() {
    _tick++;
    if (period case final period?) {
      due += period;
    } else {
      _active = false;
    }
    callback(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;
}

/// One open vault with sync set up, and what the scheduler did to it.
class Setup {
  Setup._(this.container, this.server, this.session, this.timers, this.key, this.lists);

  final ProviderContainer container;
  final FakeWebDav server;
  final VaultSession session;
  final FakeTimers timers;
  final String key;
  late final SyncScheduler scheduler;

  /// The vault's lists, as the scheduler sees them.
  Lists lists;

  /// Each set of lists the scheduler stored.
  final applied = <Lists>[];

  SyncNotifier get store => container.read(syncProvider.notifier);
  SyncSnapshot get snapshot => container.read(syncProvider);

  int get gets => server.requests.where((r) => r.method == 'GET').length;

  /// What the server's sync file holds.
  Future<SyncDoc?> remote([String at = path, String? withKey]) async {
    final file = server.files[at];
    return file == null ? null : decryptSyncFile(file.text, unb64(withKey ?? key));
  }

  /// Another device writes the file.
  Future<void> otherDeviceWrites(List<OtpAccount> accounts) async =>
      server.put(path, await encryptSyncFile(SyncDoc(accounts: accounts), unb64(key)));

  /// The user changes the vault's lists.
  void userChanges(List<OtpAccount> accounts) {
    lists = Lists(accounts: accounts, backupServices: lists.backupServices);
    scheduler.userChanged();
  }
}

Future<Setup> setup({List<OtpAccount>? local, SyncSettings? settings, bool start = true}) async {
  final kv = KeyValueStore.memory();
  final server = FakeWebDav();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv), webDavProvider.overrideWithValue(WebDav(server.client))],
  );
  addTearDown(container.dispose);
  final vault = VaultStore(kv, container.read(vaultRegistryProvider), deriveKey: fastKdf);
  final session = await vault.setupVault('pw');
  final key = b64(randomBytes(32));
  await vault.saveEncryptedValue(
    'backmycodes_sync',
    (settings ??
            SyncSettings(
              personal: SyncTarget(dav: dav, file: syncFile, key: key),
            ))
        .toJson(),
    session,
  );
  final s = Setup._(container, server, session, FakeTimers(), key, Lists(accounts: local ?? [acct('phone')]));
  var clock = unlockedAt;
  s.scheduler = SyncScheduler(
    store: s.store,
    webDav: container.read(webDavProvider),
    session: session,
    getLists: () => s.lists,
    applySynced: (lists) async {
      s.applied.add(lists);
      s.lists = lists;
    },
    clock: () => clock = clock.add(const Duration(seconds: 1)),
    startTimer: s.timers.start,
    startPeriodicTimer: s.timers.periodic,
  );
  addTearDown(s.scheduler.dispose);
  if (start) {
    await s.scheduler.start();
    await s.scheduler.idle;
  }
  return s;
}

void main() {
  group('as SyncController.test.tsx', () {
    test('uploads this device’s accounts when the vault opens', () async {
      final s = await setup();

      expect(ids((await s.remote())!.accounts), ['phone']);
      expect(s.snapshot.status[personalScope]?.lastSyncAt, isNotNull);
      expect(s.snapshot.status[personalScope]?.problem, isNull);
      // Nothing came down, so there was nothing to take locally
      expect(s.applied, isEmpty);
    });

    test('takes what another device synced', () async {
      final s = await setup();
      // Another device writes the file; with no deletion recorded, both accounts survive
      await s.otherDeviceWrites([acct('tablet')]);

      s.store.requestSync();
      await s.scheduler.idle;

      expect(ids(s.lists.accounts), ['phone', 'tablet']);
      expect(s.applied, hasLength(1));
    });

    test('reports a problem instead of syncing, and keeps the local accounts', () async {
      final s = await setup();
      final lastSyncAt = s.snapshot.status[personalScope]?.lastSyncAt;
      s.server.respond = (_) async => http.Response('', 401);

      s.store.requestSync();
      await s.scheduler.idle;

      expect(s.snapshot.status[personalScope], ScopeStatus(lastSyncAt: lastSyncAt, problem: SyncProblem.auth));
      expect(ids(s.lists.accounts), ['phone']);
      expect(s.applied, isEmpty);
    });

    test('keeps the count of the file it synced, and stops at an older one the server hands back', () async {
      final s = await setup();
      final first = s.server.files[path]!.text;
      s.userChanges([acct('phone'), acct('laptop')]);
      s.timers.elapse(const Duration(seconds: 2));
      await s.scheduler.idle;
      expect((await s.remote())!.seq, 2);
      expect((await s.store.loadScopeStates(s.session))[personalScope]?.extra[seenSeqKey], 2);

      // The first file again, older than the one the phone wrote since
      s.server.put(path, first);
      s.store.requestSync();
      await s.scheduler.idle;

      expect(s.snapshot.status[personalScope]?.problem, SyncProblem.older);
      expect(ids(s.lists.accounts), ['laptop', 'phone']);
      expect(s.server.files[path]!.text, first);
      expect((await s.store.loadScopeStates(s.session))[personalScope]?.extra[seenSeqKey], 2);
    });
  });

  group('when it syncs', () {
    test('two seconds after the user’s last change', () async {
      final s = await setup();
      final before = s.gets;

      s.userChanges([acct('phone'), acct('one')]);
      s.timers.elapse(const Duration(milliseconds: 1500));
      s.userChanges([acct('phone'), acct('one'), acct('two')]);
      s.timers.elapse(const Duration(milliseconds: 1999));
      await s.scheduler.idle;
      expect(s.gets, before);

      s.timers.elapse(const Duration(milliseconds: 1));
      await s.scheduler.idle;

      expect(s.gets, before + 1);
      expect(ids((await s.remote())!.accounts), ['one', 'phone', 'two']);
      // What the user did is already there; nothing new to take
      expect(s.applied, isEmpty);
    });

    test('when the app comes back to the front', () async {
      final s = await setup();
      final before = s.gets;

      s.scheduler.setVisible(false);
      await s.scheduler.idle;
      expect(s.gets, before);

      s.scheduler.setVisible(true);
      await s.scheduler.idle;
      expect(s.gets, before + 1);
    });

    test('every five minutes while the app is in front', () async {
      final s = await setup();
      final before = s.gets;

      s.timers.elapse(syncPeriod - const Duration(seconds: 1));
      await s.scheduler.idle;
      expect(s.gets, before);
      s.timers.elapse(const Duration(seconds: 1));
      await s.scheduler.idle;
      expect(s.gets, before + 1);

      s.scheduler.setVisible(false);
      s.timers.elapse(syncPeriod * 2);
      await s.scheduler.idle;
      expect(s.gets, before + 1);
    });

    test('once settings are saved, as when a space is joined', () async {
      final s = await setup();
      final settings = s.snapshot.settings!;
      final spaceKey = b64(randomBytes(32));
      s.lists = Lists(
        accounts: [
          acct('phone'),
          acct('shared', spaceId: 'fam'),
        ],
      );

      await s.store.saveSettings(
        settings.copyWith(
          spaces: [
            Space(
              id: 'fam',
              name: 'Family',
              target: SyncTarget(dav: dav, file: spaceFile('fam'), key: spaceKey),
              joinedAt: 1,
            ),
          ],
        ),
        s.session,
      );
      await s.scheduler.idle;

      expect(ids((await s.remote('/files/me/Kemlock/${spaceFile('fam')}', spaceKey))!.accounts), ['shared']);
      expect(ids((await s.remote())!.accounts), ['phone']);
      expect(s.snapshot.status.keys, unorderedEquals([personalScope, 'fam']));
    });

    test('not when there is nothing to sync', () async {
      final s = await setup(settings: noSync);

      s.store.requestSync();
      await s.scheduler.idle;

      expect(s.server.requests, isEmpty);
      expect(s.snapshot.running, isFalse);
    });
  });

  group('each run', () {
    test('syncs the vault’s entries and each space’s to their own files', () async {
      final spaceKey = b64(randomBytes(32));
      final s = await setup(
        local: [
          acct('mine'),
          acct('shared', spaceId: 'fam'),
        ],
        settings: SyncSettings(
          personal: SyncTarget(dav: dav, file: syncFile, key: b64(randomBytes(32))),
          spaces: [
            Space(
              id: 'fam',
              name: 'Family',
              target: SyncTarget(dav: dav, file: spaceFile('fam'), key: spaceKey),
              joinedAt: 1,
            ),
          ],
        ),
      );
      final personalKey = s.snapshot.settings!.personal!.key;

      expect(ids((await s.remote(path, personalKey))!.accounts), ['mine']);
      expect(ids((await s.remote('/files/me/Kemlock/${spaceFile('fam')}', spaceKey))!.accounts), ['shared']);
      final states = await s.store.loadScopeStates(s.session);
      expect(states[personalScope]?.known, ['mine']);
      expect(states['fam']?.known, ['shared']);
      expect(states[personalScope]?.lastSyncAt, s.snapshot.status[personalScope]?.lastSyncAt);
    });

    test('leaves out a space that carries one of the vault’s own scope names', () async {
      final spaceKey = b64(randomBytes(32));
      final s = await setup(
        local: [
          acct('mine'),
          acct('theirs', spaceId: personalScope),
        ],
        settings: SyncSettings(
          personal: SyncTarget(dav: dav, file: syncFile, key: b64(randomBytes(32))),
          spaces: [
            Space(
              id: personalScope,
              name: 'Joined before invites were checked',
              target: SyncTarget(dav: dav, file: spaceFile(personalScope), key: spaceKey),
              joinedAt: 1,
            ),
          ],
        ),
      );

      // The space's file is never written, so the vault's own ids never reach it
      expect(await s.remote('/files/me/Kemlock/${spaceFile(personalScope)}', spaceKey), isNull);
      expect((await s.store.loadScopeStates(s.session))[personalScope]?.known, ['mine']);
    });

    test('keeps the vault’s and another space’s entries when a space’s file holds others under their ids', () async {
      final famKey = b64(randomBytes(32));
      final workKey = b64(randomBytes(32));
      const famPath = '/files/me/Kemlock/backmycodes-space-fam.json';
      const workPath = '/files/me/Kemlock/backmycodes-space-work.json';
      Space space(String id, String key) => Space(
        id: id,
        name: id,
        target: SyncTarget(dav: dav, file: spaceFile(id), key: key),
        joinedAt: 1,
      );
      final mine = acct('mine');
      final job = acct('job', spaceId: 'work');
      final s = await setup(
        local: [mine, job],
        settings: SyncSettings(
          personal: SyncTarget(dav: dav, file: syncFile, key: b64(randomBytes(32))),
          spaces: [space('fam', famKey), space('work', workKey)],
        ),
        start: false,
      );
      // Someone in the family space who knows both ids writes entries of their own under them, stamped far ahead
      final ahead = unlockedAt.add(const Duration(days: 365)).millisecondsSinceEpoch;
      OtpAccount planted(String id) => OtpAccount(id: id, issuer: id, label: '', secret: 'THEIRS', addedAt: 1, updatedAt: ahead);
      s.server.put(famPath, await encryptSyncFile(SyncDoc(accounts: [planted('mine'), planted('job')]), unb64(famKey)));

      await s.scheduler.start();
      await s.scheduler.idle;
      await s.scheduler.run();
      await s.scheduler.idle;

      // Both entries are where they were, as they were
      expect(s.lists.accounts, [mine, job]);
      final personal = (await s.remote(path, s.snapshot.settings!.personal!.key))!;
      expect(personal.accounts, [mine]);
      expect(personal.deleted, isEmpty);
      final work = (await s.remote(workPath, workKey))!;
      expect(ids(work.accounts), ['job']);
      expect(work.deleted, isEmpty);
      // The family space keeps what it was given: this phone never held it, so it deletes nothing there
      final fam = (await s.remote(famPath, famKey))!;
      expect([for (final account in fam.accounts) account.secret], ['THEIRS', 'THEIRS']);
      expect(fam.deleted, isEmpty);
      expect((await s.store.loadScopeStates(s.session))['fam']?.known, isEmpty);
    });

    test('keeps syncing the other scopes when one fails', () async {
      final spaceKey = b64(randomBytes(32));
      final s = await setup(
        local: [
          acct('mine'),
          acct('shared', spaceId: 'fam'),
        ],
        settings: SyncSettings(
          personal: SyncTarget(
            dav: dav.copyWith(url: 'http://dav.example.com/'),
            file: syncFile,
            key: b64(randomBytes(32)),
          ),
          spaces: [
            Space(
              id: 'fam',
              name: 'Family',
              target: SyncTarget(dav: dav, file: spaceFile('fam'), key: spaceKey),
              joinedAt: 1,
            ),
          ],
        ),
      );

      expect(s.snapshot.status[personalScope], const ScopeStatus(problem: SyncProblem.insecure));
      expect(s.snapshot.status['fam']?.problem, isNull);
      expect(ids((await s.remote('/files/me/Kemlock/${spaceFile('fam')}', spaceKey))!.accounts), ['shared']);
    });

    test('is dropped when it raced a change the user made, and runs again with it', () async {
      final s = await setup(start: false);
      await s.otherDeviceWrites([acct('tablet')]);
      // The user adds an account while the first run is reading the file
      s.server.beforeNextRequest(() => s.userChanges([acct('phone'), acct('new')]));

      await s.scheduler.start();
      await s.scheduler.idle;

      // Only the second run's result was taken, with the user's account in it
      expect(s.applied, hasLength(1));
      expect(ids(s.applied.single.accounts), ['new', 'phone', 'tablet']);
      expect(ids((await s.remote())!.accounts), ['new', 'phone', 'tablet']);
      expect(s.gets, 2);
    });

    test('waits for the one before, and a request meanwhile queues one more', () async {
      final s = await setup();
      var inFlight = 0;
      var most = 0;
      s.server.respond = (request) async {
        most = ++inFlight > most ? inFlight : most;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final res = await s.server.handle(request);
        inFlight--;
        return res;
      };
      final before = s.gets;
      final running = <bool>[];
      s.container.listen(syncProvider.select((sync) => sync.running), (_, now) => running.add(now));

      unawaited(s.scheduler.run());
      s.store.requestSync();
      s.store.requestSync();
      await s.scheduler.idle;

      expect(most, 1);
      expect(s.gets, before + 2);
      expect(running, [true, false, true, false]);
    });

    test('is dropped when the vault locks meanwhile', () async {
      final s = await setup(start: false);
      await s.otherDeviceWrites([acct('tablet')]);
      s.server.beforeNextRequest(s.scheduler.dispose);

      await s.scheduler.start();
      await s.scheduler.idle;

      expect(s.applied, isEmpty);
      expect(s.snapshot.settings, isNull);
      expect(s.snapshot.running, isFalse);
      expect(await s.store.loadScopeStates(s.session), isEmpty);
    });
  });

  group('when the vault locks', () {
    test('stops syncing and forgets the settings', () async {
      final s = await setup();
      final before = s.server.requests.length;
      s.userChanges([acct('phone'), acct('late')]);

      s.scheduler.dispose();
      s.store.requestSync();
      s.scheduler.setVisible(true);
      s.timers.elapse(syncPeriod * 2);
      await s.scheduler.idle;

      expect(s.server.requests, hasLength(before));
      expect(s.timers.pending, 0);
      expect(s.snapshot.settings, isNull);
    });

    test('leaves sync unloaded when its settings can’t be read', () async {
      final s = await setup(start: false);
      s.container.read(keyValueStoreProvider).setItem('backmycodes_sync', 'not json');

      await s.scheduler.start();
      s.store.requestSync();
      await s.scheduler.idle;

      expect(s.snapshot.settings, isNull);
      expect(s.server.requests, isEmpty);
    });
  });
}
