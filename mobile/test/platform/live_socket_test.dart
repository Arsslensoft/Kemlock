// The live socket opened through the gate (add-kemlock-server-sync, task 11.3), against a real WebSocket server on
// loopback: the upgrade carries the headers it was given, frames arrive as text, offline mode refuses it before
// anything is opened, and an address that isn't wss is refused.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/network.dart';

void main() {
  late HttpServer server;
  final upgrades = <HttpHeaders>[];

  setUp(() async {
    upgrades.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      upgrades.add(request.headers);
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('{"type":"sync"}');
      socket.add(List<int>.filled(4, 1));
      socket.add('x' * (maxLiveFrameBytes + 1));
      socket.add('approval');
      await socket.close();
    });
  });

  tearDown(() => server.close(force: true));

  Uri address() => Uri.parse('ws://127.0.0.1:${server.port}/kem/v1/live');

  test('carries the upgrade headers and gives the text frames, dropping binary and over-long ones', () async {
    final socket = await connectLiveSocket(
      NetworkGate(() => false),
      address(),
      headers: const {'Authorization': 'DPoP token-1', 'DPoP': 'proof-1'},
      allowPlain: true,
    );

    final frames = await socket.frames.toList().timeout(const Duration(seconds: 10));

    expect(frames, ['{"type":"sync"}', 'approval']);
    expect(upgrades.single.value('authorization'), 'DPoP token-1');
    expect(upgrades.single.value('dpop'), 'proof-1');
    await socket.close();
  });

  test('offline mode refuses it before any connection is made', () async {
    await expectLater(connectLiveSocket(NetworkGate(() => true), address(), allowPlain: true), throwsA(isA<OfflineException>()));
    expect(upgrades, isEmpty);
  });

  test('an address that is not wss is refused, and nothing is opened', () async {
    await expectLater(connectLiveSocket(NetworkGate(() => false), address()), throwsA(isA<WebSocketException>()));
    await expectLater(
      connectLiveSocket(NetworkGate(() => false), Uri.parse('http://127.0.0.1:${server.port}/kem/v1/live'), allowPlain: true),
      throwsA(isA<WebSocketException>()),
    );
    expect(upgrades, isEmpty);
  });

  test('a server that does not upgrade is a failure, not a hang', () async {
    final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => plain.close(force: true));
    plain.listen((request) {
      request.response.statusCode = 401;
      request.response.close();
    });

    await expectLater(
      connectLiveSocket(NetworkGate(() => false), Uri.parse('ws://127.0.0.1:${plain.port}/kem/v1/live'), allowPlain: true),
      throwsA(isA<WebSocketException>()),
    );
  });
}
