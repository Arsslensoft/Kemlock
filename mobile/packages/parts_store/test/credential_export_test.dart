import 'package:credential_transfer/credential_transfer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock_parts/src/credential_export.dart';
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

  final export = PlayCredentialExport();

  test('registers each vault with the credential types and nothing of what it holds', () async {
    phone = _Phone((call) => null);

    await export.registerExports(
      const [ExportVault(vaultId: 'main'), ExportVault(vaultId: 'work', name: 'Work')],
      const {'basic-auth', 'totp'},
    );

    final call = phone.calls.single;
    expect(call.method, 'registerExports');
    final arguments = call.arguments as Map<Object?, Object?>;
    expect(arguments['entries'], [
      {'vaultId': 'main', 'account': null},
      {'vaultId': 'work', 'account': 'Work'},
    ]);
    expect(arguments['types'], unorderedEquals(['basic-auth', 'totp']));
    // The entry's secret id is made in Kotlin: Dart neither sends nor gets one
    expect(arguments.keys, unorderedEquals(['entries', 'types']));
  });

  test('asks the plugin to clear only what is registered, with nothing sent', () async {
    phone = _Phone((call) => null);

    await export.clearExports();

    expect(phone.calls.single.method, 'clearRegisteredExports');
    expect(phone.calls.single.arguments, isNull);
  });

  test('says a failed clear as a problem, and no plugin as unavailable', () async {
    phone = _Phone((call) => throw PlatformException(code: TransferErrorCodes.registerFailed));
    await expectLater(
      export.clearExports(),
      throwsA(isA<CredentialExportException>().having((e) => e.problem, 'problem', CredentialExportProblem.registerFailed)),
    );
    phone.close();

    phone = _Phone((call) => throw MissingPluginException());
    await expectLater(
      export.clearExports(),
      throwsA(isA<CredentialExportException>().having((e) => e.problem, 'problem', CredentialExportProblem.unavailable)),
    );
  });

  test('says each of the plugin error codes as its own problem', () async {
    const codes = {
      TransferErrorCodes.registerFailed: CredentialExportProblem.registerFailed,
      TransferErrorCodes.gone: CredentialExportProblem.gone,
      TransferErrorCodes.unavailable: CredentialExportProblem.unavailable,
      'somethingNew': CredentialExportProblem.unknown,
    };
    for (final MapEntry(key: code, value: problem) in codes.entries) {
      phone = _Phone((call) => throw PlatformException(code: code));

      await expectLater(
        export.answerExport('req', '{}'),
        throwsA(isA<CredentialExportException>().having((e) => e.problem, 'problem', problem)),
        reason: code,
      );
      phone.close();
    }
  });

  test('keeps nothing of the data or the error text in the exception it throws', () async {
    phone = _Phone((call) => throw PlatformException(code: TransferErrorCodes.gone, message: 'secret-in-a-message'));

    await expectLater(
      export.answerExport('req', '{"password":"hunter2-secret"}'),
      throwsA(isA<CredentialExportException>().having((e) => '$e', 'text', allOf(isNot(contains('secret')), isNot(contains('hunter2'))))),
    );
  });

  test('answers a request by its id with the JSON', () async {
    phone = _Phone((call) => null);

    await export.answerExport('req-1', '{"version":1}');

    expect(phone.calls.single.method, 'answerExport');
    expect(phone.calls.single.arguments, {'id': 'req-1', 'json': '{"version":1}'});
  });

  test('reads the request that waited as a request, and nothing from a malformed one', () async {
    phone = _Phone(
      (call) => {
        'id': 'req-1',
        'vaultId': 'main',
        'app': '1Password',
        'package': 'com.onepassword',
        'types': ['basic-auth', 'passkey'],
      },
    );
    final request = await export.pendingExport();
    expect(request?.id, 'req-1');
    expect(request?.vaultId, 'main');
    expect(request?.app, '1Password');
    expect(request?.package, 'com.onepassword');
    expect(request?.types, {'basic-auth', 'passkey'});
    expect('$request', isNot(contains('basic-auth')));
    phone.close();

    phone = _Phone((call) => {'id': 'req-1'});
    expect(await export.pendingExport(), isNull);
    phone.close();

    phone = _Phone((call) => null);
    expect(await export.pendingExport(), isNull);
  });

  test('refusing a request that is gone is not an error, and no plugin is no request', () async {
    phone = _Phone((call) => throw PlatformException(code: TransferErrorCodes.gone));
    await export.refuseExport('req');
    phone.close();

    phone = _Phone((call) => throw MissingPluginException());
    await export.refuseExport('req');
    expect(await export.pendingExport(), isNull);
    await expectLater(
      export.registerExports(const [ExportVault(vaultId: 'main')], const {'basic-auth'}),
      throwsA(isA<CredentialExportException>().having((e) => e.problem, 'problem', CredentialExportProblem.unavailable)),
    );
  });

  test('hands on the requests that arrive while the app runs', () async {
    phone = _Phone((call) => null);
    final arrived = export.exportRequests.first;

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      credentialTransferChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('exportRequested', {
          'id': 'req-9',
          'vaultId': 'work',
          'app': 'Bitwarden',
          'package': 'com.x8bit.bitwarden',
          'types': ['totp'],
        }),
      ),
      (_) {},
    );

    final request = await arrived;
    expect(request.id, 'req-9');
    expect(request.vaultId, 'work');
    expect(request.types, {'totp'});
  });
}
