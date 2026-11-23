// What the Spaces sheet does for a WebDAV space that moves to Kemlock Server (docs/plans/add-server-spaces.md, tasks 8.1 and 8.4):
// the move, which leaves the space on WebDAV when it fails, and the Owner's close, with its warning and its offer to delete the
// file. The mover is a fake, so no server is involved; the folder is the fake one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/legacy_ids.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/spaces/server_spaces_list.dart';
import 'package:kemlock/features/spaces/space_bridge.dart';
import 'package:kemlock/features/spaces/space_move.dart';
import 'package:kemlock/features/sync/spaces_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../helpers/test_app.dart';
import 'sync_screen_kit.dart';

const _dav = DavAccount(url: folder, username: 'me', password: 'app-pw');
const _id = 'fam-01';

/// A mover that records what it was asked and fails when told to.
class _FakeMover implements SpaceMover {
  Object? failure;
  final moved = <String>[];
  final closed = <String>[];

  @override
  Future<SpaceMoveResult> moveSpace({
    required String appSpaceId,
    required String name,
    required Lists local,
    void Function(SpaceMoveStep step, int done, int total)? onProgress,
  }) async {
    moved.add(appSpaceId);
    if (failure case final failure?) {
      throw failure;
    }
    return (uuid: spaceUuid(appSpaceId), moved: local.ids.length, doc: local);
  }

  @override
  Future<void> closeCopy(String appSpaceId) async {
    closed.add(appSpaceId);
    if (failure case final failure?) {
      throw failure;
    }
  }
}

Space _space({SpaceOnServer? note}) {
  final space = Space(
    id: _id,
    name: 'Family',
    target: SyncTarget(dav: _dav, file: spaceFile(_id), key: b64(randomBytes(32))),
    joinedAt: 1,
  );
  return note == null ? space : space.withOnServer(note);
}

OtpAccount _account(String id) => OtpAccount(id: id, issuer: id, label: '', secret: 'JBSWY3DPEHPK3PXP', spaceId: _id, addedAt: 1);

/// A source that lists server spaces from a fixed list, as the vault's server answers.
class _ListSource implements ServerSpacesSource {
  _ListSource(this.entries);

  final List<ServerSpaceEntry> entries;

  @override
  Future<List<ServerSpaceEntry>> load() async => entries;

  @override
  Widget sheetFor(ServerSpaceEntry entry) => Text('sheet of ${entry.name}');

  @override
  Future<ServerSpaceEntry> make(String name) async => throw UnimplementedError();
}

/// The card of the space named Family.
Finder _card() => find
    .ancestor(
      of: find.text('Family'),
      matching: find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Family'),
    )
    .first;

