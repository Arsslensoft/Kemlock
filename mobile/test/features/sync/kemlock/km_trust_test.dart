// "Trust this phone" (add-kemlock-server-sync, task 4.3) over a fake of the hardware and the fake
// server: a copy opens only through the same hardware key, and removing trust deletes the server's
// copy and the key.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/keys.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_trust.dart';
import 'package:kemlock/platform/device_keys.dart';

import '../../../fakes/fake_device_keys.dart';
import 'fake_kemlock_server.dart';

final _accountId = uuidBytes('00000000-0000-4000-8000-000000000001');
final _deviceId = uuidBytes(FakeKemlockServer.deviceId);
const _tag = 'trust.main.acct';

class _Phone {
  _Phone({FakeDeviceKeys? keys, FakeKemlockServer? server})
    : keys = keys ?? FakeDeviceKeys(),
      server = server ?? (FakeKemlockServer()..checkTokens = false) {
    trust = KmTrust(wrapper: DeviceKeysWrapper(this.keys, protection: 'secure-enclave'));
    api = KmApi(this.server.client);
    token = this.server.issueTokens('jkt')['accessToken']! as String;
  }

  final FakeDeviceKeys keys;
  final FakeKemlockServer server;
  late final KmTrust trust;
  late final KmApi api;
  late final String token;
  final root = randomBytes(rootKeyLength);

  Future<void> trustPhone() => trust.trust(
    api: api,
    server: FakeKemlockServer.url,
    token: token,
    tag: _tag,
    rootKey: root,
    accountId: _accountId,
    deviceId: _deviceId,
    keyVersion: 1,
  );

  Future<Uint8List?> open({List<int>? accountId, List<int>? deviceId, int keyVersion = 1, KmApi? other}) => trust.openAfterSso(
    api: other ?? api,
    server: FakeKemlockServer.url,
    token: token,
    tag: _tag,
    accountId: accountId ?? _accountId,
    deviceId: deviceId ?? _deviceId,
    keyVersion: keyVersion,
  );
}

void main() {
  test('trusting uploads the sealed root with the hardware’s wrap of its key, under the hardware’s protection', () async {
    final phone = _Phone();

    await phone.trustPhone();

    final copy = phone.server.keyCopy!;
    expect(copy['protection'], 'secure-enclave');
    final blob = b64urlDecode(copy['wrappedKey']!);
    expect(blob[0], 1, reason: 'the format version');
    expect(blob[1], 0x01, reason: 'the Secure Enclave’s platform byte');
    expect(blob.length, greaterThan(94), reason: 'the sealed root, then the wrap');
    expect(blob, isNot(containsAllInOrder(phone.root.sublist(0, 8))), reason: 'the root is not in it in the clear');
    expect(phone.keys.calls.where((c) => c.startsWith('wrap')), hasLength(1));
  });

  test('after SSO the phone opens the root with the copy and its own hardware key', () async {
    final phone = _Phone();
    await phone.trustPhone();

    expect(await phone.open(), phone.root);
  });

  test('a phone that is not trusted opens nothing, and the sign-in goes on', () async {
    final phone = _Phone();

    expect(await phone.open(), isNull, reason: 'no hardware key, no copy');

    await phone.keys.create(_tag, DeviceKeyUse.wrapping);
    expect(await phone.open(), isNull, reason: 'a hardware key but no copy');
  });

  test('a copy opens only through the same hardware key: another phone’s, or a replaced one, can’t', () async {
    final phone = _Phone();
    await phone.trustPhone();

    final other = _Phone(server: phone.server);
    await other.keys.create(_tag, DeviceKeyUse.wrapping);
    await expectLater(other.open(), throwsA(isA<KmTrustUnreadable>()));

    await phone.keys.create(_tag, DeviceKeyUse.wrapping);
    await expectLater(phone.open(), throwsA(isA<KmTrustUnreadable>()));
  });

  test('a copy is bound to its account, its device and its key version', () async {
    final phone = _Phone();
    await phone.trustPhone();

    await expectLater(phone.open(accountId: uuidBytes('00000000-0000-4000-8000-000000000002')), throwsA(isA<KmTrustUnreadable>()));
    await expectLater(phone.open(deviceId: uuidBytes('00000000-0000-4000-8000-0000000000d2')), throwsA(isA<KmTrustUnreadable>()));
    await expectLater(phone.open(keyVersion: 2), throwsA(isA<KmTrustUnreadable>()));
    expect(await phone.open(), phone.root, reason: 'and still opens for its own');
  });

  test('a changed byte, a short copy or another version’s format does not open', () async {
    final phone = _Phone();
    await phone.trustPhone();
    final good = b64urlDecode(phone.server.keyCopy!['wrappedKey']!);

    Future<void> storeAndOpen(Uint8List blob) async {
      phone.server.keyCopy = {'wrappedKey': b64urlEncode(blob), 'protection': 'secure-enclave'};
      await phone.open();
    }

    for (final bad in [
      Uint8List.fromList(good)..[40] ^= 1,
      Uint8List.fromList(good)..[good.length - 1] ^= 1,
      Uint8List.fromList(good.sublist(0, 50)),
      Uint8List.fromList(good)..[0] = 9,
      Uint8List.fromList(good)..[1] = 0x02,
    ]) {
      await expectLater(storeAndOpen(bad), throwsA(isA<KmTrustUnreadable>()));
    }
  });

  test('removing trust deletes the hardware key and the server’s copy, and the next SSO needs more than the phone', () async {
    final phone = _Phone();
    await phone.trustPhone();

    await phone.trust.removeTrust(api: phone.api, server: FakeKemlockServer.url, token: phone.token, tag: _tag);

    expect(phone.server.keyCopy, isNull);
    expect(phone.keys.wrapping, isEmpty);
    expect(await phone.open(), isNull);
  });

  test('a server that can’t be reached leaves the copy, but the key is already gone, so the copy opens nothing', () async {
    final phone = _Phone();
    await phone.trustPhone();
    phone.server.respond = (_) async => http.Response('', 500);

    await expectLater(
      phone.trust.removeTrust(api: phone.api, server: FakeKemlockServer.url, token: phone.token, tag: _tag),
      throwsA(isA<KmError>()),
    );

    expect(phone.keys.wrapping, isEmpty);
    expect(phone.server.keyCopy, isNotNull);
  });

  test('a phone with no hardware key can’t be trusted, and nothing is uploaded', () async {
    final phone = _Phone(keys: FakeDeviceKeys(hasHardware: false));

    await expectLater(phone.trustPhone(), throwsA(isA<KmTrustUnavailable>()));

    expect(phone.server.keyCopy, isNull);
  });

  test('a copy the server doesn’t take leaves no key behind', () async {
    final phone = _Phone();
    phone.server.respond = (_) async => http.Response('', 500);

    await expectLater(phone.trustPhone(), throwsA(isA<KmError>()));

    expect(phone.keys.wrapping, isEmpty);
  });

  test('the key K_td is never stored: only the hardware’s wrap of it leaves the phone', () async {
    final phone = _Phone();
    await phone.trustPhone();

    // What the hardware wrapped is what the fake saw; it is 32 bytes, wrapped to 60
    final blob = b64urlDecode(phone.server.keyCopy!['wrappedKey']!);
    expect(blob.length, 94 + 12 + 32 + 16);
  });
}
