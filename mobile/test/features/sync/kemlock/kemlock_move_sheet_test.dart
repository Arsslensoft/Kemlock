// The move's screens (move-off-vaultwarden-sync, tasks 7.1 and 7.2): what moves and what stays before anything is
// written, the progress by step over a fake runner, the result with Go back to Vaultwarden, and that closing the sheet
// never stops the move.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/kemlock/km_auth_api.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_move.dart';
import 'package:kemlock/features/sync/kemlock/km_move_record.dart';
import 'package:kemlock/features/sync/kemlock/km_move_server.dart';
import 'package:kemlock/features/sync/kemlock_copy.dart';
import 'package:kemlock/features/sync/kemlock_host_factory.dart';
import 'package:kemlock/features/sync/kemlock_move.dart';
import 'package:kemlock/features/sync/kemlock_move_sheet.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_merge.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_models.dart';
import 'package:kemlock/features/sync/webdav.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/secure_note.dart';

import '../../../helpers/test_app.dart';
import '../../export/transfer_harness.dart' show tapOn;
import '../sync_screen_kit.dart';

const _kemlock = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com:8443')],
  deviceId: '00000000-0000-4000-8000-0000000000d1',
);

VaultwardenTarget _home(VaultwardenMode mode) =>
    VaultwardenTarget(server: 'https://kem.example.com:8443', email: 'me@example.com', home: 'home-1', mode: mode, folderId: 'folder-1');

final _pixel = KmDevice(id: 'd2', name: 'Pixel', kind: 'bitwarden', lastBitwarden: testNow.subtract(const Duration(days: 1)));

/// The vault of the tests: two codes and a note with one file.
Lists _vault() => Lists(
  accounts: [
    const OtpAccount(id: 'a1', issuer: 'Orbit', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1),
    const OtpAccount(id: 'a2', issuer: 'Delta', label: 'me', secret: 'JBSWY3DPEHPK3PXP', addedAt: 1),
  ],
  notes: [
    SecureNote(
      id: 'n1',
      title: 'Passport',
      addedAt: 1,
      attachments: [NoteAttachment(id: 'f1', name: 'scan.txt', size: 13, key: b64(Uint8List(32)), addedAt: 1)],
    ),
  ],
);

/// A vault with [settings] and the move's sheet open. [run] stands for the move.
Future<SyncSheetKit> _open(WidgetTester tester, SyncSettings settings, {KmMoveRun? run, List<KmDevice> devices = const []}) async {
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    (context) => showKemlockMoveSheet(context, _kemlock),
    overrides: [
      kemlockDeviceListProvider.overrideWithValue((target) async => devices),
      kemlockMoveRunProvider.overrideWithValue(run ?? (target, {onProgress, choice}) => throw StateError('the move must not run')),
      kemlockRestoreHomeProvider.overrideWithValue((target) async => 5),
    ],
  );
  await kit.vault.applySynced(_vault());
  await kit.save(settings);
  await kit.open(tester);
  return kit;
}

KmMoveStore _store(SyncSheetKit kit) => KmMoveStore(VaultKmValues(kit.vaultStore, kit.session));

