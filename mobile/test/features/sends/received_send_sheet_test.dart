// A Send link another app shares: it opens at once, asks for a password only when the server says so, shows a
// text where Copy goes through the secret clipboard, saves it as a note, and fetches a file once however often it is
// saved. The server is a MockClient that answers as Kemlock Server's public routes do.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kemlock/crypto/account/argon2id.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/crypto/account/send.dart';
import 'package:kemlock/features/sends/received_send_sheet.dart';
import 'package:kemlock/features/sends/send_link.dart';
import 'package:kemlock/features/sends/sends_providers.dart';
import 'package:kemlock/features/sends/sends_recipient.dart';
import 'package:kemlock/features/share/share_sheet.dart';
import 'package:kemlock/platform/shared_items.dart';
import 'package:kemlock/vault/vault_controller.dart';

import '../../flows/flow_kit.dart' show pumpUntil, tapOn;
import '../../helpers/test_app.dart';
import '../share/share_kit.dart';

/// A cheap stand-in for Argon2id, so a password's proof is quick to make.
Future<Uint8List> _quickProof(Uint8List password, Uint8List salt, Argon2idSettings settings) async =>
    Uint8List.fromList([for (var i = 0; i < 32; i++) (password.isEmpty ? 0 : password[i % password.length]) ^ salt[i % salt.length]]);

/// One Send on a server that answers its public routes.
class _Hosted {
  _Hosted._(this.id, this.key, this.kind, this.payload, {this.password, this.fileBytes});

  final Uint8List id;
  final Uint8List key;
  final String kind;
  final Uint8List payload;
  final String? password;
  final Uint8List? fileBytes;
  final requests = <http.Request>[];

  String get link => sendLink(Uri.parse('https://kem.example.com'), id, key);

