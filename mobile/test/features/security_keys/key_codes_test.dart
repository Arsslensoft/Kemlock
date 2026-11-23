import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/models/key_account.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/platform/security_keys.dart';

import '../../fakes/fake_oath_key.dart';
import '../../fakes/fake_security_keys.dart';
import 'key_codes_harness.dart';

const _list = 0xa1;
const _calculate = 0xa2;
// SELECT has the same instruction byte, with P1 04: a CALCULATE ALL is told by its P1 00.
const _calculateAll = 0xa4;
const _alice = 'Example:alice@example.org';
const _slow = '60/Slow:bob';
const _touch = 'Registrar:root';
const _counter = 'Example:counter';

/// How many commands of [ins] the application got.
int _count(FakeOathKey oath, int ins) => oath.received.where((received) => received == ins).length;

void main() {
  // Task 4.1
  group('reading a key', () {
    test('brings the code of the current period and of the next, the ones codeAt gives', () async {
      final rig = await CodesRig.open();
      rig.present();

      final result = await rig.codes.read();

      expect(result.outcome, KeyCodesOutcome.done);
      expect(result.device, '0102030405060708');
      final now = rig.nowSec;
      final codes = rig.state.codes[rig.remembered(_alice).id]!;
      expect([for (final code in codes) code.code], [codeAt(rfcVaultAccount(), now), codeAt(rfcVaultAccount(), now, 1)]);
      expect([for (final code in codes) (code.from, code.until)], [(now - 10, now + 20), (now + 20, now + 50)]);
      expect(rig.state.readAt, now);
      expect(_count(rig.oath, _list), 1);
      expect(_count(rig.oath, _calculateAll), 2);
    });

    test('an account with a 60-second period gets its own two steps', () async {
      final rig = await CodesRig.open();
      rig.present();

      await rig.codes.read();

      final slow = rfcVaultAccount(algorithm: 'SHA256', digits: 8, period: 60);
      final now = rig.nowSec;
      final codes = rig.state.codes[rig.remembered(_slow).id]!;
      expect([for (final code in codes) code.code], [codeAt(slow, now), codeAt(slow, now, 1)]);
      expect([for (final code in codes) (code.from, code.until)], [(now - 10, now + 50), (now + 50, now + 110)]);
      expect(_count(rig.oath, _calculate), 2, reason: 'two CALCULATEs for the one account with another period');
      expect(rig.remembered(_slow).period, 60);
      expect(rig.remembered(_slow).algorithm, 'SHA256');
    });

    test('a touch account and a counter account get no code, and the vault remembers which they are', () async {
      final rig = await CodesRig.open();
      rig.present();

      await rig.codes.read();

      expect(rig.state.codes.containsKey(rig.remembered(_touch).id), isFalse);
      expect(rig.state.codes.containsKey(rig.remembered(_counter).id), isFalse);
      expect(rig.state.counterCodes, isEmpty);
      expect(rig.remembered(_touch).touch, isTrue);
      expect(rig.remembered(_alice).touch, isFalse);
      expect(rig.remembered(_counter).type, KeyAccountType.hotp);
      expect(rig.oath.find(_counter)!.counter, 0, reason: 'a read never moves a counter');
    });

    test('a code shows while its period lasts, then the next, then none', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      final first = codeAt(rfcVaultAccount(), rig.nowSec);
      final second = codeAt(rfcVaultAccount(), rig.nowSec, 1);

      expect(rig.showing(_alice), first);
      rig.phone.elapse(const Duration(seconds: 19));
      expect(rig.showing(_alice), first);
      rig.phone.elapse(const Duration(seconds: 1));
      expect(rig.showing(_alice), second, reason: 'the period turned: the next code, read at the same time');
      rig.phone.elapse(const Duration(seconds: 29));
      expect(rig.showing(_alice), second);
      rig.phone.elapse(const Duration(seconds: 1));
      expect(rig.showing(_alice), isNull, reason: 'both periods have passed');
      expect(rig.remembered(_alice).name, _alice, reason: 'the row keeps its name');
    });

    test('a connection lost after LIST and before the codes remembers the names and shows no codes', () async {
      final rig = await CodesRig.open();
      rig.present();
      rig.phone.removeWhen = (frame) => frame[1] == _calculateAll && frame[2] == 0;

      final result = await rig.codes.read();

      expect(result.outcome, KeyCodesOutcome.interrupted);
      expect(result.partial, isTrue);
      expect([for (final account in rig.vaultState.keyAccounts) account.name], [_alice, _slow, _touch, _counter]);
      expect(rig.state.codes, isEmpty);
      expect(rig.state.readAt, isNull);
    });

    test('a connection lost between the two CALCULATE ALLs shows no half-read codes', () async {
      final rig = await CodesRig.open();
      rig.present();
      var seen = 0;
      rig.phone.removeWhen = (frame) => frame[1] == _calculateAll && frame[2] == 0 && ++seen == 2;

      final result = await rig.codes.read();

      expect(result.partial, isTrue);
      expect(rig.state.codes, isEmpty);
      expect(rig.vaultState.keyAccounts, hasLength(4));
    });

    test('a connection lost during LIST changes nothing', () async {
      final rig = await CodesRig.open(
        oath: FakeOathKey(
          version: [5, 7, 0],
          accounts: [for (var i = 0; i < 40; i++) FakeOathAccount('Example:account-$i@example.org', rfcSecret)],
        ),
      );
      // What an earlier read left.
      await rig.vault.reconcileKey('0102030405060708', 'YubiKey 5C NFC', const [
        KeyAccountSeen(name: 'Old:one', type: KeyAccountType.totp),
      ]);
      final before = rig.vaultState.keyAccounts;
      rig.present();
      rig.phone.removeWhen = (frame) => frame[1] == 0xa5;

      final result = await rig.codes.read();

      expect(result.outcome, KeyCodesOutcome.interrupted);
      expect(result.partial, isFalse);
      expect(rig.vaultState.keyAccounts, before);
      expect(rig.state.codes, isEmpty);
    });

    test('a second read brings the list in line with the key and keeps tags', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      final alice = rig.remembered(_alice);
      await rig.vault.updateKeyAccount(alice.copyWith(tags: ['work']));
      rig.oath.accounts.removeWhere((account) => account.name == _slow);
      rig.oath.accounts.add(FakeOathAccount('New:carol', rfcSecret));

      await rig.codes.read();

      expect([for (final account in rig.vaultState.keyAccounts) account.name], [_alice, _touch, _counter, 'New:carol']);
      expect(rig.remembered(_alice).id, alice.id);
      expect(rig.remembered(_alice).tags, ['work']);
      expect(rig.state.codes.keys, containsAll([alice.id, rig.remembered('New:carol').id]));
    });

    test('a second key has its own entries, and the first key’s are unchanged', () async {
      final rig = await CodesRig.open();
      final first = rig.present();
      await rig.codes.read();
      final before = rig.vaultState.keyAccounts;
      rig.phone.remove(first);
      final spare = FakeOathKey(id: [9, 9, 9, 9, 9, 9, 9, 9], accounts: [FakeOathAccount('Spare:dave', rfcSecret)]);
      rig.phone.arrive(FakeKey(applets: [spare]).device(kinds: nfcKey));

      await rig.codes.read();

      expect(rig.vaultState.keyAccounts.sublist(0, 4), before);
      expect(rig.vaultState.keyAccounts.last.device, '0909090909090909');
      expect(rig.state.codes.keys, containsAll([rig.remembered(_alice).id, rig.remembered('Spare:dave').id]));
    });

    test('names Yubico’s apps hide are skipped', () async {
      final rig = await CodesRig.open(
        oath: FakeOathKey(accounts: [FakeOathAccount(_alice, rfcSecret), FakeOathAccount('_hidden:Example:secret', rfcSecret)]),
      );
      rig.present();

      await rig.codes.read();

      expect([for (final account in rig.vaultState.keyAccounts) account.name], [_alice]);
      expect(rig.state.codes, hasLength(1));
    });

    test('locking the vault empties the provider', () async {
      final rig = await CodesRig.open();
      rig.present(kinds: usbKey);
      await rig.codes.read();
      await rig.codes.calculate(rig.remembered(_counter));
      expect(rig.state.codes, isNotEmpty);
      expect(rig.state.counterCodes, isNotEmpty);
      expect(rig.state.plugged, isNotNull);

      rig.vault.lock();

      expect(rig.state.codes, isEmpty);
      expect(rig.state.counterCodes, isEmpty);
      expect(rig.state.readAt, isNull);
      expect(rig.state.plugged, isNull);
    });

    test('nothing stored holds a secret or a code of the key’s accounts', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      final shown = {
        for (final codes in rig.state.codes.values)
          for (final code in codes) code.code,
      };
      expect(shown, hasLength(4));

      final stored = await rig.vaultStore.loadEncryptedValue('backmycodes_key_account_data', rig.session);
      final text = jsonEncode(stored);
      expect(text, contains(_alice));
      for (final code in shown) {
        expect(text, isNot(contains(code)));
      }
      expect(text, isNot(contains(rfcSecretBase32)));
      for (final entry in stored! as List<Object?>) {
        expect((entry! as Map<String, Object?>).keys, isNot(anyOf(contains('secret'), contains('code'), contains('digits'))));
      }
      // And nothing else the phone stores names the key's accounts, sealed or not.
      for (final key in rig.store.storedKeys()) {
        expect(rig.store.getItem(key), isNot(contains('alice@example.org')), reason: key);
      }
    });

    test('a key without the application, or with another one under its name, is not read', () async {
      final none = await CodesRig.open(applets: const []);
      none.present();
      expect((await none.codes.read()).outcome, KeyCodesOutcome.unsupported);
      expect(none.vaultState.keyAccounts, isEmpty);

      final other = await CodesRig.open(applets: [_Impostor()]);
      other.present();
      expect((await other.codes.read()).outcome, KeyCodesOutcome.unsupported);
      expect(other.vaultState.keyAccounts, isEmpty);
    });

    test('an application the iPhone was not told of is said to be unsupported', () async {
      final rig = await CodesRig.open(capabilities: FakeSecurityKeys.iphone);
      rig.phone.declaredAids = {'a0000006472f0001'};
      rig.present();

      expect((await rig.codes.read()).outcome, KeyCodesOutcome.unsupported);
    });

    test('on an iPhone the read happens under the system’s sheet, which then closes', () async {
      final rig = await CodesRig.open(capabilities: FakeSecurityKeys.iphone);
      rig.present();

      final result = await rig.codes.read();

      expect(result.outcome, KeyCodesOutcome.done);
      expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), hasLength(1));
      expect(rig.phone.calls.last, 'stopWatch');
      expect(rig.phone.calls, contains('endNfc'));
      expect(rig.phone.nfcSheetUp, isFalse);
      expect(rig.state.plugged, isNull);
      expect(rig.state.activity, KeyCodesActivity.idle);
    });

    test('closing the iPhone’s sheet is a cancellation, with nothing changed', () async {
      final rig = await CodesRig.open(capabilities: FakeSecurityKeys.iphone);
      rig.phone.cancelNextNfcSheet = true;

      final result = await rig.codes.read();

      expect(result.outcome, KeyCodesOutcome.cancelled);
      expect(rig.vaultState.keyAccounts, isEmpty);
    });

    test('waits for a key to be presented, and can be told to stop waiting', () async {
      final rig = await CodesRig.open();

      final reading = rig.codes.read();
      await pumpEventQueue();
      expect(rig.state.activity, KeyCodesActivity.waiting);
      await rig.codes.cancel();

      expect((await reading).outcome, KeyCodesOutcome.cancelled);
      expect(rig.state.activity, KeyCodesActivity.idle);
    });

    test('a phone that can reach no key says so', () async {
      final rig = await CodesRig.open(capabilities: SecurityKeyCapabilities.none);

      expect((await rig.codes.read()).outcome, KeyCodesOutcome.unavailable);
    });

    test('a key with a password is not listed before the password is proved', () async {
      final rig = await CodesRig.open(
        oath: FakeOathKey(password: 'correct horse', accounts: usualAccounts()),
      );
      rig.present();

      final first = await rig.codes.read();

      expect(first.outcome, KeyCodesOutcome.passwordNeeded);
      expect(first.device, '0102030405060708');
      expect(rig.oath.received, isEmpty, reason: 'nothing but the selection was sent');
      expect(rig.vaultState.keyAccounts, isEmpty);

      final wrong = await rig.codes.read(accessKey: keyAccessFor('battery staple', first.device!));
      expect(wrong.outcome, KeyCodesOutcome.wrongPassword);
      expect(_count(rig.oath, _list), 0);

      final right = await rig.codes.read(accessKey: keyAccessFor('correct horse', first.device!));
      expect(right.outcome, KeyCodesOutcome.done);
      expect(rig.vaultState.keyAccounts, hasLength(4));
    });

    test('a key that fails its own proof is not trusted, and nothing is listed', () async {
      final rig = await CodesRig.open(
        oath: FakeOathKey(password: 'correct horse', accounts: usualAccounts())..wrongProof = true,
      );
      rig.present();

      final result = await rig.codes.read(accessKey: keyAccessFor('correct horse', '0102030405060708'));

      expect(result.outcome, KeyCodesOutcome.untrustedKey);
      expect(_count(rig.oath, _list), 0);
      expect(rig.vaultState.keyAccounts, isEmpty);
    });
  });

  // Task 4.2
  group('a key that stays plugged in', () {
    test('is read again as the second period begins, while the tab listens, and not after', () async {
      final rig = await CodesRig.open();
      rig.present(kinds: usbKey);
      await rig.codes.read();
      expect(rig.state.plugged, '0102030405060708');
      expect(_count(rig.oath, _list), 1);

      fakeAsync((async) {
        void pass(int seconds) {
          rig.phone.elapse(Duration(seconds: seconds));
          async.elapse(Duration(seconds: seconds));
          async.flushMicrotasks();
        }

        rig.codes.listening(true);
        pass(19);
        expect(_count(rig.oath, _list), 1, reason: 'the first period is not over');
        pass(1);
        expect(_count(rig.oath, _list), 2, reason: 'the second period began');
        expect(rig.showing(_alice), codeAt(rfcVaultAccount(), rig.nowSec));
        expect(rig.state.nextAfter(rig.remembered(_alice).id, rig.nowSec), isNotNull);

        // Two minutes on, a valid code throughout.
        for (var i = 0; i < 120; i++) {
          pass(1);
          expect(rig.showing(_alice), codeAt(rfcVaultAccount(), rig.nowSec), reason: 'at ${rig.nowSec}');
        }
        expect(_count(rig.oath, _list), 6);

        rig.codes.listening(false);
        final reads = _count(rig.oath, _list);
        pass(90);
        expect(_count(rig.oath, _list), reads, reason: 'the tab is not on screen');
        expect(rig.showing(_alice), isNull);
      });
    });

    test('goes stale once it is unplugged, with the codes already read showing until they run out', () async {
      final rig = await CodesRig.open();
      final device = rig.present(kinds: usbKey);
      await rig.codes.read();

      fakeAsync((async) {
        void pass(int seconds) {
          rig.phone.elapse(Duration(seconds: seconds));
          async.elapse(Duration(seconds: seconds));
          async.flushMicrotasks();
        }

        rig.codes.listening(true);
        rig.phone.remove(device);
        pass(20);
        expect(_count(rig.oath, _list), 1);
        expect(rig.state.plugged, isNull);
        expect(rig.showing(_alice), codeAt(rfcVaultAccount(), rig.nowSec));
        pass(30);
        expect(rig.showing(_alice), isNull);
        expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), isEmpty);
        rig.codes.listening(false);
      });
    });

    test('an NFC connection never repeats', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      expect(rig.state.plugged, isNull);

      fakeAsync((async) {
        rig.codes.listening(true);
        rig.phone.elapse(const Duration(seconds: 120));
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(_count(rig.oath, _list), 1);
        expect(async.pendingTimers, isEmpty);
        rig.codes.listening(false);
      });
    });

    test('a key in the iPhone’s USB-C port is read with no NFC sheet, and again by itself', () async {
      final rig = await CodesRig.open(capabilities: FakeSecurityKeys.iphone);
      rig.present(kinds: smartcardKey);

      expect((await rig.codes.read()).outcome, KeyCodesOutcome.done);

      expect(rig.phone.calls.where((call) => call.startsWith('beginNfc')), isEmpty);
      expect(rig.state.plugged, isNotNull);
    });
  });

  // Task 4.3
  group('one account asked on its own', () {
    test('a touch account is asked with one CALCULATE, and shows that one code', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      rig.oath.received.clear();

      final result = await rig.codes.calculate(rig.remembered(_touch));

      expect(result.outcome, KeyCodesOutcome.done);
      expect(result.code, codeAt(rfcVaultAccount(), rig.nowSec));
      expect(rig.oath.received, [_calculate]);
      expect(rig.showing(_touch), result.code);
      rig.phone.elapse(const Duration(seconds: 20));
      expect(rig.showing(_touch), isNull, reason: 'its period ended');
    });

    test('a touch that never comes leaves the row as it was', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      rig.oath.touchGiven = false;
      final before = rig.state.codes;

      final result = await rig.codes.calculate(rig.remembered(_touch));

      expect(result.outcome, KeyCodesOutcome.notTouched);
      expect(rig.state.codes, before);
      expect(rig.showing(_touch), isNull);
    });

    test('a link that gives up waiting for the touch is a touch that did not come', () async {
      final rig = await CodesRig.open();
      final device = rig.present();
      await rig.codes.read();
      device.silent = true;

      final result = await rig.codes.calculate(rig.remembered(_touch));

      expect(result.outcome, KeyCodesOutcome.notTouched);
    });

    test('each request for a counter code moves the key’s counter by exactly one', () async {
      final rig = await CodesRig.open();
      rig.present();
      await rig.codes.read();
      final account = rig.remembered(_counter);
      final vault = rfcVaultAccount(type: OtpType.hotp, counter: 0);
      rig.oath.received.clear();

      final first = await rig.codes.calculate(account);
      expect(rig.oath.received, [_calculate]);
      expect(rig.oath.find(_counter)!.counter, 1);
      expect(first.code, codeAt(vault, 0));
      expect(rig.state.counterCodes[account.id], first.code);

      final second = await rig.codes.calculate(account);
      expect(rig.oath.find(_counter)!.counter, 2);
      expect(second.code, codeAt(vault, 0, 1));
      expect(rig.state.counterCodes[account.id], second.code);

      // It shows until the tab is left.
      rig.codes.listening(true);
      rig.phone.elapse(const Duration(minutes: 5));
      expect(rig.state.counterCodes[account.id], second.code);
      rig.codes.listening(false);
      expect(rig.state.counterCodes, isEmpty);
    });

    test('a key other than the account’s is not asked', () async {
      final rig = await CodesRig.open();
      final first = rig.present();
      await rig.codes.read();
      rig.phone.remove(first);
      final spare = FakeOathKey(id: [9, 9, 9, 9, 9, 9, 9, 9], accounts: [FakeOathAccount(_counter, rfcSecret, hotp: true)]);
      rig.phone.arrive(FakeKey(applets: [spare]).device(kinds: nfcKey));

      final result = await rig.codes.calculate(rig.remembered(_counter));

      expect(result.outcome, KeyCodesOutcome.otherKey);
      expect(spare.received, isEmpty);
      expect(spare.find(_counter)!.counter, 0);
    });
  });
}

/// An application under the same identifier that is not Yubico's.
class _Impostor extends FakeOathKey {
  @override
  List<int> get selectAnswer => ascii.encode('SECRETS');
}
