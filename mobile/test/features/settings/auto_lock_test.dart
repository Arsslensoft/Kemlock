import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/features/mail/mail_service.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/platform/mail_requests.dart';

import '../../fakes/fake_mail_requests.dart';
import '../mail/mail_kit.dart';

const _minute = Duration(minutes: 1);

/// The vault's clock, from 1,000,000 ms, running with the test's fake time.
/// [skip] moves it on without firing timers, as a phone does for an app in
/// the background.
class _Clock {
  _Clock(this._tester) : _start = _tester.binding.clock.now();

  final WidgetTester _tester;
  final DateTime _start;
  Duration skipped = Duration.zero;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1000000).add(_tester.binding.clock.now().difference(_start) + skipped);

  void skip(Duration duration) => skipped += duration;
}

/// An auto-lock with its holds, counting the times it locked.
class _Harness {
  _Harness(WidgetTester tester) : clock = _Clock(tester) {
    holds = AutoLockHolds(now: clock.now);
    autoLock = AutoLock(holds: holds, now: clock.now, lock: () => locks++, extendSession: extended.add);
  }

  final _Clock clock;
  late final AutoLockHolds holds;
  late final AutoLock autoLock;
  int locks = 0;
  final extended = <Duration>[];

  /// testWidgets fails on timers still pending at the end.
  void dispose() => autoLock.dispose();
}