  int get fileRequests => requests.where((request) => request.url.path.endsWith('/file')).length;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    http.Response problem(int status, String slug) => http.Response(
      jsonEncode({'type': 'urn:kemlock:problem:$slug', 'title': slug, 'status': status}),
      status,
      headers: {'content-type': 'application/problem+json'},
    );
    final wanted = password;
    if (wanted != null) {
      final proof = request.bodyBytes.isEmpty
          ? null
          : (jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>)['password'] as String?;
      if (proof == null) return problem(401, 'send-password-required');
      final expected = sendProofText(await sendProof(wanted, key, id, runner: _quickProof));
      if (proof != expected) return problem(401, 'send-wrong-password');
    }
    if (request.url.path.endsWith('/file')) {
      return http.Response.bytes(fileBytes!, 200, headers: {'content-type': 'application/octet-stream'});
    }
    return http.Response(
      jsonEncode({
        'id': sendAccessId(id),
        'kind': kind,
        'payload': b64urlEncode(payload),
        'fileSize': fileBytes?.length,
        'deletionAt': DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000,
        'senderEmail': 'ann@example.com',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  static Future<_Hosted> text(WidgetTester tester, {String name = 'Wi-Fi', String text = 'on the fridge', String? password}) async {
    final id = newSendId();
    final key = newSendLinkKey();
    final payload = await tester.runAsync(
      () => sealSendPart(
        sealLabel: SendLabel.payload,
        key: sendPayloadKey(key),
        sendId: id,
        kind: sendKindText,
        plaintext: SendPayload.text(name: name, text: text).encode(),
      ),
    );
    return _Hosted._(id, key, sendKindText, payload!, password: password);
  }

  static Future<_Hosted> file(WidgetTester tester, Uint8List plain, {String name = 'scan.pdf'}) async {
    final id = newSendId();
    final key = newSendLinkKey();
    final sealed = await tester.runAsync(() async {
      final payload = await sealSendPart(
        sealLabel: SendLabel.payload,
        key: sendPayloadKey(key),
        sendId: id,
        kind: sendKindFile,
        plaintext: SendPayload.file(name: name, mime: 'application/pdf', size: plain.length).encode(),
      );
      return (payload, await sealSendFile(plain, key));
    });
    return _Hosted._(id, key, sendKindFile, sealed!.$1, fileBytes: sealed.$2);
  }
}

class _SendsApp extends ShareApp {
  _SendsApp(super.tester, this.hosted);

  final _Hosted hosted;

  @override
  List<Override> get overrides => [
    ...super.overrides,
    sendsRecipientProvider.overrideWithValue(SendsRecipient(clientFor: (pin) => hosted.client, proofRunner: _quickProof)),
  ];
}

/// Pumps, with real time between, until [finder] finds something: a loading bar that moves never lets the app settle.
Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  Future<_SendsApp> opened(WidgetTester tester, _Hosted hosted) async {
    final app = _SendsApp(tester, hosted);
    await app.start();
    app.shared.send(SharedText('Here it is: ${hosted.link}'));
    return app;
  }

  testWidgets('a shared Send link opens the Send, and another shared text opens the share sheet', (tester) async {
    final hosted = await _Hosted.text(tester);
    final app = await opened(tester, hosted);
    await _until(tester, find.text('on the fridge'));
    expect(find.text(t('sends.received.from', {'email': 'ann@example.com'})), findsOneWidget);
    expect(hosted.requests.single.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
    await tapOn(tester, find.text(t('sends.received.close')));

    app.shared.send(const SharedText('Meet me at nine.'));
    await pumpUntil(tester, find.byType(ShareSheet));
    expect(find.byType(ReceivedSendSheet), findsNothing);
  });

  testWidgets('Copy goes through the secret clipboard, and Save as note adds a note to the open vault', (tester) async {
    final hosted = await _Hosted.text(tester);
    final app = await opened(tester, hosted);
    await _until(tester, find.text('on the fridge'));

    await tapOn(tester, find.text(t('sends.received.copy')));
    expect(app.copies, ['on the fridge']);
    // The toast that says so would lie over the next button
    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, find.text(t('sends.received.saveNote')));

    final notes = app.app.state.notes;
    expect(notes.map((note) => (note.title, note.text)), [('Wi-Fi', 'on the fridge')]);
  });

  testWidgets('a password is asked only when the server says so, and a wrong one is asked again', (tester) async {
    final hosted = await _Hosted.text(tester, password: 'hunter2');
    await opened(tester, hosted);
    await _until(tester, find.text(t('sends.received.password.title')));
    expect(find.text('on the fridge'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.pump();
    await tester.tap(find.text(t('sends.received.password.open')));
    await _until(tester, find.text(t('sends.received.wrongPassword')));
    expect(find.text('on the fridge'), findsNothing);

    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pump();
    await tester.tap(find.text(t('sends.received.password.open')));
    await _until(tester, find.text('on the fridge'));
    expect(hosted.requests.map((request) => request.bodyBytes.isEmpty), [true, false, false], reason: 'the first try carries no proof');
    expect(hosted.requests.map((request) => utf8.decode(request.bodyBytes)).join(), isNot(contains('hunter2')));
  });

  testWidgets('a file is fetched on the first Save, and a second Save and a Share make no second request', (tester) async {
    final plain = Uint8List.fromList(List.generate(2000, (i) => i & 0xff));
    final hosted = await _Hosted.file(tester, plain);
    final app = await opened(tester, hosted);
    await _until(tester, find.text('scan.pdf'));
    expect(hosted.fileRequests, 0, reason: 'showing the file spends no open');
    expect(find.text(t('sends.received.fileUses')), findsOneWidget);

    await tester.tap(find.text(t('sends.received.save')));
    for (var i = 0; i < 200 && app.files.saved.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.files.saved.single.bytes, plain);
    expect(app.files.saved.single.name, 'scan.pdf');
    expect(hosted.fileRequests, 1);

    await tester.pump(const Duration(seconds: 10));
    await tapOn(tester, find.text(t('sends.received.save')));
    await tapOn(tester, find.text(t('sends.received.share')));
    expect(app.files.saved, hasLength(3));
    expect(hosted.fileRequests, 1);
  });

  testWidgets('the sheet goes when the vault locks', (tester) async {
    final hosted = await _Hosted.text(tester);
    final app = await opened(tester, hosted);
    await _until(tester, find.text('on the fridge'));

    app.app.controller.lock();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(ReceivedSendSheet), findsNothing);
    expect(app.app.state.phase, VaultPhase.locked);
  });
}