void main() {
  testWidgets('says what moves by kind and what stays for a sealed home, names the Bitwarden devices, and Not now writes nothing', (
    tester,
  ) async {
    final kit = await _open(tester, SyncSettings(vaultwarden: _home(VaultwardenMode.sealed)), devices: [_pixel]);

    expect(find.text(t('kemlock.move.kind.otp', {'n': 'other', 'count': 2})), findsOneWidget);
    expect(find.text(t('kemlock.move.kind.note', {'n': 'one', 'count': 1})), findsOneWidget);
    expect(find.text(t('kemlock.move.files', {'n': 'one', 'count': 1})), findsOneWidget);
    expect(find.text(t('kemlock.move.fate.sealed')), findsOneWidget);
    expect(find.textContaining('Pixel'), findsOneWidget);
    expect(find.textContaining(t('kemlock.move.devices.stop')), findsOneWidget);

    await tapOn(tester, buttonWithText(t('kemlock.move.later')));

    expect(find.text(t('kemlock.move.title')), findsNothing);
    expect(await _store(kit).load(), isNull, reason: 'no record was written');
    expect(kit.settings!.kemlock, isNull);
    expect(kit.settings!.vaultwarden, isNotNull);
  });

  testWidgets('says a plain home stays for Bitwarden apps and Amethystora, without the closing warning', (tester) async {
    await _open(tester, SyncSettings(vaultwarden: _home(VaultwardenMode.plain)), devices: [_pixel]);

    expect(find.text(t('kemlock.move.fate.plain')), findsOneWidget);
    expect(find.text(t('kemlock.move.fate.sealed')), findsNothing);
    expect(find.textContaining(t('kemlock.move.devices.stop')), findsNothing);
  });

  testWidgets('says a WebDAV file stays exactly as it is', (tester) async {
    final personal = SyncTarget(
      dav: const DavAccount(url: folder, username: 'me', password: 'app-pw'),
      file: syncFile,
      key: 'a2V5',
    );
    await _open(tester, SyncSettings(personal: personal));

    expect(find.text(t('kemlock.move.fate.webdav')), findsOneWidget);
  });

  testWidgets('shows the step with its counts, goes on when the sheet closes, and ends with the result and Go back', (tester) async {
    final gate = Completer<void>();
    late SyncSheetKit kit;
    Future<KmMoveOutcome> run(KemlockTarget target, {void Function(KmMoveStep, int, int)? onProgress, Object? choice}) async {
      onProgress?.call(KmMoveStep.copy, 1, 3);
      await gate.future;
      final record = (await _store(kit).load())!;
      final done = record.copyWith(
        step: KmMoveStep.done,
        closed: true,
        finishedAt: testNow.millisecondsSinceEpoch,
        result: {
          'moved': {'otp': 2, 'note': 1},
          'files': 1,
          'oldStore': 'closed',
        },
      );
      await _store(kit).save(done);
      return KmMoveOutcome(record: done);
    }

    kit = await _open(tester, SyncSettings(vaultwarden: _home(VaultwardenMode.sealed)), run: run);

    // The run waits on the gate with its progress bar moving, so frames are pumped one at a time rather than settled
    final start = buttonWithText(t('kemlock.move.start'));
    await tester.ensureVisible(start);
    await tester.pump();
    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(t('kemlock.move.progress.title')), findsOneWidget);
    expect(find.text(t('kemlock.move.step.copy')), findsOneWidget);
    expect(find.text(t('kemlock.move.step.count', {'done': 1, 'total': 3})), findsOneWidget);
    expect(kit.settings!.kemlock, isNotNull, reason: 'confirming saved the Kemlock target, after the record');
    expect(kit.container.read(kemlockMoveProvider).pausesSync, isTrue);

    // Closing the sheet leaves the move running, still with a moving progress bar, so again no settling
    final close = buttonWithText(t('export.close'));
    await tester.ensureVisible(close);
    await tester.pump();
    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(t('kemlock.move.progress.title')), findsNothing);
    expect(kit.container.read(kemlockMoveProvider).running, isTrue);

    gate.complete();
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    final state = kit.container.read(kemlockMoveProvider);
    expect(state.running, isFalse);
    expect(state.record!.isDone, isTrue);
    expect(state.pausesSync, isFalse);
  });

  testWidgets(
    'the result lists what moved and what happened to the old store, and Go back restores the home and drops the Kemlock target',
    (tester) async {
      late SyncSheetKit kit;
      Future<KmMoveOutcome> run(KemlockTarget target, {void Function(KmMoveStep, int, int)? onProgress, Object? choice}) async {
        final record = (await _store(kit).load())!;
        final done = record.copyWith(
          step: KmMoveStep.done,
          closed: true,
          finishedAt: testNow.millisecondsSinceEpoch,
          result: {
            'moved': {'otp': 2, 'note': 1},
            'files': 1,
            'oldStore': 'closed',
          },
        );
        await _store(kit).save(done);
        return KmMoveOutcome(record: done);
      }

      kit = await _open(tester, SyncSettings(vaultwarden: _home(VaultwardenMode.sealed)), run: run);

      await tapOn(tester, buttonWithText(t('kemlock.move.start')));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(find.text(t('kemlock.move.result.title')), findsOneWidget);
      final moved = [
        t('kemlock.move.kind.otp', {'n': 'other', 'count': 2}),
        t('kemlock.move.kind.note', {'n': 'one', 'count': 1}),
        t('kemlock.move.files', {'n': 'one', 'count': 1}),
      ].join(', ');
      expect(find.text(t('kemlock.move.result.moved', {'list': moved})), findsOneWidget);
      expect(find.text(t('kemlock.move.result.closed')), findsOneWidget);
      // The sealed home's target is kept in the record, for going back, after the settings drop it
      expect((await _store(kit).load())!.extra[kmGoBackTargetKey], isA<Map<String, Object?>>());

      await tapOn(tester, buttonWithText(t('kemlock.move.back')));

      expect(kit.settings!.kemlock, isNull);
      expect(kit.settings!.vaultwarden, isNotNull);
      expect(kit.container.read(kemlockMoveProvider).record!.result!['oldStore'], 'wentBack');
      expect(kit.container.read(kemlockMoveProvider).record!.closed, isFalse);
    },
  );

  testWidgets('a move that stopped says why, and Try again resumes it', (tester) async {
    var attempts = 0;
    late SyncSheetKit kit;
    Future<KmMoveOutcome> run(KemlockTarget target, {void Function(KmMoveStep, int, int)? onProgress, Object? choice}) async {
      attempts++;
      if (attempts == 1) {
        throw const KmMoveError(KmMoveIssue.fileMissing, detail: 'Passport');
      }
      final record = (await _store(kit).load())!;
      final done = record.copyWith(
        step: KmMoveStep.done,
        finishedAt: testNow.millisecondsSinceEpoch,
        result: {
          'moved': {'otp': 2},
          'oldStore': 'copyKept',
        },
      );
      await _store(kit).save(done);
      return KmMoveOutcome(record: done);
    }

    kit = await _open(tester, SyncSettings(vaultwarden: _home(VaultwardenMode.plain)), run: run);

    await tapOn(tester, buttonWithText(t('kemlock.move.start')));
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(find.text(t('kemlock.move.problem.fileMissing', {'note': ' (Passport)'})), findsOneWidget);
    expect(kit.container.read(kemlockMoveProvider).unfinished, isTrue, reason: 'the vault’s own sync stays held');

    await tapOn(tester, buttonWithText(t('kemlock.move.retry')));
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text(t('kemlock.move.result.copyKept')), findsOneWidget);
    expect(kit.container.read(kemlockMoveProvider).unfinished, isFalse);
  });
}
