// The New Send sheet, the link sheet and the Sends page, over a service that answers as it is told: what the sheets
// refuse before anything is made, what they say of a server's refusal, what the page shows for each status and for
// each reason it lists nothing, and that Copy goes through the secret clipboard.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/send.dart';
import 'package:kemlock/features/sends/new_send_sheet.dart';
import 'package:kemlock/features/sends/send_edit_sheet.dart';
import 'package:kemlock/features/sends/sends_page.dart';
import 'package:kemlock/features/sends/sends_providers.dart';
import 'package:kemlock/features/sends/sends_service.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_failover.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock/km_sends_api.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/platform/files.dart';
import 'package:kemlock/platform/network.dart';
import 'package:kemlock/ui/ui.dart';

import '../../flows/flow_kit.dart' show tapOn;
import '../../helpers/test_app.dart';
import '../share/share_kit.dart';
import '../sync/kemlock/km_sync_kit.dart' show kmTarget;

class _NoValues implements KmVaultValues {
  @override
  Future<Object?> load(String key) async => null;

  @override
  Future<void> save(String key, Object? value) async {}

  @override
  void remove(String key) {}
}

const _id = '3f2c9a71-e4b0-4a56-8a00-0000000000';

KmSend _send(
  int n, {
  String kind = sendKindText,
  bool disabled = false,
  int? maxAccess,
  int accessCount = 0,
  DateTime? expiresAt,
  bool ready = true,
}) {
  final id = '$_id${n.toString().padLeft(2, '0')}';
  return KmSend(
    id: id,
    accessId: sendAccessId(uuidBytes(id)),
    kind: kind,
    meta: Uint8List(40),
    sealedKey: Uint8List(sendSealedKeyLength),
    payload: Uint8List(40),
    hasPassword: false,
    accessCount: accessCount,
    hideEmail: false,
    disabled: disabled,
    deletionAt: DateTime.now().add(const Duration(days: 3)),
    createdAt: DateTime.now(),
    revisedAt: DateTime.now(),
    maxAccess: maxAccess,
    expiresAt: expiresAt,
    file: kind == sendKindFile ? KmSendFile(size: 30, ready: ready) : null,
  );
}

const _foreignId = '3f2c9a71-e4b0-4856-8a00-0000000000';

/// A Send a Bitwarden app made, as the list holds it: the server's plain fields only.
ForeignSend _foreign(int n, {String kind = sendKindText, bool disabled = false, int? maxAccess, int accessCount = 0}) {
  final id = '$_foreignId${n.toString().padLeft(2, '0')}';
  final send = KmForeignSend(
    id: id,
    accessId: sendAccessId(uuidBytes(id)),
    kind: kind,
    hasPassword: false,
    accessCount: accessCount,
    hideEmail: false,
    disabled: disabled,
    deletionAt: DateTime.now().add(const Duration(days: 3)),
    createdAt: DateTime.now(),
    revisedAt: DateTime.now(),
    maxAccess: maxAccess,
    file: kind == sendKindFile ? const KmSendFile(size: 30, ready: true) : null,
  );
  return ForeignSend(send: send, status: sendStatus(send, DateTime.now()));
}

OwnedSend _owned(KmSend send, String? name, {SendStatus? status}) => OwnedSend(
  send: send,
  status: status ?? sendStatus(send, DateTime.now()),
  meta: name == null ? null : SendMeta(name: name, notes: ''),
);

/// A service that makes and lists what it is told to, and records what it was asked to make.
class _FakeService extends SendsService {
  _FakeService()
    : super(
        host: KmHost(values: _NoValues(), clientFor: (pin) => throw StateError('no client'), proofsFor: (session) async => null),
        target: kmTarget,
      );

  final made = <NewSend>[];
  Object? makeError;
  Object? listError;
  var listed = <OwnedSend>[];
  var listedForeign = <ForeignSend>[];
  final deletedForeign = <String>[];

  @override
  Future<MadeSend> make(NewSend input) async {
    made.add(input);
    final error = makeError;
    if (error != null) throw error;
    return MadeSend(send: _send(90), link: 'https://kem.example.com/#/send/AAAAAAAAAAAAAAAAAAAAAA/${'B' * 43}');
  }

