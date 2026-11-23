// The iOS export's channel (plan add-credential-exchange, tasks 8.3 and 8.6): the system's sheet opens first, and
// the payload is made only when the native side asks for it once the person has gone on, never sent with the call.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/credential_exchange.dart';

const _channel = MethodChannel('com.kemlock.app/credential_exchange');
const _codec = StandardMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  /// What the native side does on an `export` call: [onExport] runs in its place, and may ask Dart for the payload.
  void native(Future<Object?> Function() onExport) {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return call.method == 'export' ? onExport() : Future<Object?>.value();
    });
  }

  /// The native side asking Dart for the payload (`exportJson`): the text, or the code of the error it got back.
  Future<Object?> askForPayload() async {
    final reply = Completer<ByteData?>();
    await messenger.handlePlatformMessage(_channel.name, _codec.encodeMethodCall(const MethodCall('exportJson')), reply.complete);
    try {
      return _codec.decodeEnvelope((await reply.future)!);
    } on PlatformException catch (error) {
      return 'error:${error.code}:${error.message}';
    }
  }

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test('sends no JSON with the call, and makes the payload only when the system asks for it', () async {
    var made = 0;
    final seen = <int>[];
    Object? payload;
    native(() async {
      seen.add(made);
      payload = await askForPayload();
      return null;
    });
    final exchange = ChannelIosCredentialExchange();

    await exchange.export(() async {
      made++;
      return '{"accounts":[]}';
    });

    expect(calls.single.method, 'export');
    expect(calls.single.arguments, isNull);
    // Nothing was made when the sheet opened, and one payload was when the native side asked
    expect(seen, [0]);
    expect(made, 1);
    expect(payload, '{"accounts":[]}');
  });

  test('never makes the payload when the person closes the system sheet', () async {
    var made = 0;
    native(() async => throw PlatformException(code: 'cancelled'));
    final exchange = ChannelIosCredentialExchange();

    await expectLater(
      exchange.export(() async {
        made++;
        return '{}';
      }),
      throwsA(isA<IosExportCancelled>()),
    );

    expect(made, 0);
  });

  test('tells the system a failure with no text when the payload could not be made', () async {
    Object? told;
    native(() async {
      told = await askForPayload();
      throw PlatformException(code: 'failed');
    });
    final exchange = ChannelIosCredentialExchange();

    await expectLater(exchange.export(() async => throw StateError('password hunter2-secret')), throwsA(isA<IosExchangeFailed>()));

    expect(told, 'error:failed:null');
  });

  test('makes the payload once: a second ask finds nothing, and so does one after the export ended', () async {
    var made = 0;
    final answers = <Object?>[];
    native(() async {
      answers.add(await askForPayload());
      answers.add(await askForPayload());
      return null;
    });
    final exchange = ChannelIosCredentialExchange();

    await exchange.export(() async {
      made++;
      return '{}';
    });
    answers.add(await askForPayload());

    expect(made, 1);
    expect(answers, ['{}', 'error:gone:null', 'error:gone:null']);
  });

  test('says every other end of the native call as a failure', () async {
    native(() async => throw PlatformException(code: 'failed', message: 'AuthenticationServices 1'));
    final exchange = ChannelIosCredentialExchange();

    await expectLater(exchange.export(() async => '{}'), throwsA(isA<IosExchangeFailed>()));
  });
}
