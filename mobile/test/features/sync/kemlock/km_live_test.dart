// The live socket's engine (add-kemlock-server-sync, task 11.3), on a fake server and a fake clock: it opens, takes
// frames of the two types, opens again after a drop with a back-off from 2 s doubling to 5 minutes, starts that
// over once a socket stayed open, and stops when told.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_live.dart';

import '../../../fakes/fake_live_server.dart';

final _upgrade = KmLiveUpgrade(
  url: Uri.parse('wss://kem.example.com/kem/v1/live'),
  headers: const {'Authorization': 'DPoP token', 'DPoP': 'proof'},
  pin: 'AA:BB',
);

({KmLive live, FakeLiveServer server, List<KmLiveFrame> frames}) _make(FakeAsync async) {
  final server = FakeLiveServer();
  final frames = <KmLiveFrame>[];
  final live = KmLive(
    upgrade: () async => _upgrade,
    connect: server.connect,
    onFrame: frames.add,
    clock: () => DateTime.utc(2026, 11, 22).add(async.elapsed),
  );
  return (live: live, server: server, frames: frames);
}

void main() {
  test('opens at once with the upgrade it was given, pin and all', () {
    fakeAsync((async) {
      final made = _make(async);
      made.live.start();
      async.flushMicrotasks();

      expect(made.live.open, isTrue);
      final socket = made.server.current!;
      expect(socket.url, _upgrade.url);
      expect(socket.headers, _upgrade.headers);
      expect(socket.pin, 'AA:BB');
    });
  });

  test('reads a frame of either type, bare or as JSON, and drops one it does not know', () {
    fakeAsync((async) {
      final made = _make(async);
      made.live.start();
      async.flushMicrotasks();
      final socket = made.server.current!;

      socket.send('sync');
      socket.send('{"type":"approval"}');
      socket.send('{"type":"wipe"}');
      socket.send('not json {');
      socket.send('x' * 5000);
      async.flushMicrotasks();

      expect(made.frames, [KmLiveFrame.sync, KmLiveFrame.approval]);
    });
  });

  test('opens again after a drop, waiting 2 s the first time', () {
    fakeAsync((async) {
      final made = _make(async);
      made.live.start();
      async.flushMicrotasks();
      made.server.current!.drop();
      async.flushMicrotasks();

      expect(made.live.open, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(made.server.sockets, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(made.server.sockets, hasLength(2));
      expect(made.live.open, isTrue);
    });
  });

  test('backs off from 2 s, doubling, to 5 minutes and no further', () {
    expect([for (var i = 1; i <= 10; i++) KmLive.delayAfter(i).inSeconds], [2, 4, 8, 16, 32, 64, 128, 256, 300, 300]);
    fakeAsync((async) {
      final made = _make(async);
      made.server.refuse = true;
      made.live.start();
      async.flushMicrotasks();
      expect(made.server.attempts, hasLength(1));

      for (final wait in [2, 4, 8, 16]) {
        final before = made.server.attempts.length;
        async.elapse(Duration(seconds: wait - 1));
        async.flushMicrotasks();
        expect(made.server.attempts, hasLength(before), reason: 'just before $wait s');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(made.server.attempts, hasLength(before + 1), reason: 'after $wait s');
      }
      expect(made.live.failures, 5);
      made.live.stop();
    });
  });

  test('a socket that stays open a minute starts the back-off over; one dropped at once does not', () {
    fakeAsync((async) {
      final made = _make(async);
      made.live.start();
      async.flushMicrotasks();
      // Dropped at once: 2 s, then 4 s
      made.server.current!.drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      made.server.current!.drop();
      async.flushMicrotasks();
      expect(made.live.failures, 2);
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(made.live.open, isTrue);

      // Open for a minute, then dropped: back to 2 s
      async.elapse(KmLive.steady);
      made.server.current!.drop();
      async.flushMicrotasks();
      expect(made.live.failures, 1);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(made.live.open, isTrue);
      made.live.stop();
    });
  });

  test('stop closes the socket and no more attempts are made', () {
    fakeAsync((async) {
      final made = _make(async);
      made.live.start();
      async.flushMicrotasks();
      final socket = made.server.current!;

      made.live.stop();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 10));

      expect(socket.closed, isTrue);
      expect(made.live.open, isFalse);
      expect(made.server.attempts, hasLength(1));
    });
  });

  test('an upgrade that cannot be made, or that is null, is a failed attempt', () {
    fakeAsync((async) {
      final server = FakeLiveServer();
      var calls = 0;
      final live = KmLive(
        upgrade: () async {
          calls++;
          if (calls == 1) {
            throw StateError('no session');
          }
          return calls == 2 ? null : _upgrade;
        },
        connect: server.connect,
        onFrame: (_) {},
      );
      live.start();
      async.flushMicrotasks();
      expect(live.failures, 1);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(live.failures, 2);
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();

      expect(live.open, isTrue);
      expect(server.attempts, hasLength(1));
      live.stop();
    });
  });

  test('a stop while the socket is still being opened leaves none open', () {
    fakeAsync((async) {
      final made = _make(async);
      made.live.start();
      made.live.stop();
      async.flushMicrotasks();

      expect(made.live.open, isFalse);
      expect(made.server.current, isNull);
    });
  });
}
