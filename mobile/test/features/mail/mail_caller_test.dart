import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/mail/mail_caller.dart';

const _cert = '9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b';
const _apps = [MailApp(package: 'net.thunderbird.android', cert: _cert, name: 'Thunderbird', allowedAt: 1)];

/// Whether the asking app is the one approved (openspec:
/// add-pgp-mail-provider, task 3.3).
void main() {
  test('the approved package with its certificate is approved', () {
    expect(judgeCaller(const MailCaller(package: 'net.thunderbird.android', cert: _cert), _apps), MailCallerStanding.approved);
    expect(approvalOf(const MailCaller(package: 'net.thunderbird.android', cert: _cert), _apps), _apps.single);
  });

  test('the digests are compared without regard to case', () {
    final upper = MailCaller(package: 'net.thunderbird.android', cert: _cert.toUpperCase());
    expect(judgeCaller(upper, _apps), MailCallerStanding.approved);
  });

  test('a package never approved is unknown', () {
    expect(judgeCaller(const MailCaller(package: 'eu.faircode.email', cert: _cert), _apps), MailCallerStanding.unknown);
    expect(judgeCaller(const MailCaller(package: 'net.thunderbird.android', cert: _cert), const []), MailCallerStanding.unknown);
  });

  test('an approved package under another certificate is told apart', () {
    const other = MailCaller(package: 'net.thunderbird.android', cert: 'ff00');
    expect(judgeCaller(other, _apps), MailCallerStanding.otherCertificate);
    expect(approvalOf(other, _apps), isNull);
  });

  test('a caller with several signers is refused whatever the list holds', () {
    for (final apps in [const <MailApp>[], _apps]) {
      const caller = MailCaller(package: 'net.thunderbird.android', cert: _cert, refusal: MailCallerRefusal.severalSigners);
      expect(judgeCaller(caller, apps), MailCallerStanding.refused);
      expect(approvalOf(caller, apps), isNull);
    }
  });

  test('a caller with no package or no certificate is refused', () {
    expect(judgeCaller(const MailCaller(package: '', cert: _cert), _apps), MailCallerStanding.refused);
    expect(judgeCaller(const MailCaller(package: 'net.thunderbird.android', cert: ''), _apps), MailCallerStanding.refused);
  });

  test('reads what the channel carries', () {
    expect(
      MailCaller.fromMap(const {'package': 'eu.faircode.email', 'cert': 'ab', 'label': 'FairEmail'}),
      const MailCaller(package: 'eu.faircode.email', cert: 'ab', label: 'FairEmail'),
    );
    expect(MailCaller.fromMap(const {'package': 'x', 'refused': 'severalSigners'}).refusal, MailCallerRefusal.severalSigners);
    expect(MailCaller.fromMap(const {'refused': 'something new'}).refusal, MailCallerRefusal.noPackage);
    expect(const MailCaller(package: 'eu.faircode.email', cert: 'ab').name, 'eu.faircode.email');
  });
}
