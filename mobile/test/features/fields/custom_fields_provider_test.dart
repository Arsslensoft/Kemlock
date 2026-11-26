import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/features/fields/custom_fields_provider.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/sync.dart';
import 'package:kemlock/features/sync/sync_store.dart';
import 'package:kemlock/models/custom_field.dart';

import '../sync/kemlock/fake_kemlock_accounts.dart';
import '../sync/kemlock/fake_kemlock_server.dart';
import '../sync/kemlock/km_phone_kit.dart';
import '../sync/sync_screen_kit.dart';

const _account = '00000000-0000-4000-8000-000000000001';

const _target = KemlockTarget(
  accountId: _account,
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: FakeKemlockServer.deviceId,
);

late KmTestAccount _test;

/// What `GET /custom-fields` answers: one field for every kind, and people may add their own.
http.Response _answer({bool allowOwn = true}) => http.Response(
  jsonEncode({
    'fields': [
      {'id': 'd1', 'name': 'Employee ID', 'type': 'text', 'kinds': 'all'},
    ],
    'allowOwn': allowOwn,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

/// A container whose vault syncs to [target] (none for a vault with no Kemlock Server account), over a server that answers
/// `GET /custom-fields` through its `respond` hook.
Future<({ProviderContainer container, FakeKemlockServer server})> _open({KemlockTarget? target = _target, bool running = false}) async {
  final server = FakeKemlockServer(userId: _account);
  final host = await signedInHost(server, _test);
  server.respond = (request) async => request.url.path == '/kem/v1/custom-fields' ? _answer() : server.handle(request);
  final container = ProviderContainer(
    overrides: [
      fakeSync(
        SyncSnapshot(
          settings: SyncSettings(kemlock: target),
          running: running,
        ),
      ),
      kemlockHostProvider.overrideWith(() => KmHostHolder(host)),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, server: server);
}

void main() {
  setUpAll(() async {
    _test = await KmTestAccount.create(_account);
  });

  test('online, it is what the server answers', () async {
    final opened = await _open();

    final answer = await opened.container.read(kmCustomFieldsProvider.future);

    expect(answer, isNotNull);
    expect(answer!.fields.map((field) => (field.id, field.name, field.kind)), [('d1', 'Employee ID', CustomFieldKind.text)]);
    expect(answer.allowOwn, isTrue);
    expect(opened.server.requests.where((request) => request.url.path == '/kem/v1/custom-fields'), hasLength(1));
  });

  test('offline after an answer, it is the last answer', () async {
    final opened = await _open();
    final first = await opened.container.read(kmCustomFieldsProvider.future);
    expect(first!.fields, hasLength(1));

    opened.server.respond = (request) async => throw http.ClientException('offline');
    opened.container.invalidate(kmCustomFieldsProvider);
    final again = await opened.container.read(kmCustomFieldsProvider.future);

    expect(again, isNotNull);
    expect(again!.fields.single.id, 'd1');
  });

  test('offline with no answer ever read, it is null: the editor offers nothing from an admin', () async {
    final opened = await _open();
    opened.server.respond = (request) async => throw http.ClientException('offline');

    expect(await opened.container.read(kmCustomFieldsProvider.future), isNull);
  });

  test('while a sync runs, it asks nothing and keeps the last answer', () async {
    final opened = await _open(running: true);

    expect(await opened.container.read(kmCustomFieldsProvider.future), isNull);
    expect(opened.server.requests.where((request) => request.url.path == '/kem/v1/custom-fields'), isEmpty);
  });

  test('with no Kemlock Server account, it is null and nothing is asked', () async {
    final opened = await _open(target: null);

    expect(await opened.container.read(kmCustomFieldsProvider.future), isNull);
    expect(opened.server.requests, isEmpty);
  });
}