  @override
  Future<SendsListing> listing() async {
    final error = listError;
    if (error != null) throw error;
    return SendsListing(owned: listed, foreign: listedForeign);
  }

  @override
  Future<void> deleteForeign(ForeignSend foreign) async {
    deletedForeign.add(foreign.send.id);
    listedForeign = [
      for (final other in listedForeign)
        if (other.send.id != foreign.send.id) other,
    ];
  }
}

class _SheetsApp extends ShareApp {
  _SheetsApp(super.tester, this.service);

  final _FakeService? service;

  @override
  List<Override> get overrides => [...super.overrides, sendsServiceProvider.overrideWithValue(service)];

  Future<void> pumpFor(Duration time) async {
    await tester.pump();
    await tester.pump(time);
  }

  Future<void> openNewSend() async {
    unawaited(showNewSendSheet(shell));
    await pumpFor(const Duration(milliseconds: 600));
    expect(find.byType(NewSendSheet), findsOneWidget);
  }

  Future<void> openPage() async {
    GoRouter.of(shell).go('/vault/sends');
    await pumpFor(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byType(SendsPage), findsOneWidget);
  }
}

Finder _field(String id) => find.widgetWithText(TextField, t(id));

/// The button with [label], whether it was made with an icon or not.
VoidCallback? _onPressed(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>())).onPressed;

