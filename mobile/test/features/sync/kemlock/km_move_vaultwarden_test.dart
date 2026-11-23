// A move from a Vaultwarden home to the fake Kemlock Server, end to end (move-off-vaultwarden-sync, tasks 4.3
// and 4.4): a sealed home is closed and can be gone back to; a plain home stays as a Bitwarden copy that keeps
// syncing beside the Kemlock API, nothing is trashed, and logins never reach it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bitwarden.dart';
import 'package:kemlock/features/sync/kemlock/km_cache.dart';
import 'package:kemlock/features/sync/kemlock/km_move.dart';
import 'package:kemlock/features/sync/kemlock/km_move_back.dart';
import 'package:kemlock/features/sync/kemlock/km_move_old_store.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock/km_move_source.dart';
import 'package:kemlock/features/sync/kemlock/km_sync.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_backend.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/models/login.dart';

import '../vaultwarden/fake_vaultwarden.dart';
import '../vaultwarden/vw_kit.dart';
import 'fake_kemlock_server.dart';
import 'km_move_kit.dart';
import 'km_phone_kit.dart';
import 'km_sync_kit.dart';

/// One phone whose vault syncs with a Vaultwarden home and moves to Kemlock Server.
class _Phone {
  _Phone(this.vw, this.target, this.rig, {required this.lists});

  final FakeVaultwarden vw;
  final VaultwardenTarget target;
  final MoveRig rig;
  Lists lists;
  ScopeState vwState = const ScopeState(known: []);
  ScopeState kmState = const ScopeState(known: []);
  Object? kmCache;
  final values = KmMemoryValues();
  var _tick = 0;

  int get now => moveNow + (++_tick) * 60000;

  VwConnection get connection =>
      VwConnection(api: VwApi(vw.client), server: FakeVaultwarden.url, credentials: vw.credentials(), onCredentials: (_) async {});

  VaultwardenScopeSync get _vwScope => VaultwardenScopeSync(connection: connection, reader: VwReader(vw.userKey), target: target);

  KmScopeSync get _kmScope => KmScopeSync(
    connection: rig.connection,
    server: FakeKemlockServer.url,
    crypto: rig.crypto,
    loadCache: () async => KmCache.fromJson(kmCache == null ? null : jsonDecode(jsonEncode(kmCache))),
    saveCache: (cache) async => kmCache = jsonDecode(jsonEncode(cache.toJson())),
  );

  /// The first sync with the home, before the move.
  Future<void> syncVaultwarden() async {
    final result = await _vwScope.sync(lists, vwState, now: now);
    lists = applyScope(lists, null, result.doc);
    vwState = ScopeState(known: result.known, lastSyncAt: moveNow, extra: result.state);
  }

  /// What the scheduler does with both scopes after a plain home's move.
  Future<void> syncBoth() async {
    final at = now;
    final vwResult = await _vwScope.sync(lists, vwState, now: at);
    lists = applyScope(lists, null, vwResult.doc);
    vwState = ScopeState(known: vwResult.known, lastSyncAt: at, extra: {...vwResult.state, copyOfKey: true});
    final kmResult = await _kmScope.sync(kmTarget, lists, kmState, now: at);
    lists = applyScope(lists, null, kmResult.doc);
    kmState = ScopeState(known: kmResult.known, lastSyncAt: at, extra: kmResult.state);
  }

  KmMoveRunner runner() => KmMoveRunner(
    store: KmMoveStore(values),
    source: VaultwardenMoveSource(
      target: target,
      run: (local, state, {required now, choice}) => VaultwardenScopeSync(
        connection: connection,
        reader: VwReader(vw.userKey),
        target: target,
      ).sync(local, state, now: now, choice: choice),
    ),
    server: rig.moveServer,
    files: FakeFileStore(),
    oldStore: VaultwardenOldStore(
      mode: target.mode,
      close: (confirmed) => VwAccountSetup.closeHome(connection, target, confirmed: confirmed),
    ),
    lists: () => lists,
    oldState: () async => vwState,
    applySynced: (synced) async {
      lists = synced.doc;
      vwState = ScopeState(known: synced.known, lastSyncAt: moveNow, extra: synced.state);
    },
    onOldStore: (result) async {
      if (result.outcome == KmOldStore.copyKept) vwState = markedAsCopy(vwState);
    },
    clock: () => DateTime.fromMillisecondsSinceEpoch(moveNow),
  );
}

Future<_Phone> _phone(VaultwardenMode mode, Lists lists) async {
  final vw = FakeVaultwarden();
  final target = await makeHome(vw, mode);
  final phone = _Phone(vw, target, MoveRig(), lists: lists);
  await phone.syncVaultwarden();
  return phone;
}

/// What a Bitwarden app does to an item's name.
Future<void> _rename(FakeVaultwarden vw, String id, String name) async =>
    vw.put({...vw.ciphers[id]!, 'name': await bwEncryptString(name, vw.userKey)}, id: id);

Future<String> _cipherNamed(FakeVaultwarden vw, String name) async {
  for (final cipher in vw.ciphers.values) {
    if (cipher['deletedDate'] == null && await bwDecryptString(cipher['name']! as String, vw.userKey) == name) {
      return cipher['id']! as String;
    }
  }
  throw StateError('no item named $name');
}

