import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/credential_management.dart';
import 'package:kemlock/security_key/fido/ctap.dart';

import '../../fakes/fake_fido_key.dart';
import 'rig.dart';

Future<CredentialManagement> _open(Rig rig) async =>
    CredentialManagement(rig.session, rig.info.credentialManagementCommand!, await rig.token('123456', PinPermission.credentialManagement));

void main() {
  testOverEachLink('counts the places used and free', (kind) async {
    final fido = FakeFidoKey(pin: '123456');
    for (var i = 0; i < 7; i++) {
      fido.addPasskey('site$i.example', 'ada');
    }
    final rig = await Rig.connect(fido, kind: kind);

    final storage = await (await _open(rig)).metadata();

    expect(storage.used, 7);
    expect(storage.remaining, 93);
    expect(storage.total, 100);
  });

  testOverEachLink('lists nothing on a key with no passkeys', (kind) async {
    final rig = await Rig.connect(FakeFidoKey(pin: '123456'), kind: kind);
    final management = await _open(rig);

    expect(await management.list(), isEmpty);
    expect((await management.metadata()).used, 0);
  });

  testOverEachLink('lists one site with three users', (kind) async {
    final fido = FakeFidoKey(pin: '123456')
      ..addPasskey('example.org', 'ada', rpName: 'Example', displayName: 'Ada Lovelace')
      ..addPasskey('example.org', 'grace')
      ..addPasskey('example.org', 'edsger');
    final rig = await Rig.connect(fido, kind: kind);

    final passkeys = await (await _open(rig)).list();

    expect(
      [for (final passkey in passkeys) '${passkey.rpId} ${passkey.userName}'],
      ['example.org ada', 'example.org grace', 'example.org edsger'],
    );
    expect(passkeys.first.rpName, 'Example');
    expect(passkeys.first.userDisplayName, 'Ada Lovelace');
    expect(passkeys.first.userId, fido.credentials.first.userId);
    expect(passkeys.first.credentialId, {'id': fido.credentials.first.id, 'type': 'public-key'});
    expect(passkeys[1].userDisplayName, isNull);
  });

  testOverEachLink('lists 100 passkeys across 40 sites', (kind) async {
    final fido = FakeFidoKey(pin: '123456');
    for (var i = 0; i < 100; i++) {
      fido.addPasskey('site${i % 40}.example', 'user$i');
    }
    final rig = await Rig.connect(fido, kind: kind);
    final management = await _open(rig);

    final passkeys = await management.list();

    expect(passkeys, hasLength(100));
    expect({for (final passkey in passkeys) passkey.rpId}, hasLength(40));
    expect({for (final passkey in passkeys) passkey.userName}, hasLength(100));
    expect([for (final passkey in passkeys.take(3)) passkey.userName], ['user0', 'user40', 'user80'], reason: 'site by site');
    final storage = await management.metadata();
    expect((storage.used, storage.remaining), (100, 0));
  });

  testOverEachLink('deletes a passkey, after which the key is read again without it', (kind) async {
    final fido = FakeFidoKey(pin: '123456')
      ..addPasskey('github.com', 'adalovelace')
      ..addPasskey('google.com', 'ada@example.org')
      ..addPasskey('github.com', 'grace');
    final rig = await Rig.connect(fido, kind: kind);
    final management = await _open(rig);
    final passkeys = await management.list();

    await management.delete(passkeys.firstWhere((passkey) => passkey.userName == 'adalovelace'));

    expect([for (final credential in fido.credentials) credential.userName], ['ada@example.org', 'grace']);
    expect([for (final passkey in await management.list()) passkey.userName], ['ada@example.org', 'grace']);
    expect((await management.metadata()).used, 2);
    await expectLater(
      management.delete(passkeys.first),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.noCredentials)),
    );
  });

  test('uses the preview command for a preview-only key and the standard one otherwise', () async {
    final preview = await Rig.connect(FakeFidoKey.ctap20(pin: '123456')..addPasskey('example.org', 'ada'));
    expect(preview.info.credentialManagementCommand, CtapCommand.credentialManagementPreview);
    var mark = preview.fido.requests.length;
    final previewManagement = await _open(preview);
    expect((await previewManagement.list()).single.userName, 'ada');
    await previewManagement.metadata();
    expect(preview.requestsSince(mark), ['6.2', '6.5', '41.2', '41.4', '41.1']);

    final standard = await Rig.connect(FakeFidoKey(pin: '123456')..addPasskey('example.org', 'ada'), kind: SecurityKeyLinkKind.usbHid);
    expect(standard.info.credentialManagementCommand, CtapCommand.credentialManagement);
    mark = standard.fido.requests.length;
    expect((await (await _open(standard)).list()).single.userName, 'ada');
    expect(standard.requestsSince(mark), ['6.2', '6.9', 'a.2', 'a.4']);
  });

  testOverEachLink('gives an error and no partial list when the key leaves mid-enumeration', (kind) async {
    final fido = FakeFidoKey(pin: '123456');
    for (var i = 0; i < 6; i++) {
      fido.addPasskey('site$i.example', 'ada');
    }
    final rig = await Rig.connect(fido, kind: kind);
    final management = await _open(rig);
    var enumerated = 0;
    fido.onRequest = (command, parameters) {
      // The fourth site's passkeys are never read.
      if (command == 0x0a && parameters[1] == 4 && ++enumerated == 4) rig.phone.remove(rig.device);
    };

    await expectLater(management.list(), throwsA(isA<SecurityKeyRemoved>()));
    expect(rig.connection.isOpen, isFalse);
  });

  testOverEachLink('refuses a key that names more sites than any key holds, before asking for them', (kind) async {
    final fido = FakeFidoKey(pin: '123456')
      ..addPasskey('example.org', 'ada')
      ..claimedSites = 1 << 30;
    final rig = await Rig.connect(fido, kind: kind);
    final management = await _open(rig);

    await expectLater(management.list(), throwsA(isA<CtapError>()));
    expect(fido.requests.where((request) => request == 'a.3'), isEmpty);
  });

  testOverEachLink('refuses a key that names more passkeys in all than any key holds', (kind) async {
    final fido = FakeFidoKey(pin: '123456')
      ..addPasskey('example.org', 'ada')
      ..addPasskey('example.net', 'grace')
      ..claimedPasskeys = 600;
    final rig = await Rig.connect(fido, kind: kind);
    final management = await _open(rig);

    await expectLater(management.list(), throwsA(isA<CtapError>()));
    // The first site's 600, and none of the second's past its first
    expect(fido.requests.where((request) => request == 'a.5'), hasLength(599));
  });

  test('is refused by a key when the token lacks the permission', () async {
    final rig = await Rig.connect(FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard)..addPasskey('example.org', 'ada'));
    final wrong = await rig.token('123456', PinPermission.bioEnrollment);
    final management = CredentialManagement(rig.session, CtapCommand.credentialManagement, wrong);

    await expectLater(
      management.metadata(),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.unauthorizedPermission)),
    );
    await expectLater(management.list(), throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.unauthorizedPermission)));
  });
}