void main() {
  group('holds', () {
    testWidgets('hold until every hold is released, and only count a release once', (tester) async {
      final holds = AutoLockHolds();
      final first = holds.hold();
      final second = holds.hold();
      first();
      first();
      expect(holds.isHeld, isTrue);
      second();
      expect(holds.isHeld, isFalse);
    });

    testWidgets('record when the last hold ended', (tester) async {
      final holds = AutoLockHolds(now: () => DateTime.fromMillisecondsSinceEpoch(1000000));
      expect(holds.lastReleaseAt, 0);

      holds.hold()();

      expect(holds.lastReleaseAt, 1000000);
    });

    testWidgets('leave the last release where it was when they are no sign of the person', (tester) async {
      var now = 1000000;
      final holds = AutoLockHolds(now: () => DateTime.fromMillisecondsSinceEpoch(now));
      holds.hold()();
      now += 60000;
      final release = holds.hold(resetsIdle: false);
      expect(holds.isHeld, isTrue);
      release();

      expect(holds.isHeld, isFalse);
      expect(holds.lastReleaseAt, 1000000);
    });

    testWidgets('let go by themselves after ten minutes, so a lost release can’t keep the vault open', (tester) async {
      final holds = AutoLockHolds();
      holds.hold();

      await tester.pump(const Duration(minutes: 10) - const Duration(milliseconds: 1));
      expect(holds.isHeld, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(holds.isHeld, isFalse);
    });

    testWidgets('are held while a task runs and released when it settles, even on failure', (tester) async {
      final holds = AutoLockHolds();
      final finish = Completer<void>();

      final task = holds.withHeld(() => finish.future);
      expect(holds.isHeld, isTrue);
      finish.complete();
      await task;
      expect(holds.isHeld, isFalse);

      await expectLater(holds.withHeld<void>(() => Future.error(StateError('no'))), throwsStateError);
      expect(holds.isHeld, isFalse);
    });

    test('are shared by the whole app, on its clock', () {
      final container = ProviderContainer(overrides: [clockProvider.overrideWithValue(() => DateTime.fromMillisecondsSinceEpoch(42))]);
      addTearDown(container.dispose);
      final holds = container.read(autoLockHoldsProvider);

      holds.hold()();

      expect(container.read(autoLockHoldsProvider), same(holds));
      expect(holds.lastReleaseAt, 42);
    });
  });

  group('auto-lock', () {
    testWidgets('locks after the chosen minutes without activity', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 5, lockOnHide: false);

      await tester.pump(_minute * 5 - const Duration(seconds: 5));
      expect(h.locks, 0);
      await tester.pump(const Duration(seconds: 5));
      expect(h.locks, 1);
      h.dispose();
    });

    testWidgets('counts from the last interaction, not from unlocking', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: false);

      await tester.pump(const Duration(seconds: 50));
      h.autoLock.activity();
      await tester.pump(const Duration(seconds: 50));
      expect(h.locks, 0);
      await tester.pump(_minute);
      expect(h.locks, 1);
      h.dispose();
    });

    testWidgets('checks as soon as the app is back, as background timers may not have run', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: false);

      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      h.clock.skip(_minute * 2);
      h.autoLock.lifecycleChanged(AppLifecycleState.resumed);
      expect(h.locks, 1);
      h.dispose();
    });

    testWidgets('locks the moment the app is hidden when asked to', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 60, lockOnHide: true);

      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      expect(h.locks, 1);
      h.dispose();
    });

    testWidgets('stays unlocked while a system picker hides the app', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: true);

      final release = h.holds.hold();
      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      h.autoLock.lifecycleChanged(AppLifecycleState.paused);
      await tester.pump(_minute * 3);
      expect(h.locks, 0);

      // Time spent in the picker doesn't count as idle
      release();
      h.autoLock.lifecycleChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 50));
      expect(h.locks, 0);
      h.dispose();
    });

    testWidgets('locks once a hold ends while the app is still hidden under it', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 60, lockOnHide: true);

      // A share sheet: the app is hidden behind the app it shares to, and the share ends there
      final release = h.holds.hold();
      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      h.autoLock.lifecycleChanged(AppLifecycleState.paused);
      await tester.pump(_minute);
      expect(h.locks, 0);
      release();
      await tester.pump(AutoLock.afterHoldEvery);
      expect(h.locks, 0, reason: 'a look more first');
      await tester.pump(AutoLock.afterHoldEvery);

      expect(h.locks, 1);
      h.dispose();
    });

    testWidgets('locks once a forgotten hold lets go by itself while the app is hidden', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 60, lockOnHide: true);

      h.holds.hold();
      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      await tester.pump(AutoLockHolds.maxHold);
      expect(h.locks, 0);
      await tester.pump(AutoLock.afterHoldEvery * 2);

      expect(h.locks, 1);
      h.dispose();
    });

    testWidgets('does not lock when the app is back as its hold ends, as a picker comes back with its file', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 60, lockOnHide: true);

      final release = h.holds.hold();
      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      h.autoLock.lifecycleChanged(AppLifecycleState.paused);
      await tester.pump(_minute);
      // The picker's answer comes a moment before the lifecycle says the app is back
      release();
      await tester.pump(AutoLock.afterHoldEvery);
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        h.autoLock.lifecycleChanged(state);
      }
      await tester.pump(_minute);

      expect(h.locks, 0);
      h.dispose();
    });

    testWidgets('does nothing while the vault is locked', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: false, minutes: 1, lockOnHide: true);

      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      h.autoLock.activity();
      await tester.pump(_minute * 10);
      expect(h.locks, 0);
      expect(h.extended, isEmpty);
      h.dispose();
    });

    testWidgets('pushes back the expiry of the session kept for restarts', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 15, lockOnHide: false);
      expect(h.extended, [_minute * 15]);

      // Not on every touch: at most every ten seconds
      await tester.pump(const Duration(seconds: 9));
      h.autoLock.activity();
      expect(h.extended, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      h.autoLock.activity();
      expect(h.extended, [_minute * 15, _minute * 15]);
      h.dispose();
    });

    testWidgets('stays put while the app is only inactive, under a system prompt or the app switcher', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 5, lockOnHide: true);

      h.autoLock.lifecycleChanged(AppLifecycleState.inactive);
      expect(h.locks, 0);
      h.autoLock.lifecycleChanged(AppLifecycleState.resumed);
      expect(h.locks, 0);

      for (final hidden in [AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]) {
        h.autoLock.update(active: false, minutes: 5, lockOnHide: true);
        h.autoLock.update(active: true, minutes: 5, lockOnHide: true);
        h.autoLock.lifecycleChanged(hidden);
      }
      expect(h.locks, 3);
      h.dispose();
    });

    testWidgets('locks once, and again only after the vault has been unlocked', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: true);

      h.autoLock.lifecycleChanged(AppLifecycleState.hidden);
      h.autoLock.lifecycleChanged(AppLifecycleState.paused);
      await tester.pump(_minute * 5);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: true);
      h.autoLock.lifecycleChanged(AppLifecycleState.resumed);
      expect(h.locks, 1);

      h.autoLock.update(active: false, minutes: 1, lockOnHide: true);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: true);
      await tester.pump(_minute);
      expect(h.locks, 2);
      h.dispose();
    });

    testWidgets('starts the count over when the timeout changes', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: false);

      await tester.pump(const Duration(seconds: 50));
      h.autoLock.update(active: true, minutes: 5, lockOnHide: false);
      await tester.pump(_minute * 5 - const Duration(seconds: 5));
      expect(h.locks, 0);
      await tester.pump(const Duration(seconds: 5));
      expect(h.locks, 1);
      h.dispose();
    });

    group('on the phone’s elapsed clock', () {
      /// Holds whose wall clock stays at 1,000,000 ms, as if set back as fast as time passes, and
      /// whose phone clock, from 0, runs with the test's fake time and [slept].
      ({AutoLockHolds holds, void Function(Duration) sleep}) phone(WidgetTester tester) {
        final start = tester.binding.clock.now();
        var slept = Duration.zero;
        final holds = AutoLockHolds(
          now: () => DateTime.fromMillisecondsSinceEpoch(1000000),
          elapsed: () async => (tester.binding.clock.now().difference(start) + slept).inMilliseconds,
        );
        return (holds: holds, sleep: (duration) => slept += duration);
      }

      testWidgets('locks after the chosen minutes, though the date is set back', (tester) async {
        final (:holds, sleep: _) = phone(tester);
        var locks = 0;
        final autoLock = AutoLock(holds: holds, lock: () => locks++)..update(active: true, minutes: 1, lockOnHide: false);

        await tester.pump(_minute - const Duration(seconds: 5));
        expect(locks, 0);
        await tester.pump(const Duration(seconds: 5));
        expect(locks, 1);
        autoLock.dispose();
      });

      testWidgets('counts the time the phone slept, though the date is set back', (tester) async {
        final (:holds, :sleep) = phone(tester);
        var locks = 0;
        final autoLock = AutoLock(holds: holds, lock: () => locks++)..update(active: true, minutes: 5, lockOnHide: false);
        await tester.pump();

        autoLock.lifecycleChanged(AppLifecycleState.hidden);
        sleep(_minute * 10);
        autoLock.lifecycleChanged(AppLifecycleState.resumed);
        await tester.pump();

        expect(locks, 1);
        autoLock.dispose();
      });

      testWidgets('a hold released before the sleep counts on the same clock', (tester) async {
        final (:holds, :sleep) = phone(tester);
        var locks = 0;
        final autoLock = AutoLock(holds: holds, lock: () => locks++)..update(active: true, minutes: 5, lockOnHide: false);
        await tester.pump();
        final release = holds.hold();
        await tester.pump(_minute * 3);
        release();

        autoLock.lifecycleChanged(AppLifecycleState.hidden);
        sleep(_minute * 4);
        autoLock.lifecycleChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(locks, 0);

        sleep(_minute);
        autoLock.lifecycleChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(locks, 1);
        autoLock.dispose();
      });
    });

    testWidgets('waits out a hold before counting the idle time', (tester) async {
      final h = _Harness(tester);
      h.autoLock.update(active: true, minutes: 1, lockOnHide: false);

      final release = h.holds.hold();
      await tester.pump(_minute * 3);
      expect(h.locks, 0);
      release();
      await tester.pump(const Duration(seconds: 55));
      expect(h.locks, 0);
      await tester.pump(const Duration(seconds: 5));
      expect(h.locks, 1);
      h.dispose();
    });
  });

  test('offers the timeouts Settings lists', () {
    expect(autoLockMinuteOptions, [1, 5, 15, 60]);
    expect(AutoLockHolds.maxHold, const Duration(minutes: 10));
  });
  // openspec: add-pgp-mail-provider, task 5.2
  testWidgets("a mail app's requests are not activity: one each minute, and the vault locks at its idle time", (tester) async {
    final requests = FakeMailRequests();
    final phone = (await tester.runAsync(() => MailPhone.open(overrides: [requests.asOverride])))!;
    addTearDown(phone.dispose);
    await tester.runAsync(() async {
      await phone.addKey('ed');
      await phone.container
          .read(mailAppsProvider.notifier)
          .put(const MailApp(package: 'net.thunderbird.android', cert: 'aa', name: 'Thunderbird', allowedAt: 0, keys: ['pgp-ed']));
    });
    phone.container.read(mailServiceProvider);
    final clock = _Clock(tester);
    final autoLock = AutoLock(holds: phone.container.read(autoLockHoldsProvider), now: clock.now, lock: phone.lock)
      ..update(active: true, minutes: 5, lockOnHide: false);
    final encrypted = await tester.runAsync(
      () => pgp.encrypt(data: pgp.PgpData.bytes(Uint8List.fromList([1, 2, 3])), recipients: [gnupgKey('ed25519.public')], text: false),
    );

    var answered = 0;
    for (var minute = 1; minute <= 6 && phone.state.isUnlocked; minute++) {
      final answer = await tester.runAsync(
        () => requests.send(
          MailCall(
            requestId: 'r$minute',
            action: OpenPgp.decryptVerify,
            extras: const {'api_version': 12},
            caller: const MailCaller(package: 'net.thunderbird.android', cert: 'aa'),
            input: encrypted,
          ),
        ),
      );
      if (answer!.resultCode == 1) answered++;
      await tester.pump(_minute);
    }
    expect(answered, 5, reason: 'each request is answered while the vault is open');
    expect(phone.state.isUnlocked, isFalse, reason: 'locked at five minutes');
    autoLock.dispose();
  });
}