Future<void> _tapOnCard(WidgetTester tester, String label) async {
  final button = find.descendant(of: _card(), matching: find.text(label));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<SyncSheetKit> _open(WidgetTester tester, _FakeMover mover, Space space) async {
  final kit = SyncSheetKit();
  await kit.pump(tester, showSpacesSheet, overrides: [spaceMoverProvider.overrideWithValue(mover)]);
  await kit.save(SyncSettings(spaces: [space]));
  await kit.vault.applySynced(Lists(accounts: [_account('acc-1'), _account('acc-2')]));
  await kit.open(tester);
  return kit;
}

void main() {
  testWidgets('offers to move a WebDAV space, asks first, and says where its copies stand once it moved', (tester) async {
    final mover = _FakeMover();
    final kit = await _open(tester, mover, _space());

    expect(find.descendant(of: _card(), matching: find.text(t('spaces.move'))), findsOneWidget);
    await _tapOnCard(tester, t('spaces.move'));
    expect(find.text(t('spaces.move.title', {'name': 'Family'})), findsOneWidget, reason: 'it asks first');
    expect(mover.moved, isEmpty);
    await tapButton(tester, t('spaces.move.confirm'));

    expect(mover.moved, [_id]);
    final note = kit.settings!.spaces.single.onServer!;
    expect(note.state, SpaceCopy.bridged);
    expect(note.uuid, spaceUuid(_id));
    expect(find.text(t('spaces.copy.row', {'state': 'bridged'})), findsOneWidget);
    expect(find.descendant(of: _card(), matching: find.text(t('spaces.move'))), findsNothing);
    expect(find.descendant(of: _card(), matching: find.text(t('spaces.copy.close'))), findsOneWidget);
    expect(kit.settings!.spaces.single.target.file, spaceFile(_id), reason: 'what the file and an invite are made from is untouched');
    expect(kit.settings!.spaces.single.target.dav, _dav);
  });

  testWidgets('a move that fails its check keeps the space on WebDAV, says so, and can be tried again', (tester) async {
    final mover = _FakeMover()..failure = const SpaceMoveError(SpaceMoveProblem.mismatch);
    final kit = await _open(tester, mover, _space());

    await _tapOnCard(tester, t('spaces.move'));
    await tapButton(tester, t('spaces.move.confirm'));

    expect(find.text(t('spaces.move.failed', {'problem': 'mismatch'})), findsOneWidget);
    final space = kit.settings!.spaces.single;
    expect(space.onServer!.state, SpaceCopy.moving, reason: 'marked before anything went up, never bridged');
    expect(space.movedToServer, isFalse, reason: 'still a WebDAV space');
    expect(
      find.descendant(of: _card(), matching: find.text(t('spaces.move'))),
      findsOneWidget,
      reason: 'it can be tried again',
    );
    expect(kit.server.requests, isEmpty, reason: 'nothing was written to the folder');
  });

  testWidgets('offers no move without Kemlock Server', (tester) async {
    final kit = SyncSheetKit();
    await kit.pump(tester, showSpacesSheet);
    await kit.save(SyncSettings(spaces: [_space()]));
    await kit.open(tester);

    expect(find.text(t('spaces.move')), findsNothing);
  });

  testWidgets('the Owner closes the copy after a warning, the file stays, and deleting it is offered and asked', (tester) async {
    final mover = _FakeMover();
    final space = _space(
      note: SpaceOnServer(state: SpaceCopy.bridged, uuid: spaceUuid(_id), at: 1),
    );
    final kit = await _open(tester, mover, space);
    kit.server.put(folderPath(space.target.file), 'the file as it was');

    await _tapOnCard(tester, t('spaces.copy.close'));
    expect(find.text(t('spaces.copy.close.body')), findsOneWidget, reason: 'the warning comes before the close');
    expect(mover.closed, isEmpty);
    await tapButton(tester, t('spaces.copy.close.confirm'));

    expect(mover.closed, [_id]);
    final note = kit.settings!.spaces.single.onServer!;
    expect(note.state, SpaceCopy.closed);
    expect(note.reason, SpaceCopyClosed.owner);
    expect(find.byKey(const ValueKey('space-closed-$_id')), findsOneWidget);
    final said = tester.widget<Text>(find.byKey(const ValueKey('space-closed-$_id'))).data!;
    expect(said, contains(t('spaces.copy.closed', {'reason': 'owner'})));
    expect(said, contains(t('spaces.copy.closed.kept')), reason: 'the warning that the old invite still reads the file as it was');
    expect(kit.server.files[folderPath(space.target.file)]!.text, 'the file as it was', reason: 'the file stays as it was');
    expect(
      find.descendant(of: _card(), matching: find.text(t('spaces.invite'))),
      findsNothing,
      reason: 'an invite to a closed file is no use',
    );

    // Deleting it is an offer: declining leaves it
    await _tapOnCard(tester, t('spaces.copy.delete'));
    expect(find.text(t('spaces.copy.delete.title')), findsOneWidget);
    await tapButton(tester, t('changePw.cancel'));
    expect(kit.server.files.containsKey(folderPath(space.target.file)), isTrue);
    expect(kit.settings!.spaces.single.onServer!.fileDeleted, isFalse);

    await _tapOnCard(tester, t('spaces.copy.delete'));
    await tapButton(tester, t('spaces.copy.delete.confirm'));
    expect(kit.server.files.containsKey(folderPath(space.target.file)), isFalse);
    expect(kit.settings!.spaces.single.onServer!.fileDeleted, isTrue);
    expect(find.descendant(of: _card(), matching: find.text(t('spaces.copy.delete'))), findsNothing);
  });

  testWidgets('a close that the account may not make is refused and leaves the copy open', (tester) async {
    final mover = _FakeMover()..failure = const SpaceMoveError(SpaceMoveProblem.notOwner);
    final space = _space(
      note: SpaceOnServer(state: SpaceCopy.bridged, uuid: spaceUuid(_id), at: 1),
    );
    final kit = await _open(tester, mover, space);

    await _tapOnCard(tester, t('spaces.copy.close'));
    await tapButton(tester, t('spaces.copy.close.confirm'));

    expect(find.text(t('spaces.copy.closeFailed', {'problem': 'notOwner'})), findsOneWidget);
    expect(kit.settings!.spaces.single.onServer!.state, SpaceCopy.bridged);
  });

  for (final entry in {
    SpaceCopy.moving: true,
    SpaceCopy.offered: true,
    SpaceCopy.bridged: false,
    SpaceCopy.joining: false,
    SpaceCopy.joined: false,
    SpaceCopy.closed: false,
  }.entries) {
    testWidgets('offers ${entry.value ? 'an' : 'no'} Invite on a ${entry.key.name} space', (tester) async {
      final note = SpaceOnServer(state: entry.key, uuid: spaceUuid(_id), at: 1);
      await _open(tester, _FakeMover(), _space(note: note));

      expect(find.descendant(of: _card(), matching: find.text(t('spaces.invite'))), entry.value ? findsOneWidget : findsNothing);
    });
  }

  for (final entry in {SpaceCopy.bridged: false, SpaceCopy.joined: false, SpaceCopy.offered: true, SpaceCopy.moving: true}.entries) {
    testWidgets('lists the server space of an invitation on a ${entry.key.name} space: ${entry.value}', (tester) async {
      final uuid = spaceUuid(_id);
      final source = _ListSource([(id: uuid, name: 'Family', status: 'invited')]);
      final kit = SyncSheetKit();
      await kit.pump(tester, showSpacesSheet, overrides: [serverSpacesSourceProvider.overrideWithValue(source)]);
      await kit.save(
        SyncSettings(
          spaces: [
            _space(
              note: SpaceOnServer(state: entry.key, uuid: uuid, at: 1),
            ),
          ],
        ),
      );
      await kit.open(tester);

      expect(
        find.byKey(ValueKey('server-space-open-$uuid')),
        entry.value ? findsOneWidget : findsNothing,
        reason: 'only a space whose note says it is on the server is hidden from the list',
      );
    });
  }

  testWidgets('lists an invitation to a space this phone holds only in WebDAV, so it can be accepted on this phone', (tester) async {
    final uuid = spaceUuid(_id);
    final source = _ListSource([(id: uuid, name: 'Family', status: 'invited')]);
    final kit = SyncSheetKit();
    await kit.pump(tester, showSpacesSheet, overrides: [serverSpacesSourceProvider.overrideWithValue(source)]);
    await kit.save(SyncSettings(spaces: [_space()]));
    await kit.open(tester);

    expect(find.byKey(ValueKey('server-space-status-$uuid')), findsOneWidget);
    expect(find.text(t('spaces.server.row', {'status': 'invited'})), findsOneWidget);
  });

  testWidgets('an offered server space names its Owner, asks before merging, and then counts as the server space’s', (tester) async {
    final mover = _FakeMover();
    final space = _space(
      note: SpaceOnServer(state: SpaceCopy.offered, uuid: spaceUuid(_id), at: 1, owner: 'Sam'),
    );
    final kit = await _open(tester, mover, space);

    expect(find.text(t('spaces.merge.found', {'owner': 'Sam'})), findsOneWidget, reason: 'the Owner is named');
    expect(
      find.descendant(of: _card(), matching: find.text(t('spaces.move'))),
      findsNothing,
      reason: 'it is no space to move',
    );
    await _tapOnCard(tester, t('spaces.merge'));
    expect(find.text(t('spaces.merge.title', {'name': 'Family'})), findsOneWidget, reason: 'it asks first');
    expect(find.text(t('spaces.merge.body', {'name': 'Family', 'owner': 'Sam'})), findsOneWidget);
    await tapButton(tester, t('changePw.cancel'));
    expect(kit.settings!.spaces.single.onServer!.state, SpaceCopy.offered, reason: 'declining merges nothing');

    await _tapOnCard(tester, t('spaces.merge'));
    await tapButton(tester, t('spaces.merge.confirm'));
    expect(kit.settings!.spaces.single.onServer!.state, SpaceCopy.joining);
    expect(kit.settings!.spaces.single.movedToServer, isTrue, reason: 'its entries are a server space’s from now on');
  });
}
