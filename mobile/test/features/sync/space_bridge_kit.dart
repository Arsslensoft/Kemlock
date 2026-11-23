// What the tests of the bridge of a moved WebDAV space share (docs/plans/add-server-spaces.md, tasks 8.2 to 8.5): the family's
// WebDAV file on the fake folder, the server space the mover made on the fake server, a moved member's phone that syncs both
// (`runBridged`), a phone that stays on WebDAV and runs the frozen merge of the version before keys, notes and logins
// (`test/compat/before_vault_items`), and another device that syncs the server space alone.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart' show expectLater, isA, throwsA;
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/spaces/km_server_spaces.dart';
import 'package:kemlock/features/spaces/space_move.dart' show SpaceMoveError;
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/features/sync/kemlock/km_account.dart';
import 'package:kemlock/features/sync/space_bridge_run.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_crypto.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../compat/before_vault_items/sync_merge.dart' as before;
import '../spaces/chain_kit.dart';
import '../spaces/fake_space_server.dart';
import '../spaces/space_move_kit.dart';
import 'fake_webdav.dart';

export '../spaces/space_move_kit.dart';

/// The family's WebDAV space, its file on a fake folder and its server space on a fake server, as the move leaves them.
class MovedFamily {
  MovedFamily._(this.server, this.dav, this.target, this.account);

  /// Writes the family's file the way today's sync does, from the family's entries, then moves the space with [account].
  ///
  /// With [markerWritten] false the move stops at its read-back, as one that failed it does: the space and its entries are on the
  /// server and the manifest is signed, but the marker that the move is whole is not written.
  static Future<MovedFamily> make(KmAccount account, {int accounts = 20, int logins = 20, bool markerWritten = true}) async {
    final server = FakeSpaceServer(familyUuid, ChainBuilder(familyUuid));
    final dav = FakeWebDav();
    final target = SyncTarget(dav: familyDav, file: spaceFile(familyId), key: newFileKey());
    final family = MovedFamily._(server, dav, target, account);
    final entries = familyEntries(accounts: accounts, logins: logins);
    family.mover.lists = Lists(accounts: entries.accounts, logins: entries.logins);
    // The file as a WebDAV space has it before anyone moves
    final first = await syncScope(WebDav(dav.client), target, scopeLists(family.mover.lists, familyId), const [], now: 1000);
    family.mover.state = ScopeState(known: first.known, lastSyncAt: 1000, extra: withSeenSeq({}, first.seq));
    final local = scopeLists(family.mover.lists, familyId);
    if (markerWritten) {
      await family.mover.source.moveSpace(appSpaceId: familyId, name: 'Family', local: local);
    } else {
      server.withheld.add(serverItemUuid('acc-7', familyUuid));
      await expectLater(family.mover.source.moveSpace(appSpaceId: familyId, name: 'Family', local: local), throwsA(isA<SpaceMoveError>()));
      server.withheld.clear();
    }
    return family;
  }

  final FakeSpaceServer server;
  final FakeWebDav dav;
  final SyncTarget target;
  final KmAccount account;

  /// The phone that moved the space, which syncs both copies.
  late final BridgedPhone mover = BridgedPhone(this, <String, Object?>{});

  WebDav get webDav => WebDav(dav.client);

  /// How many times the file was written, by anyone.
  int get fileWrites => dav.requests.where((request) => request.method == 'PUT').length;

  /// The family's file as it stands, opened.
  Future<SyncDoc> file() async => decryptSyncFile(dav.files[familyFilePath]!.text, unb64(target.key));

  /// What a plain read of the file's plaintext is: the exact JSON text its writer sealed.
  Future<String> filePlaintext() async => jsonEncode((await file()).toJson());

  /// A phone of the account that syncs the server space alone, under the server's id for it.
  ServerPhone serverPhone() => ServerPhone(this, comparedStore(server));

  /// A phone that stays on the previous version and syncs the file alone with its frozen merge.
  OlderPhone olderPhone() => OlderPhone(this);
}

/// A moved member's phone: the WebDAV space under its WebDAV id, synced both ways.
class BridgedPhone {
  BridgedPhone(this.family, this.store);

