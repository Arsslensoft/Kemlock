// Sends against a real Kemlock Server (see server_kit.dart), as the phone makes and opens them (add-sends, task 11.1):
// a text Send with a password and an open limit of 1, opened from a second client with no session, and closed after;
// and a 3 MB file Send, opened and downloaded with its bytes checked. Skipped unless KEMLOCK_URL is set.
//
// The server must be https, as a recipient's client refuses anything else. A Send the test makes is deleted at the end.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sends/send_link.dart';
import 'package:kemlock/features/sends/sends_recipient.dart';
import 'package:kemlock/features/sends/sends_service.dart';
import 'package:kemlock/features/sync/kemlock/km_sends_api.dart';

import 'server_kit.dart' as kit;

/// The Send routes' answer of [problem], as a matcher.
Matcher _sendsProblem(SendsProblem problem) => isA<SendsError>().having((e) => e.problem, 'problem', problem);

/// A recipient with no account: a client of its own, and the pin only when the test server is self-signed.
SendsRecipient _recipient() => SendsRecipient(clientFor: (_) => kit.clientFor(kit.serverPin));

SendLink _linkOf(MadeSend made) {
  final link = SendLink.parse(made.link);
  if (link is! SendLink) throw StateError('the link made is not a Kemlock Send link');
  return link;
}

void main() {
  const longTimeout = Timeout(Duration(minutes: 5));

  test(
    'a text Send with a password and one open opens once from a client with no session, then is closed',
    () async {
      final phone = await kit.signInPhone();
      final service = SendsService(host: phone.host(), target: phone.target);
      final made = await service.make(
        NewSend.text(name: 'Kemlock server test', text: 'a text for one reader', password: 'a send password', maxAccess: 1),
      );
      try {
        final recipient = _recipient();
        final link = _linkOf(made);

        // The password is asked for, and a wrong one is refused
        await expectLater(recipient.open(link), throwsA(_sendsProblem(SendsProblem.passwordRequired)));
        await expectLater(recipient.open(link, password: 'not the password'), throwsA(_sendsProblem(SendsProblem.wrongPassword)));

        // The right one opens it, and that is the one open
        final opened = await recipient.open(link, password: 'a send password');
        expect(opened.payload.text, 'a text for one reader');
        expect(opened.payload.name, 'Kemlock server test');
        opened.dispose();

        // Closed after: the server says nothing but "not found"
        await expectLater(recipient.open(link, password: 'a send password'), throwsA(_sendsProblem(SendsProblem.notFound)));

        // The owner still lists it, as used up
        final owned = (await service.list()).firstWhere((send) => send.send.id == made.send.id);
        expect(owned.status, SendStatus.usedUp);
        expect(owned.meta?.name, 'Kemlock server test');
      } finally {
        await service.deleteById(made.send.id);
      }
    },
    skip: kit.skipServer,
    timeout: longTimeout,
  );

  test(
    'a 3 MB file Send opens from a client with no session and downloads the bytes that went up',
    () async {
      final phone = await kit.signInPhone();
      final service = SendsService(host: phone.host(), target: phone.target);
      final bytes = Uint8List(3 * 1024 * 1024);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i * 31 + (i >> 8)) & 0xff;
      }
      final made = await service.make(NewSend.file(name: 'kemlock-test.bin', bytes: bytes, mime: 'application/octet-stream'));
      try {
        final recipient = _recipient();
        final opened = await recipient.open(_linkOf(made));
        expect(opened.isFile, isTrue);
        expect(opened.payload.name, 'kemlock-test.bin');
        expect(opened.payload.mime, 'application/octet-stream');
        expect(opened.payload.size, bytes.length);

        final downloaded = await recipient.download(opened);
        opened.dispose();

        expect(downloaded, hasLength(bytes.length));
        expect(downloaded, orderedEquals(bytes));
      } finally {
        await service.deleteById(made.send.id);
      }
    },
    skip: kit.skipServer,
    timeout: longTimeout,
  );
}
