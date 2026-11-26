// Putting an account on a key: move, copy and add, with the fake key
// (openspec: add-security-key-codes, task 6.1).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/security_keys/key_account_transfer.dart';
import 'package:kemlock/features/security_keys/key_codes.dart';
import 'package:kemlock/models/custom_field.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../fakes/fake_oath_key.dart';
import 'key_codes_harness.dart';

const _put = 0x01;

/// A key that is taken away as soon as it has answered a PUT.
class _LeavesAfterPut extends FakeOathKey {
  _LeavesAfterPut() : super(accounts: usualAccounts());

  void Function()? leave;

  @override
  (List<int>, int) command(int cla, int ins, int p1, int p2, Uint8List data) {
    final answer = super.command(cla, ins, p1, p2, data);
    if (ins == _put) leave?.call();
    return answer;
  }
}

Future<CodesRig> _rig({FakeOathKey? oath, List<OtpAccount> accounts = const []}) async {
  final rig = await CodesRig.open(oath: oath ?? FakeOathKey(accounts: usualAccounts()));
  for (final account in accounts) {
    await rig.vault.addAccount(account);
  }
  rig.present();
  return rig;
}

Future<KeyCodesResult> _put0(CodesRig rig, OtpAccount account, KeyTransfer mode, {bool replace = false, bool touch = false}) =>
    putOnKey(rig.codes, rig.vault, account, mode: mode, nowSec: () => rig.nowSec, replace: replace, touch: touch);

/// The vault's own copy of the account [issuer], once added.
OtpAccount _held(CodesRig rig, String issuer) => rig.vaultState.accounts.singleWhere((account) => account.issuer == issuer);

