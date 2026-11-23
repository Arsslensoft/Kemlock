// Offline mode covers Kemlock Server beyond its requests (add-kemlock-server-sync, task 12.1): the browser sheet of
// SSO opens nothing, and the live socket makes no connection. The requests, the setup sheet and the on sheet are
// checked in km_gate_test.dart, kemlock_setup_test.dart and kemlock_sheet_test.dart, the socket's closing in
// kemlock_live_test.dart.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/browser_auth.dart';
import 'package:kemlock/platform/network.dart';

const _channel = MethodChannel('com.kemlock.app/browser_auth');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  test('with offline mode on the browser sheet is not opened', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return 'kemlock://sso?code=c&state=s';
    });

    await expectLater(
      ChannelBrowserAuth(NetworkGate(() => true)).authenticate(Uri.parse('https://kem.example.com/sso'), state: 's'),
      throwsA(isA<OfflineException>()),
    );

    expect(calls, isEmpty);
  });

  test('with offline mode off the browser sheet is opened with the sign-in\'s state', () async {
    Object? sent;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      sent = call.arguments;
      return 'kemlock://sso?code=c&state=s';
    });

    final redirect = await ChannelBrowserAuth(NetworkGate(() => false)).authenticate(Uri.parse('https://kem.example.com/sso'), state: 's');

    expect(redirect, Uri.parse('kemlock://sso?code=c&state=s'));
    expect(sent, {'url': 'https://kem.example.com/sso', 'state': 's'});
  });

  test('with offline mode on the live socket makes no connection', () async {
    await expectLater(
      connectLiveSocket(NetworkGate(() => true), Uri.parse('wss://kem.example.com/kem/v1/live')),
      throwsA(isA<OfflineException>()),
    );
  });
}
