// The server matching switches of the Kemlock Server sheet (add-duplicate-cleaner, task 7.2), over the fake server
// with the duplicate cleaner's routes: the vault's switch and its explainer, turning it off, a space's switch for an
// admin and a member, and the notice a member sees once.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/account/encoding.dart' show b64urlDecode;
import 'package:kemlock/features/duplicates/duplicates_provider.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock_matching.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_sheet.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/models/login.dart';

import '../../../flows/flow_kit.dart' show tapOn;
import '../../../helpers/test_app.dart';
import '../sync_screen_kit.dart';
import 'fake_dedup_server.dart';
import 'fake_kemlock_accounts.dart';
import 'fake_kemlock_server.dart';
import 'km_phone_kit.dart';

const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: FakeKemlockServer.deviceId,
);

const _adminSpace = KmDedupSpace(id: '4a000000-0000-4000-8000-0000000000a1', name: 'Larkspur admins', admin: true);
const _memberSpace = KmDedupSpace(id: '4a000000-0000-4000-8000-0000000000b2', name: 'Larkspur members', admin: false);

late KmTestAccount _test;

typedef _Opened = ({SyncSheetKit kit, FakeDedupServer server});

/// The Kemlock Server sheet of a vault, signed in to a fake server, with the given spaces the account is in.
Future<_Opened> _open(
  WidgetTester tester, {
  bool matching = false,
  List<KmDedupSpace> spaces = const [],
  void Function(FakeDedupServer server)? prepare,
}) async {
  final server = FakeDedupServer(userId: _test.userId);
  for (final space in spaces) {
    server.spaceRoles[space.owner] = space.admin ? 'admin' : 'member';
  }
  prepare?.call(server);
  final host = await signedInHost(server, _test);
  final kit = SyncSheetKit();
  await kit.pump(
    tester,
    showSyncSheet,
    overrides: [
      kemlockHostProvider.overrideWith(() => KmHostHolder(host)),
      kemlockDedupSpacesProvider.overrideWithValue(spaces),
      suffixListHashProvider.overrideWith((ref) async => 'none'),
    ],
  );
  await kit.save(SyncSettings(kemlock: _target.copyWith(matching: matching)));
  await kit.open(tester);
  // Nothing covers a button below: any toast has gone
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
  return (kit: kit, server: server);
}

Finder _switch(String title) => find.widgetWithText(SwitchListTile, title);

bool _on(WidgetTester tester, Finder finder) => tester.widget<SwitchListTile>(finder).value;

/// Whether [request]'s DPoP proof names the server's nonce. The server refuses a phone's first proof with a 401 for its
/// nonce and the phone sends the same request again with it (`km_dpop_test.dart`), so one without a nonce was refused,
/// and is the request the server then answered.
bool _answered(http.Request request) {
  final proof = request.headers['DPoP'] ?? request.headers['dpop'];
  final parts = proof?.split('.');
  if (parts == null || parts.length != 3) {
    return false;
  }
  final claims = jsonDecode(utf8.decode(b64urlDecode(parts[1])));
  return claims is Map<String, Object?> && claims['nonce'] != null;
}

