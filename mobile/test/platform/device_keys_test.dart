// The phone's device keys over a fake channel and a fake of the hardware: what the Dart side sends, how
// it reads the answers and the errors, how a hardware key signs a DPoP proof, and the fall back to a
// sealed software key where the phone has none (add-kemlock-server-sync, tasks 4.1 and 4.2).
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/p256.dart';
import 'package:kemlock/features/sync/kemlock/km_device_key.dart';
import 'package:kemlock/features/sync/kemlock/km_dpop.dart';
import 'package:kemlock/platform/device_keys.dart';

import '../fakes/fake_device_keys.dart';

const _channel = MethodChannel('com.kemlock.app/device_keys');

Uint8List _point() => Uint8List.fromList([4, ...List.generate(32, (i) => i + 1), ...List.generate(32, (i) => i + 101)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answer(Future<Object?> Function(MethodCall call) answer) {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return answer(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  }

  group('the channel', () {
    test('asks whether the phone has hardware, and says no when nothing answers', () async {
      answer((_) async => true);
      expect(await const ChannelDeviceKeys().hardware(), isTrue);

      answer((_) async => throw PlatformException(code: 'failed'));
      expect(await const ChannelDeviceKeys().hardware(), isFalse);

      messenger.setMockMethodCallHandler(_channel, null);
      expect(await const ChannelDeviceKeys().hardware(), isFalse);
    });

    test('hands the tag, the use and the bytes over, and reads the key and the signature back', () async {
      answer(
        (call) async => switch (call.method) {
          'create' || 'info' => {'protection': 'secure-enclave', 'point': _point()},
          'sign' => Uint8List.fromList([1, 2, 3]),
          'wrap' => Uint8List.fromList([4, 5]),
          'unwrap' => Uint8List.fromList([6]),
          _ => null,
        },
      );
      const keys = ChannelDeviceKeys();

      final made = await keys.create('dpop.main.acct', DeviceKeyUse.signing);
      final info = await keys.info('dpop.main.acct');
      final signature = await keys.sign('dpop.main.acct', Uint8List.fromList([9]));
      final wrapped = await keys.wrap('trust.main.acct', Uint8List.fromList([7]));
      final opened = await keys.unwrap('trust.main.acct', Uint8List.fromList([8]));
      await keys.delete('dpop.main.acct');

      expect(made.protection, 'secure-enclave');
      expect(made.point, _point());
      expect(info?.point, _point());
      expect(signature, [1, 2, 3]);
      expect(wrapped, [4, 5]);
      expect(opened, [6]);
      expect([for (final call in calls) call.method], ['create', 'info', 'sign', 'wrap', 'unwrap', 'delete']);
      expect(calls.first.arguments, {'tag': 'dpop.main.acct', 'use': 'signing'});
      expect(calls[2].arguments, {
        'tag': 'dpop.main.acct',
        'message': Uint8List.fromList([9]),
      });
      expect(calls[3].arguments, {
        'tag': 'trust.main.acct',
        'data': Uint8List.fromList([7]),
      });
    });

    test('a key that is not there is null, and a wrapping key has no public point', () async {
      answer((call) async => call.method == 'info' ? null : {'protection': 'keystore'});
      const keys = ChannelDeviceKeys();

      expect(await keys.info('gone'), isNull);
      expect((await keys.create('trust.x', DeviceKeyUse.wrapping)).point, isNull);
    });

    test('maps the platform’s error codes, and a build with no native side is unavailable', () async {
      const keys = ChannelDeviceKeys();
      Future<DeviceKeyProblem> problem(Future<Object?> Function() call) async {
        try {
          await call();
        } on DeviceKeyError catch (e) {
          return e.problem;
        }
        fail('expected an error');
      }

      answer((_) async => throw PlatformException(code: 'unavailable'));
      expect(await problem(() => keys.create('t', DeviceKeyUse.signing)), DeviceKeyProblem.unavailable);
      answer((_) async => throw PlatformException(code: 'missing'));
      expect(await problem(() => keys.sign('t', Uint8List(1))), DeviceKeyProblem.missing);
      answer((_) async => throw PlatformException(code: 'anything else', message: 'Keychain error'));
      expect(await problem(() => keys.unwrap('t', Uint8List(1))), DeviceKeyProblem.failed);
      messenger.setMockMethodCallHandler(_channel, null);
      expect(await problem(() => keys.create('t', DeviceKeyUse.signing)), DeviceKeyProblem.unavailable);
      await keys.delete('t');
    });
  });

  group('a hardware key', () {
    test('signs a DPoP proof whose signature verifies against its public key, with the private half never asked for', () async {
      final keys = FakeDeviceKeys();
      final choice = await createDeviceKey(keys, 'dpop.main.acct');

      final proof = await KmDpop(choice.key).proof('GET', Uri.parse('https://kem.example.com/kem/v1/sync'));

      final parts = proof.split('.');
      final signature = b64urlDecode(parts[2]);
      final jwk = choice.key.publicJwk;
      final point = Uint8List.fromList([4, ...b64urlDecode(jwk['x']!), ...b64urlDecode(jwk['y']!)]);
      expect(signature, hasLength(64), reason: 'the hardware’s DER, made the raw bytes a JWS carries');
      expect(es256Verify(point, Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')), rawToDerEs256(signature)), isTrue);
      expect(keys.calls, ['create dpop.main.acct signing', 'sign dpop.main.acct']);
      expect(choice.software, isFalse);
      expect(choice.reference, {'protection': 'secure-enclave', 'tag': 'dpop.main.acct'});
    });

    test('is found again from the session’s reference, and is gone when the phone lost it', () async {
      final keys = FakeDeviceKeys(protection: 'keystore');
      final made = await createDeviceKey(keys, 'dpop.main.acct');

      final again = await openDeviceKey(keys, made.reference);

      expect(again?.key.publicJwk, made.key.publicJwk);
      expect(again?.key.protection, 'keystore');
      await keys.delete('dpop.main.acct');
      expect(await openDeviceKey(keys, made.reference), isNull);
      expect(await openDeviceKey(keys, null), isNull);
      expect(await openDeviceKey(keys, {'protection': 'keystore'}), isNull);
    });
  });

  group('a phone with no hardware key', () {
    test('gets a software key whose scalar is in the reference to seal, and the sheet says so', () async {
      final keys = FakeDeviceKeys(hasHardware: false);

      final choice = await createDeviceKey(keys, 'dpop.main.acct');

      expect(choice.software, isTrue);
      expect(choice.key.protection, DeviceKeyProtection.software);
      expect(choice.reference['protection'], 'software');
      expect(b64urlDecode(choice.reference['scalar']! as String), hasLength(32));
    });

    test('opens the same software key again from the sealed reference, and it signs as before', () async {
      final keys = FakeDeviceKeys(hasHardware: false);
      final made = await createDeviceKey(keys, 'dpop.main.acct');

      final again = await openDeviceKey(keys, made.reference);

      expect(again?.software, isTrue);
      expect(again?.key.publicJwk, made.key.publicJwk);
      final message = Uint8List.fromList([1, 2, 3]);
      final signature = await again!.key.sign(message);
      final jwk = again.key.publicJwk;
      final point = Uint8List.fromList([4, ...b64urlDecode(jwk['x']!), ...b64urlDecode(jwk['y']!)]);
      expect(es256Verify(point, message, rawToDerEs256(signature)), isTrue);
      expect(await openDeviceKey(keys, {'protection': 'software'}), isNull);
      expect(await openDeviceKey(keys, {'protection': 'software', 'scalar': '!!'}), isNull);
    });

    test('is made only when the platform says unavailable: any other failure of the hardware is thrown', () async {
      final keys = FakeDeviceKeys()..failNext = DeviceKeyProblem.failed;

      await expectLater(createDeviceKey(keys, 'dpop.main.acct'), throwsA(isA<DeviceKeyError>()));
    });
  });
}
