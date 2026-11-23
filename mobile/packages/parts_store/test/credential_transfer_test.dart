import 'package:credential_transfer/credential_transfer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/credential_transfer.dart';
import 'package:kemlock_ports/kemlock_ports.dart';

/// Answers the plugin's channel as its Kotlin class does, and notes what was asked.
class _Phone {
  _Phone(this.answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(credentialTransferChannel, (call) async {
      calls.add(call);
      return answer(call);
    });
  }

  final Object? Function(MethodCall call) answer;
  final calls = <MethodCall>[];

  void close() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(credentialTransferChannel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Phone phone;
  tearDown(() => phone.close());

  final transfer = PlayCredentialTransfer();
  const types = {'basic-auth', 'passkey', 'totp'};

  test('asks the system for the credential types and answers the JSON the exporter sent', () async {
    phone = _Phone((call) => '{"version":{"major":1,"minor":0}}');

    expect(await transfer.importCredentials(types), '{"version":{"major":1,"minor":0}}');

    expect(phone.calls.single.method, 'importCredentials');
    expect((phone.calls.single.arguments as Map<Object?, Object?>)['types'], unorderedEquals(types));
  });

  test('answers null when the person closes the list, with no error', () async {
    phone = _Phone((call) => null);

    expect(await transfer.importCredentials(types), isNull);
  });

  test('says each of the plugin error codes as its own problem', () async {
    const codes = {
      TransferErrorCodes.noExportOption: CredentialTransferProblem.noExportOption,
      TransferErrorCodes.unavailable: CredentialTransferProblem.unavailable,
      TransferErrorCodes.invalidJson: CredentialTransferProblem.invalidJson,
      TransferErrorCodes.system: CredentialTransferProblem.system,
      TransferErrorCodes.unknownCaller: CredentialTransferProblem.unknownCaller,
      TransferErrorCodes.unknown: CredentialTransferProblem.unknown,
      // Kotlin's own refusals, and a code a later version may add, are not told apart
      TransferErrorCodes.busy: CredentialTransferProblem.unknown,
      TransferErrorCodes.noActivity: CredentialTransferProblem.unknown,
      TransferErrorCodes.badRequest: CredentialTransferProblem.unknown,
      'somethingNew': CredentialTransferProblem.unknown,
    };
    for (final MapEntry(key: code, value: problem) in codes.entries) {
      phone = _Phone((call) => throw PlatformException(code: code));

      await expectLater(
        transfer.importCredentials(types),
        throwsA(isA<CredentialTransferException>().having((e) => e.problem, 'problem', problem)),
        reason: code,
      );
      phone.close();
    }
  });

  test('keeps nothing of the error text in the exception it throws', () async {
    phone = _Phone((call) => throw PlatformException(code: TransferErrorCodes.system, message: 'secret-in-a-message'));

    await expectLater(
      transfer.importCredentials(types),
      throwsA(isA<CredentialTransferException>().having((e) => '$e', 'text', isNot(contains('secret')))),
    );
  });

  test('is available when the plugin says so, and not where there is no plugin', () async {
    phone = _Phone((call) => true);
    expect(await transfer.isAvailable(), isTrue);
    phone.close();

    phone = _Phone((call) => false);
    expect(await transfer.isAvailable(), isFalse);
    phone.close();

    // No native side at all, as on iOS or in a test
    phone = _Phone((call) => throw MissingPluginException());
    expect(await transfer.isAvailable(), isFalse);
  });
}
