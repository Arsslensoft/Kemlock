import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kemlock/features/security_keys/spike_page.dart';
import 'package:kemlock/router.dart';
import 'package:kemlock/ui/ui.dart';

import '../../helpers/app_harness.dart';

const _channel = MethodChannel('com.kemlock.app/security_keys');
const _events = EventChannel('com.kemlock.app/security_keys/events');

Iterable<String> _paths(List<RouteBase> routes) sync* {
  for (final route in routes) {
    if (route is GoRoute) yield route.path;
    yield* _paths(route.routes);
  }
}

void main() {
  test('a build without the define has no spike route', () {
    expect(keySpikeEnabled, isFalse, reason: 'tests, like releases, are built without KEY_SPIKE');
    expect(keySpikeRoutes(), isEmpty);
    expect(keySpikeRoutes(enabled: false), isEmpty);
    expect(_paths(keySpikeRoutes(enabled: true)), [keySpikePath]);
  });

  testWidgets('the app’s router has no spike route, and Settings no way to it', (tester) async {
    final app = TestApp();
    await tester.runAsync(() => app.createVault('pw'));
    await app.pump(tester);

    final router = app.container.read(routerProvider);
    expect(_paths(router.configuration.routes), isNot(contains(keySpikePath)));
    expect(_paths(router.configuration.routes), contains('/settings'));
    expect(find.text('Key spike'), findsNothing);
  });

  testWidgets('with a mocked channel the page shows every frame in hex with its timing', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final arguments = (call.arguments as Map<Object?, Object?>?) ?? const {};
      calls.add(call.method);
      switch (call.method) {
        case 'capabilities':
          return {'nfc': true, 'nfcOn': true, 'usb': true, 'smartcards': false, 'readsOnRequest': false};
        case 'present':
          return [
            {
              'device': 'nfc:1',
              'needsPermission': false,
              'links': [
                {'id': 'nfc:1', 'kind': 'nfc', 'extendedLength': true},
              ],
            },
          ];
        case 'transceive':
          final apdu = arguments['data']! as Uint8List;
          // SELECT answers "U2F_V2"; the CTAP messages answer a status byte.
          return apdu[1] == 0xa4 ? bytes([0x55, 0x32, 0x46, 0x5f, 0x56, 0x32, 0x90, 0x00]) : bytes([0x00, 0xa1, 0x01, 0x80, 0x90, 0x00]);
      }
      return null;
    });
    messenger.setMockStreamHandler(_events, MockStreamHandler.inline(onListen: (_, _) {}));
    addTearDown(() {
      messenger.setMockMethodCallHandler(_channel, null);
      messenger.setMockStreamHandler(_events, null);
    });

    final router = GoRouter(initialLocation: keySpikePath, routes: keySpikeRoutes(enabled: true));
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(theme: buildAppTheme(Brightness.dark), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(KeySpikePage), findsOneWidget);
    expect(find.textContaining('nfc=true on=true usb=true'), findsOneWidget);
    expect(find.textContaining('arrived nfc:1'), findsOneWidget);
    // The hand-written SELECT of A0000006472F0001, and what came back.
    expect(find.textContaining('> 00 a4 04 00 08 a0 00 00 06 47 2f 00 01 00'), findsOneWidget);
    expect(find.textContaining('< 55 32 46 5f 56 32 90 00'), findsOneWidget);
    // authenticatorGetInfo and clientPIN getKeyAgreement, as NFCCTAP_MSG.
    expect(find.textContaining('> 80 10 00 00 01 04 00'), findsOneWidget);
    expect(find.textContaining('> 80 10 00 00 06 06 a2 01 01 02 02 00'), findsOneWidget);
    expect(find.textContaining('nfc SELECT'), findsOneWidget);
    expect(find.textContaining(RegExp(r'nfc getInfo  \d+ ms')), findsOneWidget);
    expect(find.textContaining(RegExp(r'nfc getKeyAgreement  \d+ ms')), findsOneWidget);
    expect(calls.where((call) => call == 'transceive'), hasLength(3));
    expect(calls, containsAllInOrder(['capabilities', 'present', 'open', 'transceive', 'close']));
  });
}
