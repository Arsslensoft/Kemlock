// The security key step of a Vaultwarden sign-in, against the fake phone
// and the fake FIDO key.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_key_step.dart';
import 'package:kemlock/features/sync/vaultwarden/vw_webauthn.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';

import '../../../fakes/fake_fido_key.dart';
import '../../../fakes/fake_security_keys.dart';
import '../../../helpers/test_app.dart' show bundledSuffixes;

const _rpId = 'vault.example.org';
final _server = Uri.parse('https://vault.example.org:8443/vault');

Uint8List _id(int n) => Uint8List.fromList(List.filled(32, n));

VwKeyChallenge _challenge(List<Uint8List> ids, {String rpId = _rpId, bool appId = false}) => VwKeyChallenge(
  challenge: 'x8G1k0ZH-D-N9AZUasBulEHWFpbehFLDT5O2O-L0Qmk',
  rpId: rpId,
  allowCredentials: ids,
  timeout: const Duration(minutes: 1),
  receivedAt: DateTime.utc(2026, 11, 16, 9),
  appId: appId ? 'https://vault.example.org:8443/app-id.json' : null,
);

/// A phone, a key held to it, and the step, with the PINs to type in turn.
class _Kit {
  _Kit(this.fido, {SecurityKeyCapabilities phone = FakeSecurityKeys.android, List<String?> pins = const [], FakeKey? key})
    : phone = FakeSecurityKeys(phone: phone),
      key = key ?? FakeKey(productName: 'Example Key', ctap: fido),
      _pins = [...pins];

  final FakeFidoKey fido;
  final FakeSecurityKeys phone;
  final FakeKey key;
  final List<String?> _pins;

  /// What the PIN prompt was opened with: null, or the wrong PIN's tries left.
  final asked = <int?>[];
  final statuses = <VwKeyStatus>[];

  late final step = VwKeyStep(
    keys: phone,
    now: phone.now,
    suffixes: bundledSuffixes,
    onStatus: statuses.add,
    askPin: (wrong) async {
      asked.add(wrong?.retries);
      final pin = _pins.isEmpty ? null : _pins.removeAt(0);
      return pin == null ? null : Uint8List.fromList(utf8.encode(pin));
    },
  );

  void present({Set<SecurityKeyLinkKind> kinds = const {SecurityKeyLinkKind.nfc}}) => phone.arrive(key.device(kinds: kinds));

  /// How many assertion requests the key got.
  int get assertions => fido.requests.where((request) => request == '2').length;
}

/// Checks [token] as a server would: the client data names [origin] and the
/// challenge, and [credential] signed the authenticator data and its hash.
void _expectSigned(String token, FakeSignInCredential credential, {String origin = 'https://vault.example.org:8443'}) {
  final json = jsonDecode(token) as Map<String, Object?>;
  final response = json['response']! as Map<String, Object?>;
  final clientData = unb64url(response['clientDataJson']! as String);
  expect(json['id'], b64url(credential.id));
  expect(json['rawId'], b64url(credential.id));
  expect(jsonDecode(utf8.decode(clientData)), {
    'type': 'webauthn.get',
    'challenge': 'x8G1k0ZH-D-N9AZUasBulEHWFpbehFLDT5O2O-L0Qmk',
    'origin': origin,
    'crossOrigin': false,
  });
  final authenticatorData = unb64url(response['authenticatorData']! as String);
  final signed = Uint8List.fromList([...authenticatorData, ...vwKeyClientDataHash(clientData)]);
  expect(es256Verify(credential.keyPair.point, signed, unb64url(response['signature']! as String)), isTrue);
}

Matcher _fails(VwKeyProblem problem) => throwsA(isA<VwKeyStepError>().having((e) => e.problem, 'problem', problem));