void main() {
  final totp = rfcVaultAccount(issuer: 'Forge', label: 'ada', tags: ['work'], note: 'Recovery codes in the safe');
  final hotp = rfcVaultAccount(issuer: 'Bank', label: 'ada', type: OtpType.hotp, counter: 3);

  test('a time-based and a counter-based account move, and the key then gives their codes', () async {
    final rig = await _rig(accounts: [totp, hotp]);

    expect((await _put0(rig, _held(rig, 'Forge'), KeyTransfer.move)).outcome, KeyCodesOutcome.done);
    expect((await _put0(rig, _held(rig, 'Bank'), KeyTransfer.move)).outcome, KeyCodesOutcome.done);

    expect(rig.vaultState.accounts, isEmpty);
    expect(rig.oath.find('Forge:ada')!.secret, rfcSecret);
    expect(rig.oath.find('Bank:ada')!.counter, 4, reason: 'counter 3, moved on by the check');
    expect((await rig.codes.read()).outcome, KeyCodesOutcome.done);
    expect(rig.showing('Forge:ada'), codeAt(totp, rig.nowSec));
    expect(rig.remembered('Bank:ada').type.name, 'hotp');
  });

  test('tags and the note arrive on the new entry, and the key’s other accounts are remembered', () async {
    final rig = await _rig(accounts: [totp]);

    await _put0(rig, _held(rig, 'Forge'), KeyTransfer.move);

    final entry = rig.remembered('Forge:ada');
    expect(entry.tags, ['work']);
    expect(entry.note, 'Recovery codes in the safe');
    expect(rig.vaultState.keyAccounts, hasLength(5));
  });

  test('the custom fields arrive on the new entry', () async {
    const field = CustomField(name: 'Seed owner', value: 'ada', kind: CustomFieldKind.text);
    final rig = await _rig(accounts: [totp.copyWith(fields: const [field])]);

    await _put0(rig, _held(rig, 'Forge'), KeyTransfer.move);

    expect(rig.remembered('Forge:ada').fields, [field]);
  });

  test('a copy keeps the account in the vault too', () async {
    final rig = await _rig(accounts: [totp]);

    expect((await _put0(rig, _held(rig, 'Forge'), KeyTransfer.copy)).outcome, KeyCodesOutcome.done);

    expect(rig.vaultState.accounts.single.issuer, 'Forge');
    expect(rig.oath.find('Forge:ada'), isNotNull);
    expect(rig.remembered('Forge:ada').tags, ['work']);
  });

  test('a key that stores a wrong secret gives a mismatch: the entry is taken off it and the vault keeps the account', () async {
    final rig = await _rig(
      oath: FakeOathKey(accounts: usualAccounts())..corruptPuts = true,
      accounts: [totp],
    );

    final result = await _put0(rig, _held(rig, 'Forge'), KeyTransfer.move);

    expect(result.outcome, KeyCodesOutcome.mismatch);
    expect(rig.oath.find('Forge:ada'), isNull);
    expect(rig.vaultState.accounts.single.issuer, 'Forge');
    expect(rig.vaultState.keyAccounts, isEmpty);
  });

  test('a key taken away after the write leaves the account in the vault', () async {
    final oath = _LeavesAfterPut();
    final rig = await CodesRig.open(oath: oath);
    await rig.vault.addAccount(totp);
    final device = rig.present();
    oath.leave = () => rig.phone.remove(device);

    final result = await _put0(rig, _held(rig, 'Forge'), KeyTransfer.move);

    expect(result.outcome, anyOf(KeyCodesOutcome.unchecked, KeyCodesOutcome.interrupted));
    expect(rig.vaultState.accounts.single.issuer, 'Forge');
    expect(rig.vaultState.keyAccounts, isEmpty);
  });

  group('refused before anything is written', () {
    Future<void> expectRefused(OtpAccount account, KeyRefusal why, {FakeOathKey? oath}) async {
      final rig = await _rig(oath: oath, accounts: [account]);

      final result = await _put0(rig, rig.vaultState.accounts.single, KeyTransfer.move);

      expect((result.outcome, result.refusal), (KeyCodesOutcome.refused, why));
      expect(rig.oath.received, isNot(contains(_put)));
      expect(rig.vaultState.accounts, hasLength(1));
    }

    test('a Steam Guard account', () => expectRefused(rfcVaultAccount(issuer: 'Steam', type: OtpType.steam), KeyRefusal.steam));

    test('a shared space’s account', () => expectRefused(rfcVaultAccount(spaceId: 'fam'), KeyRefusal.space));

    test('a name of 65 bytes', () async {
      // "Forge:" and 59 more bytes.
      final long = rfcVaultAccount(issuer: 'Forge', label: 'a' * 59);
      expect(keyNameOf(long).length, 65);
      final rig = await _rig(accounts: [long]);

      final result = await _put0(rig, rig.vaultState.accounts.single, KeyTransfer.move);

      expect((result.outcome, result.refusal, result.nameBytes), (KeyCodesOutcome.refused, KeyRefusal.name, 65));
      expect(rig.oath.received, isEmpty);
    });

    test('SHA-512 on firmware 4.2', () async {
      await expectRefused(
        rfcVaultAccount(algorithm: 'SHA512'),
        KeyRefusal.algorithm,
        oath: FakeOathKey(accounts: usualAccounts(), version: const [4, 2, 6]),
      );
    });
  });

  test('a name the key already holds is asked about before it is replaced', () async {
    final rig = await _rig(accounts: [rfcVaultAccount(label: 'alice@example.org')]);
    final account = rig.vaultState.accounts.single;
    expect(keyNameOf(account), 'Example:alice@example.org');

    final asked = await _put0(rig, account, KeyTransfer.copy);

    expect(asked.outcome, KeyCodesOutcome.exists);
    expect(rig.oath.received, isNot(contains(_put)));
    expect((await _put0(rig, account, KeyTransfer.copy, replace: true)).outcome, KeyCodesOutcome.done);
    expect(rig.oath.accounts.where((entry) => entry.name == 'Example:alice@example.org'), hasLength(1));
  });

  test('a full key says so, with what a key of its firmware holds, and changes nothing', () async {
    final rig = await _rig(
      oath: FakeOathKey(accounts: usualAccounts(), capacity: 4),
      accounts: [totp],
    );

    final result = await _put0(rig, _held(rig, 'Forge'), KeyTransfer.move);

    expect((result.outcome, result.capacity), (KeyCodesOutcome.full, 32));
    expect(rig.vaultState.accounts, hasLength(1));
    expect(rig.oath.accounts, hasLength(4));
  });
}