void main() {
  group('the New Send sheet', () {
    Future<void> fill(_SheetsApp app) async {
      await app.tester.enterText(_field('sends.field.name'), 'Wi-Fi');
      await app.tester.enterText(_field('sends.field.text'), 'on the fridge');
      await app.tester.pump();
    }

    testWidgets("shows the server's own words when it refuses", (tester) async {
      final service = _FakeService()..makeError = const SendsError(SendsProblem.policy, detail: 'Always show the sender’s email.');
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openNewSend();
      await fill(app);

      await tester.tap(find.text(t('sends.make')));
      await app.pumpFor(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text(t('sends.error.policy', {'reason': 'Always show the sender’s email.'})), findsOneWidget);
      expect(service.made.single.text, 'on the fridge');
    });

    testWidgets('refuses a file of 50 MB and a byte before anything is made', (tester) async {
      final service = _FakeService();
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openNewSend();
      app.files.nextPick = PickedFile(name: 'big.bin', bytes: Uint8List(sendFileLimit + 1));

      await tapOn(tester, find.text(t('sends.new.file')));
      await tapOn(tester, find.text(t('sends.file.choose')));

      expect(
        find.text(
          t('sends.file.tooBig', {
            'limit': t('notes.file.mb', {'size': 50.0}),
          }),
        ),
        findsOneWidget,
      );
      expect(service.made, isEmpty);
      expect(find.text(t('sends.make')), findsOneWidget);
      expect(_onPressed(tester, t('sends.make')), isNull);
    });

    testWidgets("doesn't offer an expiry after the deletion", (tester) async {
      final app = _SheetsApp(tester, _FakeService());
      await app.start();
      await app.openNewSend();
      final oneDay = find.text(t('sends.days', {'days': 1}));

      // Deleted after 7 days: the link may stop after 1, 2 or 3 days, so each shows in two rows
      expect(oneDay, findsNWidgets(2));
      expect(find.text(t('sends.days', {'days': 14})), findsOneWidget);
      await tapOn(tester, oneDay.first);

      // Deleted after 1 day: nothing earlier is left to offer
      expect(oneDay, findsOneWidget);
      expect(find.text(t('sends.expires.never')), findsOneWidget);
    });

    testWidgets('shows the link once it is made, copies it through the secret clipboard, and empties the field on close', (tester) async {
      final app = _SheetsApp(tester, _FakeService());
      await app.start();
      await app.openNewSend();
      await fill(app);

      await tester.tap(find.text(t('sends.make')));
      await app.pumpFor(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final link = 'https://kem.example.com/#/send/AAAAAAAAAAAAAAAAAAAAAA/${'B' * 43}';
      final linkField = find.byWidgetPredicate((widget) => widget is TextField && widget.controller?.text == link);
      expect(linkField, findsOneWidget);
      expect(find.text(t('sends.link.body')), findsOneWidget);
      final controller = tester.widget<TextField>(linkField).controller!;

      await tapOn(tester, find.text(t('sends.detail.copy')));
      expect(app.copies, [link]);
      // The toast that says so would lie over the button under it
      await tester.pump(const Duration(seconds: 10));
      await tapOn(tester, find.text(t('sends.link.done')));

      expect(find.byType(NewSendSheet), findsNothing);
      expect(controller.text, isEmpty);
    });

    testWidgets('says so when offline mode is on, and offers nothing to make', (tester) async {
      final app = _SheetsApp(tester, _FakeService());
      await app.start();
      app.app.container.read(offlineProvider.notifier).set(true);
      await app.openNewSend();
      await fill(app);

      expect(find.text(t('sends.offline')), findsOneWidget);
      expect(_onPressed(tester, t('sends.make')), isNull);
    });

    testWidgets('says so when there is no Kemlock Server sync', (tester) async {
      final app = _SheetsApp(tester, null);
      await app.start();
      await app.openNewSend();
      await fill(app);

      expect(find.text(t('sends.noSync')), findsOneWidget);
      expect(_onPressed(tester, t('sends.make')), isNull);
    });
  });

  group('the Sends page', () {
    testWidgets('shows each status, and a Send that cannot be read here', (tester) async {
      final service = _FakeService()
        ..listed = [
          _owned(_send(1), 'Active one'),
          _owned(_send(2, disabled: true), 'Off one'),
          _owned(_send(3, expiresAt: DateTime.now().subtract(const Duration(days: 1))), 'Old one'),
          _owned(_send(4, maxAccess: 1, accessCount: 1), 'Used one'),
          _owned(_send(5, kind: sendKindFile, ready: false), 'Waiting one'),
          _owned(_send(6), null),
        ];
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openPage();

      for (final (name, status) in [
        ('Active one', 'sends.status.active'),
        ('Off one', 'sends.status.off'),
        ('Old one', 'sends.status.expired'),
        ('Used one', 'sends.status.usedUp'),
        ('Waiting one', 'sends.status.waiting'),
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
        expect(find.text(t(status).toUpperCase()), findsAtLeastNWidgets(1), reason: status);
      }
      expect(find.text(t('sends.status.unreadable')), findsOneWidget);
    });

    testWidgets('shows the Sends a Bitwarden app made in a section of their own, with the line about where to open them', (tester) async {
      final service = _FakeService()
        ..listed = [_owned(_send(1), 'Active one')]
        ..listedForeign = [_foreign(1), _foreign(2, kind: sendKindFile, disabled: true)];
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openPage();

      expect(find.text(t('sends.foreign.title').toUpperCase()), findsOneWidget);
      expect(find.text(t('sends.foreign.note')), findsOneWidget);
      expect(find.text(t('sends.foreign.name', {'kind': 'text'})), findsOneWidget);
      expect(find.text(t('sends.foreign.name', {'kind': 'file'})), findsOneWidget);
      expect(find.text('Active one'), findsOneWidget);
      expect(find.text(t('sends.status.off').toUpperCase()), findsOneWidget);
    });

    testWidgets('shows no empty state when only Bitwarden Sends are listed', (tester) async {
      final app = _SheetsApp(tester, _FakeService()..listedForeign = [_foreign(1)]);
      await app.start();
      await app.openPage();
      expect(find.text(t('sends.foreign.title').toUpperCase()), findsOneWidget);
      expect(find.text(t('sends.empty.title')), findsNothing);
    });

    testWidgets('shows the empty state and no Bitwarden section when nothing is listed', (tester) async {
      final app = _SheetsApp(tester, _FakeService());
      await app.start();
      await app.openPage();
      expect(find.text(t('sends.foreign.title').toUpperCase()), findsNothing);
      expect(find.text(t('sends.empty.title')), findsOneWidget);
    });

    testWidgets('a tap on a Bitwarden Send says to use that app, and opens no sheet to edit, copy or share it', (tester) async {
      final service = _FakeService()..listedForeign = [_foreign(1)];
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openPage();

      await tester.tap(find.text(t('sends.foreign.name', {'kind': 'text'})));
      await app.pumpFor(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.byType(ForeignSendSheet), findsOneWidget);
      expect(find.byType(SendEditSheet), findsNothing);
      expect(find.byType(SendDetailSheet), findsNothing);
      // The line is on the page behind the sheet and in the sheet
      expect(find.text(t('sends.foreign.note')), findsNWidgets(2));
      expect(find.text(t('sends.detail.edit')), findsNothing);
      expect(find.text(t('sends.detail.copy')), findsNothing);
      expect(find.text(t('sends.detail.share')), findsNothing);
      expect(find.text(t('sends.detail.view')), findsNothing);
      expect(find.text(t('sends.detail.delete')), findsOneWidget);
      expect(service.deletedForeign, isEmpty);
    });

    testWidgets('deletes a Bitwarden Send after the confirm dialog, and not when it is cancelled', (tester) async {
      final service = _FakeService()..listedForeign = [_foreign(1), _foreign(2)];
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openPage();

      await tester.tap(find.text(t('sends.foreign.name', {'kind': 'text'})).first);
      await app.pumpFor(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('sends.detail.delete')));
      await app.pumpFor(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmDialog), findsOneWidget);
      expect(find.text(t('sends.foreign.delete.body')), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(t('changePw.cancel'))));
      await app.pumpFor(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(service.deletedForeign, isEmpty);
      expect(find.byType(ForeignSendSheet), findsOneWidget);

      await tester.tap(find.text(t('sends.detail.delete')));
      await app.pumpFor(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(t('sends.delete.confirm'))));
      await app.pumpFor(const Duration(milliseconds: 600));
      await app.pumpFor(const Duration(milliseconds: 600));

      expect(service.deletedForeign, ['${_foreignId}01']);
      expect(find.byType(ForeignSendSheet), findsNothing);
      expect(find.byKey(const ValueKey('foreign:${_foreignId}01')), findsNothing);
      expect(find.byKey(const ValueKey('foreign:${_foreignId}02')), findsOneWidget);
    });

    testWidgets('fits each row and its sheet on a phone 360 wide, long status and all', (tester) async {
      final service = _FakeService()..listed = [_owned(_send(5, kind: sendKindFile, ready: false), 'Waiting one'), _owned(_send(6), null)];
      final app = _SheetsApp(tester, service);
      await app.start();
      tester.view.physicalSize = const Size(360, 3800);
      tester.view.devicePixelRatio = 1;
      await app.openPage();

      // An overflow is reported as an error, which fails the test; the texts are all still there
      expect(find.text(t('sends.status.waiting').toUpperCase()), findsOneWidget);
      expect(find.text(t('sends.status.unreadable').toUpperCase()), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(t('sends.status.unreadable')));
      await tester.pumpAndSettle();
      expect(find.byType(SendDetailSheet), findsOneWidget);
      expect(find.text(t('sends.status.unreadable').toUpperCase()), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('says why it lists nothing: no sync, offline mode, an ended session, a home that is away', (tester) async {
      final none = _SheetsApp(tester, null);
      await none.start();
      await none.openPage();
      expect(find.text(t('sends.noSync')), findsOneWidget);
      // "Open a Send" works whatever the account
      expect(_onPressed(tester, t('sends.open')), isNotNull);
      expect(_onPressed(tester, t('sends.new')), isNull);

      none.app.container.read(offlineProvider.notifier).set(true);
      await tester.pumpAndSettle();
      expect(find.text(t('sends.offline')), findsOneWidget);
    });

    testWidgets('an ended session and a home that is away are said', (tester) async {
      final service = _FakeService()..listError = const KmError(KmProblem.sessionEnded, reason: 'signed-out');
      final app = _SheetsApp(tester, service);
      await app.start();
      await app.openPage();
      expect(find.text(t('sends.sessionEnded')), findsOneWidget);

      service.listError = null;
      app.app.container
          .read(kemlockAwayProvider.notifier)
          .set(
            KmAway(
              using: const KemlockServer(url: 'https://replica.example.com', role: KemlockServer.replica),
              since: DateTime(2030, 6, 1, 9, 12),
            ),
          );
      await tester.pumpAndSettle();
      expect(find.textContaining('Your home server is offline since'), findsOneWidget);
      expect(_onPressed(tester, t('sends.new')), isNull);
    });
  });
}