void main() {
  for (final kind in [SecurityKeyLinkKind.nfc, SecurityKeyLinkKind.usbHid]) {
    test('a registered key answers, over ${kind.name}', () async {
      final kit = _Kit(FakeFidoKey()..maxCredentialCountInList = 8);
      final credential = kit.fido.addSignInCredential(_rpId);
      kit.present(kinds: {kind});

      final token = await kit.step.answer(_challenge([_id(1), credential.id, _id(3)]), _server);

      _expectSigned(token, credential);
      expect(kit.asked, isEmpty, reason: 'no PIN is asked for when the key needs only a touch');
      expect(kit.fido.allowListLengths, [3]);
      expect(kit.phone.openLinks, isEmpty);
      expect(kit.phone.isWatching, isFalse);
    });
  }

  test('waits for the key to be presented', () async {
    final kit = _Kit(FakeFidoKey());
    final credential = kit.fido.addSignInCredential(_rpId);

    final answer = kit.step.answer(_challenge([credential.id]), _server);
    await pumpEventQueue();
    expect(kit.statuses, [VwKeyStatus.waiting]);
    kit.present();

    _expectSigned(await answer, credential);
  });

  test('on an iPhone reads the key under the NFC sheet', () async {
    final kit = _Kit(FakeFidoKey(), phone: FakeSecurityKeys.iphone);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    final step = VwKeyStep(keys: kit.phone, askPin: (_) async => null, nfcMessage: 'Hold your key', nfcFailure: 'No luck');
    _expectSigned(await step.answer(_challenge([credential.id]), _server), credential);

    expect(kit.phone.calls, containsAllInOrder(['beginNfc Hold your key', 'endNfc']));
    expect(kit.phone.nfcSheetUp, isFalse);
  });

  test('says when the key waits for a touch', () async {
    final kit = _Kit(FakeFidoKey()..waitsForTouch = true);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present(kinds: {SecurityKeyLinkKind.usbHid});

    await kit.step.answer(_challenge([credential.id]), _server);

    expect(kit.statuses, [VwKeyStatus.waiting, VwKeyStatus.touch, VwKeyStatus.waiting]);
  });

  test('a key that takes one credential at a time is asked once per id until it answers', () async {
    final kit = _Kit(FakeFidoKey.ctap20());
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    final token = await kit.step.answer(_challenge([_id(1), _id(2), credential.id, _id(4)]), _server);

    _expectSigned(token, credential);
    expect(kit.fido.allowListLengths, [1, 1, 1]);
  });

  test('a key with a limit gets the ids in batches of it', () async {
    final kit = _Kit(FakeFidoKey()..maxCredentialCountInList = 2);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    final token = await kit.step.answer(_challenge([_id(1), _id(2), _id(3), _id(4), credential.id]), _server);

    _expectSigned(token, credential);
    expect(kit.fido.allowListLengths, [2, 2, 1]);
  });

  test('uses the id sent when the key leaves the credential out of its answer', () async {
    final kit = _Kit(FakeFidoKey.ctap20()..omitsSingleCredential = true);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    _expectSigned(await kit.step.answer(_challenge([_id(1), credential.id]), _server), credential);
  });

  test('an unregistered key is said to be, after every id was tried', () async {
    final kit = _Kit(FakeFidoKey.ctap20())..fido.addSignInCredential('other.example.org');
    kit.present();

    await expectLater(kit.step.answer(_challenge([_id(1), _id(2)]), _server), _fails(VwKeyProblem.notRegistered));

    expect(kit.fido.allowListLengths, [1, 1]);
    expect(kit.phone.openLinks, isEmpty);
  });

  test('an unregistered key and an appid in the challenge points at an older registration', () async {
    final kit = _Kit(FakeFidoKey());
    kit.present();

    await expectLater(kit.step.answer(_challenge([_id(1)], appId: true), _server), _fails(VwKeyProblem.registeredOldWay));
  });

  test('a key set to always ask is asked for its PIN once, and then answers', () async {
    final kit = _Kit(FakeFidoKey(pin: '123456')..alwaysUv = true, pins: ['123456']);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    final token = await kit.step.answer(_challenge([credential.id]), _server);

    _expectSigned(token, credential);
    expect(kit.asked, [null]);
    // Refused without the PIN, then asked again with a token for this site
    expect(kit.assertions, 2);
    final authenticatorData = unb64url(
      ((jsonDecode(token) as Map<String, Object?>)['response']! as Map<String, Object?>)['authenticatorData']! as String,
    );
    expect(authenticatorData[32] & 0x04, 0x04, reason: 'the key verified the user');
  });

  test('a wrong PIN is said with the tries left, and nothing more is sent to the key', () async {
    final kit = _Kit(FakeFidoKey(pin: '123456')..alwaysUv = true, pins: ['000000', null]);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    await expectLater(kit.step.answer(_challenge([credential.id]), _server), throwsA(isA<SecurityKeyCancelled>()));

    expect(kit.asked, [null, 7]);
    expect(kit.assertions, 1, reason: 'only the first request, which carried no PIN');
    expect(kit.fido.retries, 7);
  });

  test('the right PIN after a wrong one signs', () async {
    final kit = _Kit(FakeFidoKey(pin: '123456')..alwaysUv = true, pins: ['000000', '123456']);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    _expectSigned(await kit.step.answer(_challenge([credential.id]), _server), credential);
    expect(kit.asked, [null, 7]);
  });

  test('backing out of the PIN prompt cancels', () async {
    final kit = _Kit(FakeFidoKey(pin: '123456')..alwaysUv = true, pins: [null]);
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    await expectLater(kit.step.answer(_challenge([credential.id]), _server), throwsA(isA<SecurityKeyCancelled>()));
    expect(kit.fido.retries, 8);
  });

  test('a locked PIN is the PIN\'s own error', () async {
    final kit = _Kit(FakeFidoKey(pin: '123456')..alwaysUv = true, pins: ['123456']);
    kit.fido.retries = 0;
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();

    await expectLater(kit.step.answer(_challenge([credential.id]), _server), throwsA(isA<PinBlocked>()));
  });

  test('a key that speaks only U2F is said to have no FIDO2', () async {
    final kit = _Kit(FakeFidoKey(), key: FakeKey(productName: 'Old Key'));
    kit.present();

    await expectLater(kit.step.answer(_challenge([_id(1)]), _server), _fails(VwKeyProblem.notFido2));
  });

  test('a key that lists no FIDO2 version is said to have no FIDO2', () async {
    final kit = _Kit(FakeFidoKey(versions: ['U2F_V2']));
    kit.present(kinds: {SecurityKeyLinkKind.usbHid});

    await expectLater(kit.step.answer(_challenge([_id(1)]), _server), _fails(VwKeyProblem.notFido2));
    expect(kit.assertions, 0);
  });

  test('a key plugged into an iPhone is told to use NFC', () async {
    final kit = _Kit(FakeFidoKey(), phone: FakeSecurityKeys.iphone);
    kit.fido.addSignInCredential(_rpId);
    kit.present(kinds: {SecurityKeyLinkKind.smartcard});

    await expectLater(kit.step.answer(_challenge([_id(1)]), _server), _fails(VwKeyProblem.iphoneNfcOnly));
  });

  test('a challenge for another site never looks for a key', () async {
    final kit = _Kit(FakeFidoKey());
    final credential = kit.fido.addSignInCredential('accounts.example.com');
    kit.present();
    final before = kit.phone.calls.length;

    await expectLater(
      kit.step.answer(_challenge([credential.id], rpId: 'accounts.example.com'), _server),
      throwsA(
        isA<VwKeyStepError>()
            .having((e) => e.problem, 'problem', VwKeyProblem.otherAddress)
            .having((e) => e.rpId, 'rpId', 'accounts.example.com'),
      ),
    );

    expect(kit.phone.calls, hasLength(before));
    expect(kit.phone.sent, isEmpty);
    expect(kit.fido.requests, isEmpty);
    expect(kit.statuses, isEmpty);
  });

  test('a parent domain in the challenge is asked about, and the origin stays the address', () async {
    final kit = _Kit(FakeFidoKey());
    final credential = kit.fido.addSignInCredential('example.org');
    kit.present();

    final token = await kit.step.answer(_challenge([credential.id], rpId: 'example.org'), _server);

    _expectSigned(token, credential);
  });

  test('a public suffix in the challenge, or a parent domain without the list, never looks for a key', () async {
    final kit = _Kit(FakeFidoKey());
    final credential = kit.fido.addSignInCredential('co.uk');
    kit.present();

    await expectLater(
      kit.step.answer(_challenge([credential.id], rpId: 'co.uk'), Uri.parse('https://vault.example.co.uk')),
      _fails(VwKeyProblem.otherAddress),
    );
    final bare = VwKeyStep(keys: kit.phone, askPin: (_) async => null, now: kit.phone.now);
    await expectLater(bare.answer(_challenge([credential.id], rpId: 'example.org'), _server), _fails(VwKeyProblem.otherAddress));

    expect(kit.fido.requests, isEmpty);
    expect(kit.statuses, isEmpty);
  });

  test('cancelling the wait for a key ends it', () async {
    final kit = _Kit(FakeFidoKey());

    final answer = kit.step.answer(_challenge([_id(1)]), _server);
    await pumpEventQueue();
    await kit.step.cancel();

    await expectLater(answer, throwsA(isA<SecurityKeyCancelled>()));
    expect(kit.phone.isWatching, isFalse);
  });

  test('a key taken away while it is asked is the connection\'s error', () async {
    final kit = _Kit(FakeFidoKey());
    final credential = kit.fido.addSignInCredential(_rpId);
    kit.present();
    // The assertion request: CLA 80, INS 10, then the command byte 02
    kit.phone.removeWhen = (frame) => frame.length > 7 && frame[0] == 0x80 && frame[1] == 0x10 && frame.contains(0x02) && frame.length > 60;

    await expectLater(kit.step.answer(_challenge([credential.id]), _server), throwsA(isA<SecurityKeyRemoved>()));
  });

  test('a phone that reaches a key over NFC or Android USB can do the step, an iPad cannot', () {
    expect(vwCanReachKey(FakeSecurityKeys.android), isTrue);
    expect(vwCanReachKey(FakeSecurityKeys.iphone), isTrue);
    expect(vwCanReachKey(const SecurityKeyCapabilities(usb: true)), isTrue);
    expect(vwCanReachKey(FakeSecurityKeys.ipad), isFalse);
    expect(vwCanReachKey(SecurityKeyCapabilities.none), isFalse);
  });
}
