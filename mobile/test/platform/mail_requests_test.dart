import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/platform/mail_requests.dart';

/// The channel the mail provider's service speaks (openspec:
/// add-pgp-mail-provider, task 4.1).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a call', () {
    test('decodes, keeping only the extras Kemlock reads', () {
      final call = MailCall.fromMap({
        'requestId': 'r1',
        'resentFrom': 'r0',
        'action': 'org.openintents.openpgp.action.SIGN_AND_ENCRYPT',
        'extras': {
          'api_version': 12,
          'ascii_armor': true,
          'key_ids': Int64List.fromList([1, -2]),
          'user_ids': ['ada@example.org'],
          'passphrase': 'secret',
          'eu.faircode.email': {'id': 1},
          'progress_messenger': null,
        },
        'caller': {'package': 'eu.faircode.email', 'cert': 'ab', 'label': 'FairEmail'},
        'input': Uint8List.fromList([1, 2, 3]),
      });
      expect(call.requestId, 'r1');
      expect(call.resentFrom, 'r0');
      expect(call.action, 'org.openintents.openpgp.action.SIGN_AND_ENCRYPT');
      expect(call.extras.keys.toSet(), {'api_version', 'ascii_armor', 'key_ids', 'user_ids'});
      expect(call.extras['key_ids'], [1, -2]);
      expect(call.caller, const MailCaller(package: 'eu.faircode.email', cert: 'ab', label: 'FairEmail'));
      expect(call.input, [1, 2, 3]);
      expect(call.inputTooLarge, isFalse);
      expect(call.dry, isFalse);
      expect(call.withoutInput().input, isNull);
    });

    test('asked first without its input is dry, and what is kept of it is not', () {
      final call = MailCall.fromMap(const {'requestId': 'r1', 'action': 'org.openintents.openpgp.action.SIGN', 'dry': true});
      expect(call.dry, isTrue);
      expect(call.input, isNull);
      expect(call.withoutInput().dry, isFalse);
    });

    test('with nothing in it is a refused caller with no action', () {
      final call = MailCall.fromMap(const {});
      expect(call.action, '');
      expect(call.extras, isEmpty);
      expect(call.caller.refusal, MailCallerRefusal.noPackage);
    });
  });

  test('an answer is the result and the output', () {
    final answer = MailAnswer(const {'result_code': 1}, output: Uint8List.fromList([7]));
    expect(answer.resultCode, 1);
    expect(answer.toMap(), {
      'result': {'result_code': 1},
      'output': [7],
    });
    expect(answer.wantsInput, isFalse);
    // What the service reads its input pipe on, and nothing else
    expect(MailAnswer.sendInput.wantsInput, isTrue);
    expect(MailAnswer.sendInput.toMap(), {'sendInput': true});
  });

  group('without the native side', () {
    test('the channel serves and finishes without throwing', () async {
      final requests = ChannelMailRequests();
      requests.serve(answer: (_) async => const MailAnswer({'result_code': 1}), front: (_) {}, left: (_) {});
      await requests.finish('r1', ok: true);
      // The channel's handler answers a call sent as the service would
      final reply = await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'com.kemlock.app/mail',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('execute', {'requestId': 'r2', 'action': 'x', 'caller': <String, Object?>{}}),
        ),
        null,
      );
      expect(const StandardMethodCodec().decodeEnvelope(reply!), {
        'result': {'result_code': 1},
        'output': null,
      });
    });

    test('iOS gets no mail provider at all', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final requests = container.read(mailRequestsProvider);
      expect(requests, isA<NoMailRequests>());
      requests.serve(answer: (_) async => throw StateError('never'), front: (_) {}, left: (_) {});
      await requests.finish('r1', ok: false);
    });
  });
}
