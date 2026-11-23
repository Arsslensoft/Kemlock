import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/fido/bio_enrollment.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/ctap.dart';

import '../../fakes/fake_fido_key.dart';
import 'rig.dart';

Future<BioEnrollment> _open(Rig rig) async =>
    BioEnrollment(rig.session, rig.info.bioEnrollmentCommand!, await rig.token('123456', PinPermission.bioEnrollment));

FakeFidoKey _keyWithReader() => FakeFidoKey(pin: '123456', fingerprintReader: FakeSupport.standard);

void main() {
  testOverEachLink('reads what the reader asks for', (kind) async {
    final rig = await Rig.connect(_keyWithReader(), kind: kind);

    final sensor = await (await _open(rig)).sensor();

    expect(sensor.maxSamples, 4);
    expect(sensor.maxNameBytes, 15);
  });

  testOverEachLink('enrols a fingerprint in four touches and names it', (kind) async {
    final fido = _keyWithReader();
    final rig = await Rig.connect(fido, kind: kind);
    final bio = await _open(rig);
    final touches = <bool>[];
    rig.connection.onTouchNeeded = touches.add;

    var step = await bio.begin();
    final remaining = [step.remaining];
    while (!step.done) {
      expect(step.sample, FingerprintSample.good);
      step = await bio.next(step.templateId);
      remaining.add(step.remaining);
    }
    await bio.rename(step.templateId, 'Right thumb');

    expect(remaining, [3, 2, 1, 0]);
    expect(touches, [true, false, true, false, true, false, true, false], reason: 'the key asks for each touch');
    expect([for (final fingerprint in await bio.list()) fingerprint.name], ['Right thumb']);
    expect(fido.fingerprints.single.id, step.templateId);
  });

  testOverEachLink('does not count a bad touch, and says what was wrong with it', (kind) async {
    final fido = _keyWithReader()..samples.addAll([0, 9, 3, 0]);
    final rig = await Rig.connect(fido, kind: kind);
    final bio = await _open(rig);

    final first = await bio.begin();
    final tooShort = await bio.next(first.templateId);
    final tooLeft = await bio.next(first.templateId);
    final good = await bio.next(first.templateId);

    expect((first.sample, first.remaining), (FingerprintSample.good, 3));
    expect((tooShort.sample, tooShort.remaining), (FingerprintSample.tooShort, 3));
    expect((tooLeft.sample, tooLeft.remaining), (FingerprintSample.tooLeft, 3));
    expect((good.sample, good.remaining), (FingerprintSample.good, 2));
    expect(fido.fingerprints, isEmpty);
  });

  testOverEachLink('cancelling half-way sends the cancel command and leaves the list unchanged', (kind) async {
    final fido = _keyWithReader()..addFingerprint('Left index');
    final rig = await Rig.connect(fido, kind: kind);
    final bio = await _open(rig);
    final step = await bio.next((await bio.begin()).templateId);
    expect(step.remaining, 2);
    final mark = fido.requests.length;

    await bio.cancel();

    expect(rig.requestsSince(mark), ['9.3']);
    expect(fido.enrollmentsCancelled, 1);
    expect([for (final fingerprint in await bio.list()) fingerprint.name], ['Left index']);
    await expectLater(bio.next(step.templateId), throwsA(isA<CtapError>()), reason: 'the unfinished fingerprint is gone');
  });

  testOverEachLink('renames and removes a fingerprint', (kind) async {
    final fido = _keyWithReader();
    final thumb = fido.addFingerprint('Thumb');
    fido.addFingerprint();
    final rig = await Rig.connect(fido, kind: kind);
    final bio = await _open(rig);

    final listed = await bio.list();
    expect([for (final fingerprint in listed) fingerprint.name], ['Thumb', null]);
    await bio.rename(listed[1].id, 'Index');
    await bio.remove(thumb.id);

    expect([for (final fingerprint in await bio.list()) fingerprint.name], ['Index']);
    await bio.remove(listed[1].id);
    expect(await bio.list(), isEmpty, reason: 'a key with none says so with a status, not an empty list');
    await expectLater(bio.remove(thumb.id), throwsA(isA<CtapError>()));
  });

  testOverEachLink('says when the reader is full', (kind) async {
    final fido = _keyWithReader()..maxFingerprints = 2;
    fido
      ..addFingerprint('One')
      ..addFingerprint('Two');
    final rig = await Rig.connect(fido, kind: kind);

    await expectLater(
      (await _open(rig)).begin(),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.fingerprintDatabaseFull)),
    );
  });

  test('says when no touch comes', () async {
    final fido = _keyWithReader()..touches = false;
    final rig = await Rig.connect(fido, kind: SecurityKeyLinkKind.usbHid);

    await expectLater(
      (await _open(rig)).begin(),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.userActionTimeout)),
    );
  });

  test('uses the preview command for a preview-only key', () async {
    final fido = FakeFidoKey.ctap20(pin: '123456', fingerprintReader: FakeSupport.preview)..addFingerprint('Thumb');
    final rig = await Rig.connect(fido, kind: SecurityKeyLinkKind.usbHid);
    expect(rig.info.bioEnrollmentCommand, CtapCommand.bioEnrollmentPreview);
    final mark = fido.requests.length;
    final bio = await _open(rig);

    expect((await bio.list()).single.name, 'Thumb');
    await bio.sensor();
    await bio.cancel();

    expect(rig.requestsSince(mark), ['6.2', '6.5', '40.4', '40.7', '40.3']);
  });

  test('is refused by a key when the token lacks the permission', () async {
    final rig = await Rig.connect(_keyWithReader());
    final wrong = await rig.token('123456', PinPermission.credentialManagement);

    await expectLater(
      BioEnrollment(rig.session, CtapCommand.bioEnrollment, wrong).list(),
      throwsA(isA<CtapError>().having((e) => e.status, 'status', CtapStatus.unauthorizedPermission)),
    );
  });
}