/// The requests the server answered that touched the duplicate cleaner's routes.
List<String> _cleaner(FakeDedupServer server) => [
  for (final request in server.requests)
    if (_answered(request) && (request.url.path.contains('/duplicates') || request.url.path.endsWith('/tags')))
      '${request.method} ${request.url.path}',
];

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create('00000000-0000-4000-8000-000000000001');
  });

  group('the vault’s switch', () {
    testWidgets('is off until turned on, and opening the sheet sends nothing about it', (tester) async {
      final opened = await _open(tester);

      expect(_on(tester, _switch(t('kemlock.matching.switch'))), isFalse);
      expect(find.text(t('kemlock.matching.hint')), findsOneWidget);
      expect(_cleaner(opened.server), isEmpty);
      expect(opened.kit.settings?.kemlock?.matching, isFalse);
    });

    testWidgets('opens an explainer of what the server learns first, and cancelling it sends nothing', (tester) async {
      final opened = await _open(tester);

      await tapOn(tester, find.text(t('kemlock.matching.switch')));

      expect(find.text(t('kemlock.matching.explainer.title')), findsOneWidget);
      expect(find.text(t('kemlock.matching.explainer.sends')), findsOneWidget);
      expect(find.text(t('kemlock.matching.explainer.learns')), findsOneWidget);
      expect(find.text(t('kemlock.matching.explainer.never')), findsOneWidget);
      await tapOn(tester, find.text(t('kemlock.matching.explainer.cancel')));

      expect(_cleaner(opened.server), isEmpty);
      expect(opened.server.of(opened.server.owner).enabled, isFalse);
      expect(opened.kit.settings?.kemlock?.matching, isFalse);
      expect(_on(tester, _switch(t('kemlock.matching.switch'))), isFalse);
    });

    testWidgets('confirming turns matching on at the server and in the settings', (tester) async {
      final opened = await _open(tester);

      await tapOn(tester, find.text(t('kemlock.matching.switch')));
      await tapOn(tester, find.text(t('kemlock.matching.explainer.confirm')));

      expect(opened.server.of(opened.server.owner).enabled, isTrue);
      expect(opened.kit.settings?.kemlock?.matching, isTrue);
      expect(opened.kit.settings?.kemlock?.toJson()['matching'], isTrue);
      expect(_on(tester, _switch(t('kemlock.matching.switch'))), isTrue);
      expect(_cleaner(opened.server), ['PUT /kem/v1/duplicates/settings']);
    });

    testWidgets('a server that can’t be reached leaves it off, and says so', (tester) async {
      final opened = await _open(tester);
      opened.server.respond = (request) async => throw StateError('no route to host');

      await tapOn(tester, find.text(t('kemlock.matching.switch')));
      await tapOn(tester, find.text(t('kemlock.matching.explainer.confirm')));

      expect(find.text(t('kemlock.matching.failed')), findsOneWidget);
      expect(opened.kit.settings?.kemlock?.matching, isFalse);
      expect(_on(tester, _switch(t('kemlock.matching.switch'))), isFalse);
    });

    testWidgets('turning it off deletes the uploaded tags, and the cleaner still finds duplicates on the phone', (tester) async {
      final opened = await _open(
        tester,
        matching: true,
        prepare: (server) {
          server.turnOn();
          server.tags['3f2c9a71-e4b0-4856-8a00-0000000000a1'] = (revision: 1, version: 1, tags: ['dGFn']);
        },
      );
      for (final id in ['l1', 'l2']) {
        await opened.kit.vault.addLogin(
          Login(id: id, name: 'Larkspur $id', username: 'sam', password: 'hunter2', websites: const ['larkspur.example'], addedAt: 0),
        );
      }
      expect(_on(tester, _switch(t('kemlock.matching.switch'))), isTrue);

      await tapOn(tester, find.text(t('kemlock.matching.switch')));

      expect(find.text(t('kemlock.matching.explainer.title')), findsNothing, reason: 'turning off asks nothing');
      expect(opened.server.tagDeletes, 1);
      expect(opened.server.tags, isEmpty);
      expect(opened.server.of(opened.server.owner).enabled, isFalse);
      expect(opened.kit.settings?.kemlock?.matching, isFalse);
      expect(opened.kit.settings?.kemlock?.toJson(), isNot(contains('matching')), reason: 'off is the default, and not written');
      expect(_cleaner(opened.server), ['DELETE /kem/v1/duplicates/tags']);

      await opened.kit.container.read(duplicatesProvider.notifier).check();
      final found = opened.kit.container.read(duplicatesProvider);
      expect(found.checked, isTrue);
      expect(found.groups, hasLength(1), reason: 'two logins with one site, username and password, found without the server');
    });
  });

  group('a space’s switch', () {
    testWidgets('an admin can turn it on after the explainer, which says everyone is told', (tester) async {
      final opened = await _open(tester, spaces: [_adminSpace, _memberSpace]);
      final key = find.byKey(ValueKey('matching-${_adminSpace.id}'));
      expect(tester.widget<SwitchListTile>(key).onChanged, isNotNull);

      await tapOn(tester, find.text(_adminSpace.name));

      expect(find.text(t('kemlock.matching.explainer.space', {'space': _adminSpace.name})), findsOneWidget);
      await tapOn(tester, find.text(t('kemlock.matching.explainer.confirm')));

      expect(opened.server.of(_adminSpace.owner).enabled, isTrue);
      expect(opened.server.of(_adminSpace.owner).changedBy, _test.userId);
      expect(_on(tester, key), isTrue);
      expect(opened.server.of(opened.server.owner).enabled, isFalse, reason: 'the vault’s own switch is another one');
    });

    testWidgets('a member sees where it stands and can’t change it', (tester) async {
      final opened = await _open(
        tester,
        spaces: [_adminSpace, _memberSpace],
        prepare: (server) => server.of(_memberSpace.owner)
          ..enabled = true
          ..changedBy = '00000000-0000-4000-8000-0000000000ee'
          ..changedAt = 1795000000,
      );
      final key = find.byKey(ValueKey('matching-${_memberSpace.id}'));

      expect(_on(tester, key), isTrue);
      expect(tester.widget<SwitchListTile>(key).onChanged, isNull);
      expect(find.text(t('kemlock.matching.space.hint', {'admin': 'no'})), findsOneWidget);
      await tapOn(tester, find.text(_memberSpace.name));

      expect(find.text(t('kemlock.matching.explainer.title')), findsNothing);
      expect(opened.server.requests.where((request) => request.method == 'PUT'), isEmpty);
      expect(opened.server.of(_memberSpace.owner).enabled, isTrue);
    });

    testWidgets('the server refuses a member who tries anyway, so the screen is not all there is to it', (tester) async {
      final opened = await _open(tester, spaces: [_memberSpace]);
      final matching = opened.kit.container.read(kemlockMatchingProvider);

      Object? thrown;
      unawaited(matching.turnOn(_target, _memberSpace.owner).then<void>((_) {}, onError: (Object e) => thrown = e));
      await tester.pumpAndSettle();

      expect(thrown, isNotNull);
      expect(opened.server.of(_memberSpace.owner).enabled, isFalse);
    });

    testWidgets('every member is told at their next sync, once', (tester) async {
      final opened = await _open(
        tester,
        spaces: [_adminSpace, _memberSpace],
        prepare: (server) => server.of(_memberSpace.owner)
          ..enabled = true
          ..changedBy = '00000000-0000-4000-8000-0000000000ee'
          ..changedAt = 1795000000,
      );
      expect(find.text(t('kemlock.matching.notice', {'space': _memberSpace.name})), findsNothing, reason: 'nothing before a sync');

      // The sync run's end reads the settings of each space
      unawaited(opened.kit.container.read(kemlockMatchingNoticesProvider.notifier).refresh());
      await tester.pumpAndSettle();

      expect(find.text(t('kemlock.matching.notice', {'space': _memberSpace.name})), findsOneWidget);
      expect(
        find.textContaining(_adminSpace.name),
        findsOneWidget,
        reason: 'only the member space has a notice; the admin’s name is its switch',
      );

      await tapOn(tester, find.text(t('kemlock.matching.notice.dismiss')));

      expect(find.text(t('kemlock.matching.notice', {'space': _memberSpace.name})), findsNothing);
      expect(opened.kit.settings?.kemlock?.matchingSeen, {_memberSpace.owner: 1795000000});
      unawaited(opened.kit.container.read(kemlockMatchingNoticesProvider.notifier).refresh());
      await tester.pumpAndSettle();
      expect(find.text(t('kemlock.matching.notice', {'space': _memberSpace.name})), findsNothing, reason: 'told once');
    });

    testWidgets('an admin is not told of their own change', (tester) async {
      final opened = await _open(
        tester,
        spaces: [_adminSpace],
        prepare: (server) => server.of(_adminSpace.owner)
          ..enabled = true
          ..changedBy = _test.userId
          ..changedAt = 1795000000,
      );

      unawaited(opened.kit.container.read(kemlockMatchingNoticesProvider.notifier).refresh());
      await tester.pumpAndSettle();

      expect(find.text(t('kemlock.matching.notice', {'space': _adminSpace.name})), findsNothing);
    });
  });

  test('the target keeps the switch and what was told only when they are set', () {
    expect(_target.toJson(), isNot(contains('matching')));
    expect(_target.toJson(), isNot(contains('matchingSeen')));
    final on = _target.copyWith(matching: true, matchingSeen: {'space:x': 5});
    final back = KemlockTarget.fromJson(on.toJson());
    expect(back.matching, isTrue);
    expect(back.matchingSeen, {'space:x': 5});
  });
}