  final MovedFamily family;
  final Map<String, Object?> store;
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);

  late final KmServerSpaces source = sourceOn(family.server, family.account, store);

  /// Runs the bridge once, as the scheduler does: the space's entries in, the merged document taken back.
  Future<BridgedRun> run({required int now, bool writeFile = true, BridgeServerRun? server, WebDav? webDav}) async {
    final run = await runBridged(
      webDav: webDav ?? family.webDav,
      target: family.target,
      scope: familyId,
      local: scopeLists(lists, familyId),
      state: state,
      now: now,
      writeFile: writeFile,
      server: server ?? (entries, kept) => source.syncSpace(familyUuid, rescopedTo(entries, familyUuid), kept, now: now, bridged: true),
    );
    lists = applyScope(lists, familyId, run.doc);
    state = ScopeState(known: run.known, lastSyncAt: now, extra: run.state);
    return run;
  }

  /// The account with [id], as this phone holds it.
  OtpAccount account(String id) => lists.accounts.firstWhere((account) => account.id == id);
}

/// A phone that syncs the server space alone, as a member who began on the server does: its scope is the server's UUID.
class ServerPhone {
  ServerPhone(this.family, this.store);

  final MovedFamily family;
  final Map<String, Object?> store;
  Lists lists = const Lists();
  ScopeState state = const ScopeState(known: []);

  late final KmServerSpaces source = sourceOn(family.server, family.account, store);

  Future<void> run({required int now}) async {
    final result = await source.syncSpace(familyUuid, scopeLists(lists, familyUuid), state, now: now);
    lists = applyScope(lists, familyUuid, result.doc);
    state = ScopeState(known: result.known, lastSyncAt: now, extra: result.state);
  }

  OtpAccount account(String id) => lists.accounts.firstWhere((account) => account.id == id);

  /// Edits the account [id] as this phone's user does: new fields, stamped [at].
  void edit(String id, {String? issuer, required int at}) {
    lists = Lists(
      accounts: [
        for (final account in lists.accounts)
          if (account.id == id) account.copyWith(issuer: issuer, updatedAt: at) else account,
      ],
      logins: lists.logins,
    );
  }

  /// Adds the account [id], new at [at], in the server's space.
  void add(String id, {required int at}) {
    lists = Lists(
      accounts: [
        ...lists.accounts,
        OtpAccount(id: id, issuer: 'Issuer $id', label: 'me', secret: 'JBSWY3DPEHPK3PXP', spaceId: familyUuid, addedAt: at, updatedAt: at),
      ],
      logins: lists.logins,
    );
  }

  /// Deletes the account [id].
  void delete(String id) {
    lists = Lists(
      accounts: [
        for (final account in lists.accounts)
          if (account.id != id) account,
      ],
      logins: lists.logins,
    );
  }
}

/// A phone that stays on the version before keys, notes and logins: it merges accounts and backup codes with the frozen merge,
/// and passes every other list through as the file holds it.
class OlderPhone {
  OlderPhone(this.family);

  final MovedFamily family;
  List<OtpAccount> accounts = [];
  List<String> known = [];

  /// Syncs the file as the previous version does: reads it, merges this phone's accounts, writes it back.
  Future<void> sync({required int now}) async {
    final key = unb64(family.target.key);
    final stored = family.dav.files[familyFilePath];
    final remote = stored == null ? null : before.SyncDoc.fromJson((await decryptSyncFile(stored.text, key)).toJson());
    final merged = before.mergeScope(before.Lists(accounts: accounts), known, remote, now: now);
    final doc = SyncDoc.fromJson(jsonDecode(jsonEncode(merged.doc.toJson())) as Map<String, Object?>);
    family.dav.put(familyFilePath, await encryptSyncFile(doc, key));
    accounts = merged.doc.accounts;
    known = merged.known;
  }

  /// Edits the account [id]: a new issuer, stamped [at].
  void edit(String id, {required String issuer, required int at}) {
    accounts = [
      for (final account in accounts)
        if (account.id == id) account.copyWith(issuer: issuer, updatedAt: at) else account,
    ];
  }

  /// Adds the account [id], new at [at], in the space the file is of.
  void add(String id, {required int at}) {
    accounts = [
      ...accounts,
      OtpAccount(id: id, issuer: 'Issuer $id', label: 'me', secret: 'JBSWY3DPEHPK3PXP', spaceId: familyId, addedAt: at, updatedAt: at),
    ];
  }

  void delete(String id) {
    accounts = [
      for (final account in accounts)
        if (account.id != id) account,
    ];
  }

  OtpAccount? account(String id) => accounts.where((account) => account.id == id).firstOrNull;
}
