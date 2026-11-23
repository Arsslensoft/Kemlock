import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/vault/vault_registry.dart';

import 'mail_kit.dart';

const _thunderbird = MailApp(
  package: 'net.thunderbird.android',
  cert: 'aa11',
  name: 'Thunderbird',
  allowedAt: 1794000000000,
  keys: ['pgp-ed'],
);

const _fairEmail = MailApp(package: 'eu.faircode.email', cert: 'bb22', name: 'FairEmail', allowedAt: 1794100000000);

/// The approved mail apps, one sealed value per vault (openspec:
/// add-pgp-mail-provider, task 3.1).
void main() {
  late MailPhone phone;

  setUp(() async {
    phone = await MailPhone.open();
    addTearDown(phone.dispose);
  });

  MailApps apps() => phone.container.read(mailAppsProvider.notifier);

  test('a vault that never approved an app holds no such value', () async {
    expect(await apps().current(), isEmpty);
    expect(phone.store.getItem(keyMailApps), isNull);
  });

  test('approving writes a sealed value, and it reads back', () async {
    await apps().put(_thunderbird);
    final raw = jsonDecode(phone.store.getItem(keyMailApps)!) as Map<String, Object?>;
    expect(raw.keys.toSet(), {'kemCT', 'nonce', 'ct'});
    expect(utf8.decode(base64.decode(raw['ct']! as String), allowMalformed: true), isNot(contains('thunderbird')));

    phone.lock();
    await phone.unlock('pw');
    expect(await apps().current(), [_thunderbird]);
    expect(phone.container.read(mailAppsProvider), [_thunderbird]);
  });

  test('is empty while locked', () async {
    await apps().put(_thunderbird);
    phone.lock();
    expect(phone.container.read(mailAppsProvider), isEmpty);
    expect(await apps().current(), isEmpty);
  });

  test('removing the last app deletes the value', () async {
    await apps().put(_thunderbird);
    await apps().put(_fairEmail);
    await apps().remove(_thunderbird.package);
    expect(phone.store.getItem(keyMailApps), isNotNull);
    expect(await apps().current(), [_fairEmail]);
    await apps().remove(_fairEmail.package);
    expect(phone.store.getItem(keyMailApps), isNull);
  });

  test('approving an app again replaces its approval', () async {
    await apps().put(_thunderbird);
    await apps().put(_thunderbird.copyWith(keys: ['pgp-ed', 'pgp-rsa']));
    expect((await apps().current()).single.keys, ['pgp-ed', 'pgp-rsa']);
  });

  test('keeps fields a newer version wrote through a read and a write', () async {
    final session = phone.state.session!;
    await phone.vaultStore.saveEncryptedValue(keyMailApps, [
      {
        ..._thunderbird.toJson(),
        'later': {'x': 1},
      },
    ], session);
    phone.lock();
    await phone.unlock('pw');
    final read = (await apps().current()).single;
    expect(read.extra, {
      'later': {'x': 1},
    });
    await apps().put(read.copyWith(unchecked: ['ABCD']));
    final stored = await phone.vaultStore.loadEncryptedValue(keyMailApps, phone.state.session!);
    expect((stored! as List).single, {
      ..._thunderbird.copyWith(unchecked: ['ABCD']).toJson(),
      'later': {'x': 1},
    });
  });

  test('two vaults keep separate lists', () async {
    await apps().put(_thunderbird);
    final hidden = await phone.addHiddenVault('hidden pw');
    phone.lock();
    await phone.unlock('hidden pw');
    expect(phone.state.vault.hidden, isTrue);
    expect(await apps().current(), isEmpty);
    await apps().put(_fairEmail);
    expect(phone.store.getItem('$keyMailApps::$hidden'), isNotNull);

    phone.lock();
    await phone.unlock('pw');
    expect(phone.vaults.active, mainVault);
    expect(await apps().current(), [_thunderbird]);
  });
}
