// The first step of a move (move-off-vaultwarden-sync, task 3.1): the old store's ordinary run, with files,
// merged into the vault before anything is copied; a run that stops stops the move with its own error.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/attachment_sync.dart';
import 'package:kemlock/features/sync/kemlock/km_move_plan.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock/km_move_source.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_api.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_codec.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_sync.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/secure_note.dart';

import '../../../fakes/fake_attachments.dart';
import '../fake_webdav.dart';
import '../vaultwarden/fake_vaultwarden.dart';
import '../vaultwarden/vw_kit.dart';

final _owner = Owner.user('00000000-0000-4000-8000-000000000001');

OtpAccount _account(String id, {String? issuer}) =>
    OtpAccount(id: id, issuer: issuer ?? id, label: 'me@example.com', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1);

VaultwardenScopeSync _scope(FakeVaultwarden server, VaultwardenTarget target) => VaultwardenScopeSync(
  connection: VwConnection(
    api: VwApi(server.client),
    server: FakeVaultwarden.url,
    credentials: server.credentials(),
    onCredentials: (_) async {},
  ),
  reader: VwReader(server.userKey),
  target: target,
);

VaultwardenMoveSource _source(FakeVaultwarden server, VaultwardenTarget target) => VaultwardenMoveSource(
  target: target,
  run: (local, state, {required now, choice}) => _scope(server, target).sync(local, state, now: now, choice: choice),
);

void main() {
  group('a Vaultwarden home', () {
    test('merges an entry another device added into the vault, so the plan holds it', () async {
      final server = FakeVaultwarden();
      final target = await makeHome(server, VaultwardenMode.sealed);
      await _scope(server, target).sync(
        Lists(accounts: [_account('orbit-1', issuer: 'Orbit')]),
        const ScopeState(known: []),
        now: server.revision + 500,
      );

      final synced = await _source(server, target).sync(
        Lists(accounts: [_account('github-1')]),
        const ScopeState(known: []),
        now: server.revision + 1000,
      );

      expect(synced.doc.accounts.map((a) => a.id), unorderedEquals(['orbit-1', 'github-1']));
      expect(planKmMove(synced.doc, _owner).items.map((item) => item.entryId), unorderedEquals(['orbit-1', 'github-1']));
      expect(synced.known, unorderedEquals(['orbit-1', 'github-1']));
    });

    test('says which home it is, for the record', () async {
      final server = FakeVaultwarden();
      final target = await makeHome(server, VaultwardenMode.plain);

      final source = _source(server, target);

      expect(source.name, vaultwardenSource);
      expect(source.home, target.home);
      expect(source.mode, 'plain');
      expect(source.server, FakeVaultwarden.url.toString());
    });

    test('stops with the guard error when the run would remove many entries', () async {
      final server = FakeVaultwarden();
      final target = await makeHome(server, VaultwardenMode.sealed);
      final ids = [for (var i = 0; i < 8; i++) 'acc-$i'];
      // This phone held all eight at its last run, a moment ago, and the home holds none now. The date
      // matters: a deletion older than the tombstone lifetime is forgotten by the merge, not removed
      final local = Lists(accounts: [for (final id in ids) _account(id)]);

      await expectLater(
        _source(server, target).sync(
          local,
          ScopeState(known: ids, lastSyncAt: server.revision),
          now: server.revision + 500,
        ),
        throwsA(isA<VwSyncError>().having((e) => e.issue, 'issue', VwSyncIssue.removals)),
      );
      expect(problemOf(const VwSyncError(VwSyncIssue.removals)), SyncProblem.removals);
    });
  });

  group('a WebDAV personal vault', () {
    const dav = DavAccount(url: 'https://dav.example.com/files/me/Kemlock/', username: 'me', password: 'app-pw');
    final key = b64(Uint8List.fromList(List.generate(32, (i) => i)));
    final target = SyncTarget(dav: dav, file: syncFile, key: key);

    test('merges what another phone wrote, and fetches the file its note names that this phone lacks', () async {
      final server = FakeWebDav();
      final webDav = WebDav(server.client);
      // Another phone's note with one file, as it would have uploaded them
      final fileKey = randomBytes(32);
      final other = FakeAttachmentStore();
      await other.write('main', 'f1', Uint8List.fromList(utf8.encode('passport scan')), fileKey);
      final note = SecureNote(
        id: 'n1',
        title: 'Passport',
        addedAt: 1,
        attachments: [NoteAttachment(id: 'f1', name: 'scan.txt', size: 13, key: b64(fileKey), addedAt: 1)],
      );
      await syncScope(webDav, target, Lists(notes: [note]), const [], now: 5000);
      server.blobs['/files/me/Kemlock/${syncedFileName('f1')}'] = (await other.readSealed('main', 'f1'))!;
      final mine = FakeAttachmentStore();
      final source = WebDavMoveSource(
        webDav: webDav,
        target: target,
        files: AttachmentSync(webDav: webDav, store: mine, vaultId: 'main'),
      );

      final synced = await source.sync(Lists(accounts: [_account('a1')]), const ScopeState(known: []), now: 10000);

      expect(synced.doc.notes.map((n) => n.id), ['n1']);
      expect(synced.doc.accounts.map((a) => a.id), ['a1']);
      expect(await mine.exists('main', 'f1'), isTrue, reason: 'the move cannot reach its check while a named file is missing');
      expect(await mine.readSealed('main', 'f1'), await other.readSealed('main', 'f1'));
      expect(source.name, webdavSource);
      expect(source.home, isNull);
    });

    test('leaves a file the folder lacks missing, for the files step to name', () async {
      final server = FakeWebDav();
      final webDav = WebDav(server.client);
      final note = SecureNote(
        id: 'n1',
        title: 'Passport',
        addedAt: 1,
        attachments: [NoteAttachment(id: 'gone', name: 'scan.txt', size: 13, key: b64(randomBytes(32)), addedAt: 1)],
      );
      await syncScope(webDav, target, Lists(notes: [note]), const [], now: 5000);
      final mine = FakeAttachmentStore();

      await WebDavMoveSource(
        webDav: webDav,
        target: target,
        files: AttachmentSync(webDav: webDav, store: mine, vaultId: 'main'),
      ).sync(const Lists(), const ScopeState(known: []), now: 10000);

      expect(await mine.exists('main', 'gone'), isFalse);
    });
  });
}