void main() {
  test('closes a sealed home after the move, and going back restores it and keeps the kem1 items', () async {
    final phone = await _phone(VaultwardenMode.sealed, Lists(accounts: [for (var i = 1; i <= 3; i++) account(uuidN(i))]));

    final outcome = await phone.runner().run();

    expect(outcome.record.closed, isTrue);
    expect(outcome.oldStore!.outcome, KmOldStore.closed);
    expect(
      phone.vw.ciphers.values.every((cipher) => cipher['deletedDate'] != null),
      isTrue,
      reason: 'the home note and 3 items are in the trash',
    );
    expect(phone.rig.server.items, hasLength(3));
    final revisions = {for (final item in phone.rig.server.items.values) item.id: item.revision};

    final back = await goBackToVaultwarden(
      record: outcome.record,
      target: phone.target,
      settings: const SyncSettings(kemlock: kmTarget),
      restore: () => VwAccountSetup.restoreHome(phone.connection, phone.target),
      now: DateTime.fromMillisecondsSinceEpoch(moveNow).add(const Duration(days: 1)),
    );

    expect(back.restored, 3);
    expect(back.settings.kemlock, isNull);
    expect(back.settings.vaultwarden, phone.target);
    expect(back.record.closed, isFalse);
    expect(phone.vw.ciphers.values.every((cipher) => cipher['deletedDate'] == null), isTrue);
    expect(
      {for (final item in phone.rig.server.items.values) item.id: item.revision},
      revisions,
      reason: 'the kem1 items stay as they were',
    );
    expect(kmGoBackOffered(back.record, DateTime.fromMillisecondsSinceEpoch(moveNow)), isFalse, reason: 'offered once');
  });

  test('refuses to go back after the window', () async {
    final phone = await _phone(VaultwardenMode.sealed, Lists(accounts: [account(uuidN(1))]));
    final outcome = await phone.runner().run();

    await expectLater(
      goBackToVaultwarden(
        record: outcome.record,
        target: phone.target,
        settings: const SyncSettings(),
        restore: () async => 0,
        now: DateTime.fromMillisecondsSinceEpoch(moveNow).add(const Duration(days: 31)),
      ),
      throwsStateError,
    );
  });

  test('keeps a plain home as a copy: nothing is trashed, logins make no plain item, and both scopes keep syncing', () async {
    final phone = await _phone(
      VaultwardenMode.plain,
      Lists(
        accounts: [account(uuidN(1), issuer: 'GitHub')],
        logins: [Login(id: uuidN(5), name: 'Site', username: 'me', password: 'pw', addedAt: 1)],
      ),
    );
    final plainItems = phone.vw.ciphers.length;

    final outcome = await phone.runner().run();

    expect(outcome.oldStore!.outcome, KmOldStore.copyKept);
    expect(outcome.record.closed, isFalse);
    expect(isCopyScope(phone.vwState), isTrue, reason: 'the scope is marked as the copy');
    expect(phone.vw.ciphers.values.where((cipher) => cipher['deletedDate'] != null), isEmpty, reason: 'nothing is trashed');
    expect(phone.vw.ciphers, hasLength(plainItems), reason: 'the login made no plain item');
    expect(phone.rig.server.items, hasLength(2), reason: 'the account and the login are kem1 items');
    phone
      ..kmState = ScopeState(known: outcome.record.sent.keys.toList(), lastSyncAt: moveNow)
      ..kmCache = outcome.cache!.toJson();

    // A Bitwarden app renames the item: the next sync of both reaches the kem1 item
    await _rename(phone.vw, await _cipherNamed(phone.vw, 'GitHub'), 'GitHub (work)');
    await phone.syncBoth();

    expect(phone.lists.accounts.single.issuer, 'GitHub (work)');
    final stored = (await phone.rig.read()).items[phone.rig.itemUuidOf(uuidN(1))]!;
    expect(stored.entry!['issuer'], 'GitHub (work)');

    // An edit on the phone reaches the plain item, whose other fields stay
    final edited = phone.lists.accounts.single;
    phone.lists = Lists(
      accounts: [edited.copyWith(note: 'my note', updatedAt: moveNow + 10 * 60 * 60000)],
      logins: phone.lists.logins,
    );
    await phone.syncBoth();

    final plain = phone.vw.ciphers[await _cipherNamed(phone.vw, 'GitHub (work)')]!;
    expect(await bwDecryptString(plain['notes']! as String, phone.vw.userKey), 'my note');
    final login = plain['login']! as Map<String, Object?>;
    expect(
      await bwDecryptString(login['totp']! as String, phone.vw.userKey),
      contains('secret=JBSWY3DPEHPK3PXP'),
      reason: 'the code is intact',
    );
    expect(phone.vw.ciphers.values.where((cipher) => cipher['deletedDate'] != null), isEmpty);
    expect(phone.vw.ciphers, hasLength(plainItems));
    expect((await phone.rig.read()).items[phone.rig.itemUuidOf(uuidN(1))]!.entry!['note'], 'my note');
  });
}
