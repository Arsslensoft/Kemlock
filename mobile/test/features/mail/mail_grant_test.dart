import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_grants.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/features/mail/mail_service.dart';
import 'package:kemlock/features/settings/auto_lock.dart';
import 'package:kemlock/platform/mail_requests.dart';

import '../../fakes/fake_mail_requests.dart';
import 'mail_kit.dart';

const _caller = MailCaller(package: 'net.thunderbird.android', cert: 'aa');

MailCall _resent(String id, {String? from}) => MailCall(requestId: id, resentFrom: from, action: 'x', caller: _caller);

const _done = MailAnswer({'result_code': 1});
const _again = MailAnswer({'result_code': 2});

/// The app and a vault set to lock when hidden, with the mail grants on
/// the same holds, all on the test's fake clock.
class _Phone {
  _Phone(WidgetTester tester) : _tester = tester, _start = tester.binding.clock.now() {
    holds = AutoLockHolds(now: now);
    autoLock = AutoLock(holds: holds, now: now, lock: () => locks++)..update(active: true, minutes: 15, lockOnHide: true);
    grants = MailGrants(
      holds: holds,
      ended: () {
        if (!shown) locks++;
      },
    );
  }

  final WidgetTester _tester;
  final DateTime _start;
  late final AutoLockHolds holds;
  late final AutoLock autoLock;
  late final MailGrants grants;
  var locks = 0;

  /// Whether a screen of Kemlock is in front.
  var shown = true;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1000000).add(_tester.binding.clock.now().difference(_start));

  void hide() {
    shown = false;
    autoLock.lifecycleChanged(AppLifecycleState.hidden);
  }

  void dispose() {
    autoLock.dispose();
    grants.dispose();
  }
}

/// A grant lets an unlocked-for request finish (openspec:
/// add-pgp-mail-provider, task 5.1).
void main() {
  testWidgets('with lock when hidden, hiding during the grant does not lock; answering the request does', (tester) async {
    final phone = _Phone(tester);
    phone.grants.record('r1');
    // The request screen closes: the app goes from the screen
    phone.hide();
    expect(phone.locks, 0);
    await tester.pump(const Duration(seconds: 5));
    expect(phone.locks, 0);

    phone.grants.answered(_resent('r2', from: 'r1'), _done);
    expect(phone.grants.holds('r1'), isFalse);
    expect(phone.locks, 1, reason: 'hidden when the grant ended');
    // testWidgets fails on timers still pending at the end
    phone.dispose();
  });

  testWidgets('a hidden event after the request was answered locks', (tester) async {
    final phone = _Phone(tester);
    phone.grants.record('r1');
    phone.grants.answered(_resent('r2', from: 'r1'), _done);
    expect(phone.locks, 0, reason: 'a screen was in front');
    phone.hide();
    expect(phone.locks, 1);
    phone.dispose();
  });

  testWidgets('a grant never used ends at 60 seconds, and the vault then locks', (tester) async {
    final phone = _Phone(tester);
    phone.grants.record('r1');
    phone.hide();
    await tester.pump(MailGrants.lasts - const Duration(seconds: 1));
    expect(phone.locks, 0);
    expect(phone.holds.isHeld, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(phone.holds.isHeld, isFalse);
    expect(phone.locks, 1);
    phone.dispose();
  });

  testWidgets('the end of a grant is no activity: the vault locks at its idle time all the same', (tester) async {
    final phone = _Phone(tester);
    // A grant each minute, each ended by its request, for sixteen minutes
    for (var minute = 0; minute < 16; minute++) {
      phone.grants.record('r$minute');
      await tester.pump(const Duration(seconds: 30));
      phone.grants.answered(_resent('s$minute', from: 'r$minute'), _done);
      expect(phone.holds.lastReleaseAt, 0);
      await tester.pump(const Duration(seconds: 30));
    }
    expect(phone.locks, 1, reason: 'locked fifteen minutes after the last activity');
    phone.dispose();
  });

  testWidgets("a second request cannot use the first's grant", (tester) async {
    final phone = _Phone(tester);
    phone.grants.record('r1');
    phone.hide();
    phone.grants.answered(_resent('r2'), _done);
    phone.grants.answered(_resent('r3', from: 'r9'), _done);
    expect(phone.grants.holds('r1'), isTrue);
    expect(phone.holds.isHeld, isTrue);
    expect(phone.locks, 0);
    phone.dispose();
  });

  testWidgets('a request sent again that needs the person again keeps the grant for its new screen', (tester) async {
    final phone = _Phone(tester);
    phone.grants.record('r1');
    phone.hide();
    phone.grants.answered(_resent('r2', from: 'r1'), _again);
    expect(phone.grants.holds('r1'), isFalse);
    expect(phone.grants.holds('r2'), isTrue);
    expect(phone.locks, 0);
    // Its screen was cancelled
    phone.grants.end('r2');
    expect(phone.locks, 1);
    phone.dispose();
  });

  test('a request asked first without its input keeps the grant until it comes with it', () async {
    final requests = FakeMailRequests();
    final phone = await MailPhone.open(now: DateTime.utc(2026, 11, 17, 9), overrides: [requests.asOverride]);
    addTearDown(phone.dispose);
    await phone.addKey('ed');
    await phone.container
        .read(mailAppsProvider.notifier)
        .put(MailApp(package: _caller.package, cert: _caller.cert, name: 'Thunderbird', allowedAt: 0, keys: const ['pgp-ed']));
    phone.container.read(mailServiceProvider);
    final grants = phone.container.read(mailGrantsProvider)..record('r1');
    MailCall sign({required bool dry}) => MailCall(
      requestId: 'r2',
      resentFrom: 'r1',
      action: OpenPgp.sign,
      extras: {'api_version': 12, 'sign_key_id': keyIdOf(edFingerprint)},
      caller: _caller,
      input: dry ? null : Uint8List.fromList(utf8.encode('Hello')),
      dry: dry,
    );

    expect((await requests.send(sign(dry: true))).wantsInput, isTrue);
    expect(grants.holds('r1'), isTrue, reason: 'not answered yet');
    expect((await requests.send(sign(dry: false))).resultCode, 1);
    expect(grants.holds('r1'), isFalse);
  });
}
