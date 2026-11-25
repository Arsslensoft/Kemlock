// How the phone's push token reaches the server (add-kemlock-server-sync, design 13; plan add-unifiedpush): the kind the
// phone's push service gives goes through as it is, `apns` on iOS and `unifiedpush` on Android, and nothing is asked of the
// push service while offline mode is on.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/sync/kemlock_push.dart';
import 'package:kemlock/platform/push.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../../../fakes/fake_approval_notice.dart';
import '../../../fakes/fake_push_tokens.dart';

const _endpoint = 'https://ntfy.example.com/upAbc123';

({ProviderContainer container, FakeApprovalNotice notice}) _container(FakePushTokens push, {bool offline = false}) {
  final kv = KeyValueStore.memory();
  if (offline) kv.setItem(keyOffline, jsonEncode({'on': true}));
  final notice = FakeApprovalNotice();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv), pushTokensProvider.overrideWithValue(push), notice.asOverride],
  );
  addTearDown(container.dispose);
  addTearDown(push.close);
  return (container: container, notice: notice);
}

void main() {
  group('the token the server is given', () {
    test('an iPhone gives its APNs token, as `apns`, and is asked once to show the sign-in notification', () async {
      final s = _container(FakePushTokens.apns('apns-hex-1'));
      final read = s.container.read(kemlockPushTokenProvider);

      expect(await read(), (kind: 'apns', token: 'apns-hex-1'));
      expect(await read(), (kind: 'apns', token: 'apns-hex-1'));

      expect(s.notice.permissionRequests, 1);
    });

    test('an Android phone gives its UnifiedPush endpoint, as `unifiedpush`, and is asked for no notification', () async {
      final s = _container(FakePushTokens.unifiedPush(token: (kind: pushKindUnifiedPush, token: _endpoint)));

      expect(await s.container.read(kemlockPushTokenProvider)(), (kind: 'unifiedpush', token: _endpoint));

      expect(s.notice.permissionRequests, 0, reason: 'a UnifiedPush message is a nudge to sync, which no one is shown');
    });

    test('a phone with no token gives none', () async {
      expect(await _container(FakePushTokens.none()).container.read(kemlockPushTokenProvider)(), isNull);
      expect(await _container(FakePushTokens.unifiedPush()).container.read(kemlockPushTokenProvider)(), isNull);
    });

    test('is none while offline mode is on, and the push service is not asked', () async {
      final push = FakePushTokens.unifiedPush(token: (kind: pushKindUnifiedPush, token: _endpoint));
      final s = _container(push, offline: true);

      expect(await s.container.read(kemlockPushTokenProvider)(), isNull);

      expect(push.calls, isEmpty);
    });
  });
}
