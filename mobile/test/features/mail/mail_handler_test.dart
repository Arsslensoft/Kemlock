import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/bytes.dart';
import 'package:kemlock/crypto/keys/keys.dart' as crypto;
import 'package:kemlock/crypto/keys/openpgp/edit.dart' show changePgpKey;
import 'package:kemlock/crypto/keys/openpgp/key_info.dart' show transferablePublicKey;
import 'package:kemlock/crypto/keys/openpgp/packets.dart' show readPackets;
import 'package:kemlock/crypto/keys/pgp.dart' as pgp;
import 'package:kemlock/features/contacts/contact_standing.dart';
import 'package:kemlock/features/keys/key_standing.dart';
import 'package:kemlock/features/mail/mail_apps.dart';
import 'package:kemlock/features/mail/mail_caller.dart';
import 'package:kemlock/features/mail/mail_handler.dart';
import 'package:kemlock/features/mail/mail_key_cache.dart';
import 'package:kemlock/features/mail/mail_keys.dart';
import 'package:kemlock/features/pgp/pgp_job.dart';
import 'package:kemlock/features/pgp/pgp_widgets.dart' show jobKeyOf;
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/json.dart';
import 'package:kemlock/models/vault_key.dart';
import 'package:kemlock/platform/mail_requests.dart';

import '../../helpers/test_app.dart';
import '../pgp/pgp_kit.dart' show fixtureBytes;
import 'mail_kit.dart';

/// A job that ends when it is told to, or when it is cancelled.
class _HeldJob implements PgpJob {
  final _done = Completer<PgpOutcome>();
  var cancelled = false;

  @override
  ValueListenable<double> get progress => ValueNotifier<double>(0);

  @override
  Future<PgpOutcome> get result => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) _done.complete(const PgpCancelledOutcome());
  }

  void end(PgpOutcome outcome) => _done.complete(outcome);
}

const _tbCert = '9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b';
const _thunderbird = MailCaller(package: 'net.thunderbird.android', cert: _tbCert, label: 'Thunderbird');
const _stranger = MailCaller(package: 'org.example.mail', cert: 'cc33', label: 'Example Mail');

/// The mail fixtures are dated 17 November 2026; the test keys were made two days before.
final _now = DateTime.utc(2026, 11, 17, 9);

var _ids = 0;

MailCall _call(
  String action, {
  Map<String, Object?> extras = const {},
  MailCaller caller = _thunderbird,
  Uint8List? input,
  String? resentFrom,
  bool dry = false,
}) => MailCall(
  requestId: 'r${++_ids}',
  resentFrom: resentFrom,
  action: action,
  extras: {'api_version': 12, ...extras},
  caller: caller,
  input: input,
  dry: dry,
);

/// Every action the table of decision 9 names.
const _actions = [
  OpenPgp.checkPermission,
  OpenPgp.getSignKeyId,
  OpenPgp.getKeyIds,
  OpenPgp.getKey,
  OpenPgp.sign,
  OpenPgp.cleartextSign,
  OpenPgp.detachedSign,
  OpenPgp.encrypt,
  OpenPgp.signAndEncrypt,
  OpenPgp.decryptVerify,
  OpenPgp.queryAutocryptStatus,
  OpenPgp.updateAutocryptPeer,
  OpenPgp.backup,
  OpenPgp.autocryptKeyTransfer,
  OpenPgp.decryptMetadata,
];

/// Answering mail apps' requests (openspec: add-pgp-mail-provider, tasks
/// 4.2 to 4.7).
void main() {
  late MailPhone phone;

  setUp(() async {
    phone = await MailPhone.open(now: _now);
    addTearDown(phone.dispose);
  });

  MailHandler handler() => phone.container.read(mailHandlerProvider);
  Future<MailAnswer> send(MailCall call) => handler().answer(call);
  MailStep? stepOf(MailCall call) => handler().pending(call.requestId)?.step;

  Future<void> approve({List<String> keys = const ['pgp-ed'], List<String> unchecked = const []}) => phone.container
      .read(mailAppsProvider.notifier)
      .put(MailApp(package: _thunderbird.package, cert: _tbCert, name: 'Thunderbird', allowedAt: 0, keys: keys, unchecked: unchecked));

  group('the order of checks', () {
    Future<List<Map<String, Object?>>> lockedAnswers() async {
      final answers = <Map<String, Object?>>[];
      for (final caller in [_thunderbird, _stranger]) {
        for (final action in _actions) {
          final call = _call(
            action,
            caller: caller,
            extras: {
              'key_ids': [keyIdOf(edFingerprint)],
              'user_ids': ['ed25519@example.org'],
            },
          );
          final answer = await send(call);
          answers.add(answer.toMap());
          expect(stepOf(call), isA<UnlockStep>());
        }
      }
      return answers;
    }

    test('locked, every action of every caller gets one answer, with keys or without', () async {
      phone.lock();
      final empty = await lockedAnswers();

      await phone.unlock('pw');
      await phone.addKey('ed');
      await approve();
      phone.lock();
      final full = await lockedAnswers();

      final all = [...empty, ...full];
      expect(all.map(jsonEncode).toSet(), hasLength(1), reason: 'every answer must be the same');
      expect(all.first, {
        'result': {'result_code': 2},
        'output': null,
      });
    });

    test('an unknown API version gets the incompatible-version error', () async {
      await approve();
      for (final version in [2, 13, null]) {
        final answer = await send(
          MailCall(requestId: 'v$version', action: OpenPgp.checkPermission, extras: {'api_version': ?version}, caller: _thunderbird),
        );
        expect(answer.result, {
          'result_code': 0,
          'error': {'id': OpenPgp.incompatibleApiVersions, 'message': isA<String>()},
        });
      }
      final eleven = await send(
        MailCall(requestId: 'v11', action: OpenPgp.checkPermission, extras: const {'api_version': 11}, caller: _thunderbird),
      );
      expect(eleven.resultCode, 1);
    });

    test('an unknown caller gets the same answer, locked or open, whatever version it sends', () async {
      Future<Map<String, Object?>> answerTo(Object? version) async => (await send(
        MailCall(requestId: 's${++_ids}', action: OpenPgp.checkPermission, extras: {'api_version': ?version}, caller: _stranger),
      )).toMap();
      final open = [
        for (final version in [1, 2, 12, 13, null, 'x']) await answerTo(version),
      ];
      phone.lock();
      final locked = [
        for (final version in [1, 2, 12, 13, null, 'x']) await answerTo(version),
      ];
      expect([...open, ...locked].map(jsonEncode).toSet(), {
        jsonEncode({
          'result': {'result_code': 2},
          'output': null,
        }),
      });
    });

    test('an unknown caller is asked about', () async {
      final call = _call(OpenPgp.checkPermission, caller: _stranger);
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<ApproveStep>().having((s) => s.otherCertificate, 'otherCertificate', isFalse));
    });

    test('a caller under another certificate is asked about, with the warning', () async {
      await approve();
      final call = _call(
        OpenPgp.checkPermission,
        caller: const MailCaller(package: 'net.thunderbird.android', cert: 'ff00'),
      );
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<ApproveStep>().having((s) => s.otherCertificate, 'otherCertificate', isTrue));
    });

    test('a caller with several signers is refused, and never asked about', () async {
      await approve();
      final call = _call(
        OpenPgp.checkPermission,
        caller: const MailCaller(package: 'net.thunderbird.android', cert: _tbCert, refusal: MailCallerRefusal.severalSigners),
      );
      expect((await send(call)).resultCode, 0);
      expect(stepOf(call), isNull);
    });

    test('an approved caller is answered', () async {
      await approve();
      expect((await send(_call(OpenPgp.checkPermission))).result, {'result_code': 1});
    });

    test('eight requests at most are kept for one app, its oldest forgotten first', () async {
      phone.lock();
      final thunderbird = _call(OpenPgp.decryptVerify);
      await send(thunderbird);
      final stranger = [for (var i = 0; i < MailHandler.pendingPerApp + 1; i++) _call(OpenPgp.decryptVerify, caller: _stranger)];
      for (final call in stranger) {
        await send(call);
      }
      expect(stepOf(stranger.first), isNull);
      for (final call in stranger.skip(1)) {
        expect(stepOf(call), isA<UnlockStep>());
      }
      expect(stepOf(thunderbird), isA<UnlockStep>(), reason: "another app's is kept");
      expect(MailHandler.pendingPerApp, 8);
    });

    test('a dry call wants the input only from an approved app with nothing left to ask', () async {
      final sign = {'sign_key_id': keyIdOf(edFingerprint)};
      // Locked, or a stranger: the person is needed, and the service reads nothing
      phone.lock();
      expect((await send(_call(OpenPgp.sign, extras: sign, dry: true))).toMap(), {
        'result': {'result_code': 2},
        'output': null,
      });
      await phone.unlock('pw');
      await phone.addKey('ed');
      final stranger = _call(OpenPgp.decryptVerify, caller: _stranger, dry: true);
      expect((await send(stranger)).result, {'result_code': 2});
      expect(stepOf(stranger), isA<ApproveStep>());
      // Approved without the key: asked about, still without the input
      await approve(keys: const []);
      final notAllowed = _call(OpenPgp.sign, extras: sign, dry: true);
      expect((await send(notAllowed)).result, {'result_code': 2});
      expect(stepOf(notAllowed), isA<AddKeyStep>());
      // A request with no work on the input is answered outright
      await approve();
      expect((await send(_call(OpenPgp.checkPermission, dry: true))).result, {'result_code': 1});
      // The work alone is left
      for (final action in [OpenPgp.sign, OpenPgp.detachedSign, OpenPgp.decryptVerify]) {
        final answer = await send(_call(action, extras: sign, dry: true));
        expect(answer.wantsInput, isTrue, reason: action);
        expect(answer.toMap(), {'sendInput': true});
      }
      final signed = await send(_call(OpenPgp.sign, extras: sign, input: mailFixture('body.eml')));
      expect(signed.resultCode, 1);
    });
  });

  group('key questions', () {
    setUp(() async {
      await phone.addKey('ed');
      await phone.addKey('rsa-protected');
      await approve();
    });

    test('give key IDs as the low 64 bits of the fingerprint, as signed longs', () async {
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint);
      final answer = await send(
        _call(
          OpenPgp.getKeyIds,
          extras: {
            'user_ids': ['Fixture RSA <rsa@example.org>', 'ed25519@example.org'],
          },
        ),
      );
      expect(answer.result, {
        'result_code': 1,
        'key_ids': unorderedEquals([keyIdOf(rsaFingerprint), keyIdOf(edFingerprint)]),
      });
      // EA29C79D1C6570277907BB485D49D28C8EFC2F98 ends 5D49D28C8EFC2F98: positive; check a negative one rounds trip
      expect(keyIdOf('00000000000000000000000080000000000000FF'), isNegative);
    });

    test('an address with no key gives none, and an expired key is left out', () async {
      await phone.addContact(
        'c-expired',
        'keys/gnupg/expiry/expired.public.asc',
        name: 'Fixture Expired',
        fingerprint: 'C303A83AA9ECEFCCE8BEA40B1E31F533F9E4D55B',
      );
      final answer = await send(
        _call(
          OpenPgp.getKeyIds,
          extras: {
            'user_ids': ['nobody@example.org', 'expired@example.org'],
          },
        ),
      );
      expect(answer.result, {'result_code': 1, 'key_ids': <int>[]});
    });

    test("GET_KEY hands over a contact's public key, and no secret", () async {
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint);
      final answer = await send(_call(OpenPgp.getKey, extras: {'key_id': keyIdOf(rsaFingerprint)}));
      expect(answer.resultCode, 1);
      final info = crypto.readPgpKeyInfo(answer.output!);
      expect(info.primary.fingerprintHex, rsaFingerprint);
      expect(info.isSecret, isFalse);
    });

    test('GET_KEY hands over an allowed own key, armored when asked, with no secret packet', () async {
      final answer = await send(_call(OpenPgp.getKey, extras: {'key_id': keyIdOf(edFingerprint), 'ascii_armor': true}));
      expect(answer.resultCode, 1);
      final text = utf8.decode(answer.output!);
      expect(text, startsWith('-----BEGIN PGP PUBLIC KEY BLOCK-----'));
      expect((await pgp.readPgpPublicKey(text)).fingerprintHex, edFingerprint);
      expect(crypto.readPgpKeyInfo(Uint8List.fromList((await pgp.readPgpPublicKey(text)).transferableKey)).isSecret, isFalse);
      // Thunderbird asks by address, for its Autocrypt header, in binary
      final byAddress = await send(_call(OpenPgp.getKey, extras: {'user_id': 'ed25519@example.org'}));
      expect(crypto.readPgpKeyInfo(byAddress.output!).primary.fingerprintHex, edFingerprint);
    });

    test('GET_KEY for an own key not allowed for the app asks first', () async {
      final rsa = File('test/fixtures/keys/gnupg/rsa3072-protected.colons.txt')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('fpr'))
          .split(':')[9];
      final call = _call(OpenPgp.getKey, extras: {'key_id': keyIdOf(rsa)});
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<AddKeyStep>().having((s) => s.vaultKeyId, 'vaultKeyId', 'pgp-rsa-protected'));
    });

    test('GET_KEY for a key Kemlock never held is an error', () async {
      final answer = await send(_call(OpenPgp.getKey, extras: {'key_id': 42}));
      expect(answer.resultCode, 0);
    });

    test('CHECK_PERMISSION succeeds once approved', () async {
      expect((await send(_call(OpenPgp.checkPermission))).resultCode, 1);
    });

    test('GET_SIGN_KEY_ID brings up the picker, and answers with an allowed key it was handed back', () async {
      final ask = _call(OpenPgp.getSignKeyId, extras: {'user_id': 'Fixture <ed25519@example.org>', 'preselect_key_id': 7});
      expect((await send(ask)).result, {'result_code': 2});
      expect(
        stepOf(ask),
        isA<PickKeyStep>().having((s) => s.address, 'address', 'ed25519@example.org').having((s) => s.preselect, 'preselect', 7),
      );
      final again = await send(_call(OpenPgp.getSignKeyId, extras: {'sign_key_id': keyIdOf(edFingerprint)}, resentFrom: ask.requestId));
      expect(again.result, {
        'result_code': 1,
        'sign_key_id': keyIdOf(edFingerprint),
        'primary_user_id': 'Fixture Ed25519 <ed25519@example.org>',
      });
    });

    test('QUERY_AUTOCRYPT_STATUS: keys_confirmed only when every key is checked', () async {
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint);
      final unchecked = await send(
        _call(
          OpenPgp.queryAutocryptStatus,
          extras: {
            'user_ids': ['rsa@example.org', 'ed25519@example.org'],
          },
        ),
      );
      expect(unchecked.result, {'result_code': 1, 'autocrypt_status': OpenPgp.autocryptAvailable, 'keys_confirmed': false});
      final own = await send(
        _call(
          OpenPgp.queryAutocryptStatus,
          extras: {
            'user_ids': ['ed25519@example.org'],
          },
        ),
      );
      expect(own.result, {'result_code': 1, 'autocrypt_status': OpenPgp.autocryptAvailable, 'keys_confirmed': true});
      final missing = await send(
        _call(
          OpenPgp.queryAutocryptStatus,
          extras: {
            'user_ids': ['ed25519@example.org', 'nobody@example.org'],
          },
        ),
      );
      expect(missing.result, {'result_code': 1, 'autocrypt_status': OpenPgp.autocryptUnavailable, 'keys_confirmed': false});

      final contact = phone.state.contacts.single;
      await phone.vault.updateContact(contact.copyWith(checkedAt: 1, checkedFingerprint: rsaFingerprint));
      final checked = await send(
        _call(
          OpenPgp.queryAutocryptStatus,
          extras: {
            'user_ids': ['rsa@example.org', 'ed25519@example.org'],
          },
        ),
      );
      expect(checked.result['keys_confirmed'], isTrue);
    });
  });
  group('signing and encrypting', () {
    final body = mailFixture('body.eml');

    setUp(() async {
      await phone.addKey('ed');
      await phone.addKey('rsa');
      await approve();
    });

    Future<void> rsaContact({bool checked = false}) async {
      // The vault's own RSA key goes, so that the RSA key is a contact's
      await phone.vault.deleteKey(phone.state.keys.firstWhere((k) => k.id == 'pgp-rsa'));
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint, checked: checked);
    }

    test('a key not allowed for the app is not used: it is asked about', () async {
      final call = _call(OpenPgp.detachedSign, extras: {'sign_key_id': keyIdOf(rsaFingerprint)}, input: body);
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<AddKeyStep>().having((s) => s.vaultKeyId, 'vaultKeyId', 'pgp-rsa'));
    });

    test('a detached signature comes with its hash name and no message bytes, and verifies', () async {
      final answer = await send(
        _call(OpenPgp.detachedSign, extras: {'sign_key_id': keyIdOf(edFingerprint), 'ascii_armor': true}, input: body),
      );
      expect(answer.resultCode, 1);
      expect(answer.output, isNull);
      expect(answer.result['signature_micalg'], 'pgp-sha512');
      final signature = answer.result['detached_signature']! as Uint8List;
      expect(utf8.decode(signature), startsWith('-----BEGIN PGP SIGNATURE-----'));
      final verified = await pgp.verify(
        signed: pgp.PgpData.bytes(signature),
        data: pgp.PgpData.bytes(body),
        verifiers: [gnupgKey('ed25519.public')],
        now: _now,
      );
      expect(verified.signatures.single.verdict, pgp.SignatureVerdict.good);
    });

    test('a clear-signed text verifies', () async {
      final answer = await send(
        _call(OpenPgp.cleartextSign, extras: {'sign_key_id': keyIdOf(edFingerprint)}, input: mailFixture('note.txt')),
      );
      final verified = await pgp.verify(signed: pgp.PgpData.bytes(answer.output!), verifiers: [gnupgKey('ed25519.public')], now: _now);
      expect(verified.signatures.single.verdict, pgp.SignatureVerdict.good);
    });

    for (final armor in [true, false]) {
      test('signed and encrypted to a contact, ${armor ? 'armored' : 'binary'}, decrypts and verifies', () async {
        await rsaContact(checked: true);
        final answer = await send(
          _call(
            OpenPgp.signAndEncrypt,
            extras: {
              'sign_key_id': keyIdOf(edFingerprint),
              'user_ids': ['rsa@example.org'],
              'key_ids': [keyIdOf(edFingerprint)],
              'ascii_armor': armor,
            },
            input: body,
          ),
        );
        expect(answer.resultCode, 1, reason: '${answer.result}');
        expect(String.fromCharCodes(answer.output!.take(5)) == '-----', armor);
        for (final key in ['rsa3072.secret', 'ed25519.secret']) {
          final opened = await pgp.decrypt(
            data: pgp.PgpData.bytes(answer.output!),
            keys: [pgp.PgpSecretKey(gnupgKey(key))],
            verifiers: [gnupgKey('ed25519.public')],
            now: _now,
          );
          expect(opened.bytes, body);
          expect(opened.signatures.single.verdict, pgp.SignatureVerdict.good);
        }
      });
    }

    test('encrypting needs no private key', () async {
      await approve(keys: const []);
      await rsaContact(checked: true);
      final answer = await send(
        _call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': ['rsa@example.org'],
          },
          input: body,
        ),
      );
      expect(answer.resultCode, 1);
    });

    test('a recipient with no key brings up the missing keys, or with opportunistic an error', () async {
      final call = _call(
        OpenPgp.encrypt,
        extras: {
          'user_ids': ['ed25519@example.org', 'Nobody <nobody@example.org>'],
        },
        input: body,
      );
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<MissingKeysStep>().having((s) => s.addresses, 'addresses', ['nobody@example.org']));

      final quiet = await send(
        _call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': ['ed25519@example.org', 'nobody@example.org'],
            'opportunistic': true,
          },
          input: body,
        ),
      );
      expect(quiet.result, {
        'result_code': 0,
        'error': {'id': OpenPgp.opportunisticMissingKeys, 'message': contains('nobody@example.org')},
      });
    });

    test('an unchecked recipient is asked about once, and not after going on', () async {
      await rsaContact();
      final call = _call(
        OpenPgp.encrypt,
        extras: {
          'user_ids': ['rsa@example.org'],
        },
        input: body,
      );
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<UncheckedStep>().having((s) => s.contactIds, 'contactIds', ['c-rsa']));

      await approve(unchecked: const [rsaFingerprint]);
      final again = await send(
        _call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': ['rsa@example.org'],
          },
          input: body,
        ),
      );
      expect(again.resultCode, 1);
    });

    test('a key ID Kemlock never held is an error, as any unknown key', () async {
      final answer = await send(
        _call(
          OpenPgp.encrypt,
          extras: {
            'key_ids': [1234],
          },
          input: body,
        ),
      );
      expect(answer.result, {
        'result_code': 0,
        'error': {'id': OpenPgp.genericError, 'message': t('mail.error.noKey')},
      });
    });

    test('input over the limit is too large', () async {
      const call = MailCall(
        requestId: 'big',
        action: OpenPgp.encrypt,
        extras: {
          'api_version': 12,
          'user_ids': ['ed25519@example.org'],
        },
        caller: _thunderbird,
        inputTooLarge: true,
      );
      expect((await send(call)).result, {
        'result_code': 0,
        'error': {'id': OpenPgp.genericError, 'message': t('mail.error.tooLarge')},
      });
    });
  });

  group('decrypting and verifying', () {
    setUp(() async {
      await phone.addKey('ed');
      await approve();
    });

    Future<MailAnswer> decrypt(String fixture, {Map<String, Object?> extras = const {}}) =>
        send(_call(OpenPgp.decryptVerify, input: mailFixture(fixture), extras: extras));

    test('the signed and encrypted message gives its text, encrypted, and the signer unknown', () async {
      final answer = await decrypt('signed-encrypted.asc');
      expect(answer.resultCode, 1, reason: '${answer.result}');
      expect(answer.output, mailFixture('body.eml'));
      expect(answer.result['decryption'], {'result': OpenPgp.encrypted}, reason: 'no session key');
      expect(answer.result['signature'], {'result': OpenPgp.keyMissing, 'key_id': keyIdOf(rsaFingerprint), 'timestamp': isA<int>()});
    });

    test('a checked signer is confirmed, an unchecked one is not', () async {
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint, checked: true);
      final checked = await decrypt('signed-encrypted.asc', extras: {'sender_address': 'rsa@example.org'});
      expect(checked.result['signature'], {
        'result': OpenPgp.validKeyConfirmed,
        'key_id': keyIdOf(rsaFingerprint),
        'primary_user_id': 'Fixture RSA <rsa@example.org>',
        'user_ids': ['Fixture RSA <rsa@example.org>'],
        'confirmed_user_ids': ['Fixture RSA <rsa@example.org>'],
        'sender_status': 'confirmed',
        'timestamp': isA<int>(),
      });

      final contact = phone.state.contacts.single;
      await phone.vault.updateContact(contact.copyWith(checkedAt: unset, checkedFingerprint: unset));
      final unchecked = await decrypt('signed-encrypted.asc');
      final signature = unchecked.result['signature']! as Map<String, Object?>;
      expect(signature['result'], OpenPgp.validKeyUnconfirmed);
      expect(signature['confirmed_user_ids'], isEmpty);
      expect(signature['sender_status'], 'unknown');
    });

    test('a detached signature is verified, with nothing to decrypt', () async {
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint, checked: true);
      final answer = await decrypt('body.eml', extras: {'detached_signature': mailFixture('body.eml.sig.asc')});
      expect(answer.output, isNull);
      expect(answer.result['decryption'], {'result': OpenPgp.notEncrypted});
      expect(answer.result['signature'], containsPair('result', OpenPgp.validKeyConfirmed));
    });

    test('a clear-signed text verifies, and the changed one has a bad signature', () async {
      await phone.addContact('c-rsa', 'keys/gnupg/rsa3072.public.asc', name: 'Fixture RSA', fingerprint: rsaFingerprint, checked: true);
      final good = await decrypt('note.clearsigned.asc');
      expect(good.result['signature'], containsPair('result', OpenPgp.validKeyConfirmed));
      expect(good.result['decryption'], {'result': OpenPgp.notEncrypted});
      final bad = await decrypt('note.clearsigned-changed.asc');
      expect(bad.resultCode, 1);
      expect(bad.result['signature'], containsPair('result', OpenPgp.invalidSignature));
    });

    test('a message to a key of the vault the app may not use asks to add it', () async {
      await phone.addKey('rsa');
      final call = _call(OpenPgp.decryptVerify, input: mailFixture('signed-encrypted-rsa.asc'));
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<AddKeyStep>().having((s) => s.vaultKeyId, 'vaultKeyId', 'pgp-rsa'));
    });

    test('a message to a key the open vault lacks gives one error, whatever another vault holds', () async {
      final alone = await decrypt('signed-encrypted-rsa.asc');

      await phone.addHiddenVault('hidden pw');
      phone.lock();
      await phone.unlock('hidden pw');
      await phone.addKey('rsa');
      await approve(keys: const ['pgp-rsa']);
      expect((await decrypt('signed-encrypted-rsa.asc')).resultCode, 1, reason: 'the hidden vault opens it');
      phone.lock();
      await phone.unlock('pw');
      expect(phone.state.vault.hidden, isFalse);

      final besideHidden = await decrypt('signed-encrypted-rsa.asc');
      expect(alone.result, {
        'result_code': 0,
        'error': {'id': OpenPgp.genericError, 'message': t('mail.error.noKey')},
      });
      expect(jsonEncode(besideHidden.toMap()), jsonEncode(alone.toMap()));
    });
  });

  // A fingerprint compared proves whose key it is, not whose addresses its owner puts in it
  group('a check covers the addresses the key carried when it was made', () {
    const graceFingerprint = '894F6AAC8FCE0FAF7EE21BB6B405E72AFBA23495';
    const grace = 'Grace Hopper <grace@example.org>';
    const alice = 'Alice <alice@corp.com>';
    final body = mailFixture('body.eml');
    late Uint8List graceSecret;

    setUp(() async {
      await phone.addKey('ed');
      await approve();
      // Grace's key as she first gave it, checked; then the copy she gives later, with Alice's address in it
      final first = fixtureBytes('keys/contacts/grace-1.public.asc');
      graceSecret = await changePgpKey(
        (await crypto.readPrivateKey(fixtureBytes('keys/contacts/grace-1.secret.asc'))).private,
        const crypto.AddPgpUserId(name: 'Alice', email: 'alice@corp.com'),
        now: DateTime.utc(2026, 11, 17, 8),
      );
      final later = (await crypto.readPublicKeys(transferablePublicKey(readPackets(graceSecret)))).single.bytes;
      final checked = (await crypto.readPublicKeys(first)).single.bytes;
      final contact = Contact(
        id: 'c-grace',
        name: 'Grace Hopper',
        publicKey: b64(checked),
        source: ContactSource.qr,
        addedAt: 0,
      ).checked(graceFingerprint, 1, addresses: ['grace@example.org']);
      await phone.vault.addContact(contact.copyWith(publicKey: b64(await crypto.mergePublicKeys(checked, later))));
    });

    test('mail to the other address is asked about, as to an unchecked key, and mail to the checked one is not', () async {
      final toAlice = _call(
        OpenPgp.encrypt,
        extras: {
          'user_ids': [alice],
        },
        input: body,
      );
      expect((await send(toAlice)).result, {'result_code': 2});
      expect(stepOf(toAlice), isA<UncheckedStep>().having((s) => s.contactIds, 'contactIds', ['c-grace']));
      // Named with the checked address too, the key still goes to Alice's
      final toBoth = _call(
        OpenPgp.encrypt,
        extras: {
          'user_ids': [grace, alice],
        },
        input: body,
      );
      expect((await send(toBoth)).result, {'result_code': 2});

      final toGrace = await send(
        _call(
          OpenPgp.encrypt,
          extras: {
            'user_ids': [grace],
          },
          input: body,
        ),
      );
      expect(toGrace.resultCode, 1);
    });

    test('the key IDs for the other address are asked about first, since the app then names the key alone', () async {
      final forAlice = _call(
        OpenPgp.getKeyIds,
        extras: {
          'user_ids': [alice],
        },
      );
      expect((await send(forAlice)).result, {'result_code': 2});
      expect(stepOf(forAlice), isA<UncheckedStep>().having((s) => s.contactIds, 'contactIds', ['c-grace']));
      expect(await handler().stepFor(forAlice.requestId), isA<UncheckedStep>());

      final forGrace = await send(
        _call(
          OpenPgp.getKeyIds,
          extras: {
            'user_ids': [grace],
          },
        ),
      );
      expect(forGrace.result, {
        'result_code': 1,
        'key_ids': [keyIdOf(graceFingerprint)],
      });

      // Once the person goes on for it in this app
      await approve(unchecked: const [graceFingerprint]);
      expect(await handler().stepFor(forAlice.requestId), isNull);
      final again = await send(
        _call(
          OpenPgp.getKeyIds,
          extras: {
            'user_ids': [alice],
          },
        ),
      );
      expect(again.result, {
        'result_code': 1,
        'key_ids': [keyIdOf(graceFingerprint)],
      });
    });

    test('the other address is not confirmed for Autocrypt', () async {
      Future<Object?> confirmed(String userId) async => (await send(
        _call(
          OpenPgp.queryAutocryptStatus,
          extras: {
            'user_ids': [userId],
          },
        ),
      )).result['keys_confirmed'];
      expect(await confirmed(alice), isFalse);
      expect(await confirmed(grace), isTrue);
    });

    test("a signature is confirmed as Grace's, and not as Alice's", () async {
      final signature = await pgp.sign(
        data: pgp.PgpData.bytes(body),
        signer: pgp.PgpSecretKey(graceSecret),
        form: pgp.PgpSignatureForm.detachedArmored,
        now: _now,
      );
      Future<Map<String, Object?>> verified(String sender) async =>
          (await send(_call(OpenPgp.decryptVerify, input: body, extras: {'detached_signature': signature, 'sender_address': sender})))
                  .result['signature']!
              as Map<String, Object?>;

      final asAlice = await verified('alice@corp.com');
      expect(asAlice['result'], OpenPgp.validKeyUnconfirmed);
      expect(asAlice['sender_status'], 'unconfirmed');
      expect(asAlice['user_ids'], unorderedEquals([grace, alice]));
      expect(asAlice['confirmed_user_ids'], [grace]);

      final asGrace = await verified('Grace@Example.org');
      expect(asGrace['result'], OpenPgp.validKeyConfirmed);
      expect(asGrace['sender_status'], 'confirmed');
      expect(asGrace['confirmed_user_ids'], [grace]);
    });

    test('a check made before checks kept addresses covers the key as the vault first reads it, and no more', () async {
      // As an older version wrote it: Grace's first key, checked, with no addresses
      final first = (await crypto.readPublicKeys(fixtureBytes('keys/contacts/grace-1.public.asc'))).single.bytes;
      final contact = phone.state.contacts.single;
      await phone.vault.updateContact(contact.copyWith(publicKey: b64(first), checkedAddresses: unset));
      phone.lock();
      await phone.unlock('pw');
      expect(phone.state.contacts.single.checkedAddresses, ['grace@example.org']);
      expect((await phone.vaultStore.loadContacts(phone.state.session!)).single.checkedAddresses, ['grace@example.org']);

      // Alice's address comes in a later copy of the key, and is not covered
      final later = (await crypto.readPublicKeys(transferablePublicKey(readPackets(graceSecret)))).single.bytes;
      await phone.vault.updateContact(phone.state.contacts.single.copyWith(publicKey: b64(await crypto.mergePublicKeys(first, later))));
      phone.lock();
      await phone.unlock('pw');
      expect(phone.state.contacts.single.checkedAddresses, ['grace@example.org']);
      final toAlice = _call(
        OpenPgp.encrypt,
        extras: {
          'user_ids': [alice],
        },
        input: body,
      );
      expect((await send(toAlice)).result, {'result_code': 2});
    });
  });

  // Sixty-four bits are few enough to make a key with another's ID
  test('a key ID that keys of two fingerprints share is told apart from one key held twice', () {
    Uint8List bytesOf(String hex) =>
        Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
    MailContactKey contact(String id, String fingerprint) => MailContactKey(
      Contact(id: id, name: id, publicKey: '', source: ContactSource.file, addedAt: 0),
      ContactStanding(
        checked: true,
        key: KeyStanding.ok,
        canEncrypt: true,
        info: crypto.PgpKeyInfo(
          crypto.PgpKey(
            version: 4,
            fingerprint: bytesOf(fingerprint),
            algorithm: 'ed25519',
            created: DateTime.utc(2026),
            hasSecret: false,
            protected: false,
            revoked: false,
          ),
          const [],
          const [],
        ),
      ),
    );
    final real = contact('c-real', edFingerprint);
    final twin = contact('c-twin', '000000000000000000000000${edFingerprint.substring(24)}');
    expect(twin.keyId, real.keyId);

    expect(MailKeys(own: const [], contacts: [real, twin], now: _now).sharesId(real.keyId), isTrue);
    expect(MailKeys(own: const [], contacts: [real, contact('c-copy', edFingerprint)], now: _now).sharesId(real.keyId), isFalse);
    expect(MailKeys(own: const [], contacts: [real], now: _now).sharesId(real.keyId), isFalse);
  });

  // Nobody is at the screens to cancel a mail request's job
  group('a mail job', () {
    test('that runs past its time is cancelled, which ends its isolate, and comes to the time-out', () async {
      final job = _HeldJob();
      expect(await outcomeWithin(job, const Duration(milliseconds: 10)), same(mailJobTimedOut));
      expect(job.cancelled, isTrue);
    });

    test('that ends in time keeps its outcome and is not cancelled', () async {
      final job = _HeldJob();
      final outcome = outcomeWithin(job, const Duration(seconds: 30));
      job.end(const PgpFailedOutcome(pgp.PgpException(pgp.PgpProblem.damaged)));
      expect(await outcome, isA<PgpFailedOutcome>().having((o) => o.error.problem, 'problem', pgp.PgpProblem.damaged));
      expect(job.cancelled, isFalse);
    });

    test('has two minutes', () {
      expect(mailJobTimeout, const Duration(minutes: 2));
    });
  });

  // Joined with add-openpgp-card: a card is reached only from the PGP sheets
  group('a key on a security key', () {
    final note = mailFixture('note.txt');
    final onCard = {
      'result_code': 0,
      'error': {'id': OpenPgp.genericError, 'message': t('mail.error.onCard')},
    };

    setUp(() async {
      await phone.vault.addKey(
        VaultKey(
          id: 'pgp-card',
          name: 'On my key',
          kind: KeyKind.pgp,
          algorithm: 'pgp',
          privateKey: b64(gnupgKey('card/stub-ed25519')),
          publicKey: b64(gnupgKey('ed25519.public')),
          origin: KeyOrigin.imported,
          protected: true,
          addedAt: 0,
          card: const {
            'aid': 'D276000124010304FFFF123456780000',
            'slots': {'sig': edFingerprint, 'dec': '4BA83174FC8CE762A23BF0A4841A40E3B199EA67'},
          },
        ),
      );
      await approve(keys: const ['pgp-card']);
    });

    test('is encrypted to, as any own key', () async {
      final answer = await send(
        _call(
          OpenPgp.encrypt,
          extras: {
            'key_ids': [keyIdOf(edFingerprint)],
          },
          input: note,
        ),
      );
      expect(answer.resultCode, 1, reason: '${answer.result}');
    });

    test('signs nothing, and asks no passphrase for it', () async {
      final sign = _call(OpenPgp.cleartextSign, extras: {'sign_key_id': keyIdOf(edFingerprint)}, input: note);
      expect((await send(sign)).result, onCard);
      expect(stepOf(sign), isNull);

      final ask = _call(OpenPgp.getSignKeyId, extras: {'sign_key_id': keyIdOf(edFingerprint)});
      expect((await send(ask)).result, {'result_code': 2}, reason: 'not answered with the card key');
      expect(stepOf(ask), isA<PickKeyStep>());
    });

    test('opens no message, and asks no passphrase for it', () async {
      final message = await pgp.encrypt(data: pgp.PgpData.bytes(note), recipients: [gnupgKey('ed25519.public')], text: true, now: _now);
      final call = _call(OpenPgp.decryptVerify, input: message);
      expect((await send(call)).result, onCard);
      expect(stepOf(call), isNull);
    });
  });

  group('the rest of the table', () {
    setUp(() async {
      await phone.addKey('ed-protected');
      await approve(keys: const ['pgp-ed-protected']);
    });

    test('UPDATE_AUTOCRYPT_PEER succeeds, and the contacts are unchanged', () async {
      final before = phone.state.contacts;
      final answer = await send(
        _call(OpenPgp.updateAutocryptPeer, extras: {'autocrypt_peer_id': 'rsa@example.org', 'autocrypt_peer_update': 'ignored'}),
      );
      expect(answer.result, {'result_code': 1});
      expect(phone.state.contacts, before);
    });

    for (final (action, name) in [
      (OpenPgp.backup, 'BACKUP'),
      (OpenPgp.autocryptKeyTransfer, 'autocrypt_key_transfer'),
      (OpenPgp.decryptMetadata, 'DECRYPT_METADATA'),
      (OpenPgp.getSignKeyIdLegacy, 'GET_SIGN_KEY_ID_LEGACY'),
    ]) {
      test('$name gives an error naming it', () async {
        final answer = await send(_call(action));
        expect(answer.result, {
          'result_code': 0,
          'error': {
            'id': OpenPgp.genericError,
            'message': t('mail.error.unsupported', {'action': name}),
          },
        });
        expect(answer.output, isNull);
      });
    }

    test('the legacy SIGN clear-signs (design.md, task 1.3), and a passphrase the app sends is never read', () async {
      final call = _call(
        OpenPgp.sign,
        extras: {'sign_key_id': keyIdOf(edProtectedFingerprint), 'passphrase': 'fixture passphrase'},
        input: mailFixture('note.txt'),
      );
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<PassphraseStep>().having((s) => s.vaultKeyId, 'vaultKeyId', 'pgp-ed-protected'));
    });
  });
  group('a protected key opened for mail', () {
    final note = mailFixture('note.txt');

    setUp(() async {
      await phone.addKey('ed-protected');
      await approve(keys: const ['pgp-ed-protected']);
    });

    MailCall signCall() => _call(OpenPgp.cleartextSign, extras: {'sign_key_id': keyIdOf(edProtectedFingerprint)}, input: note);
    MailKeyCache cache() => phone.container.read(mailKeyCacheProvider);
    Map<String, String?> storage() => {for (final key in phone.store.storedKeys()) key: phone.store.getItem(key)};

    test('asks the first time, not the second, and again after the vault locked', () async {
      final first = signCall();
      expect((await send(first)).result, {'result_code': 2});
      expect(stepOf(first), isA<PassphraseStep>());

      final stored = storage();
      await handler().openKey('pgp-ed-protected', 'fixture passphrase');
      final second = await send(signCall());
      expect(second.resultCode, 1, reason: '${second.result}');
      final verified = await pgp.verify(
        signed: pgp.PgpData.bytes(second.output!),
        verifiers: [gnupgKey('ed25519-protected.public')],
        now: _now,
      );
      expect(verified.signatures.single.verdict, pgp.SignatureVerdict.good);
      expect(storage(), stored, reason: 'nothing of it is stored');

      phone.lock();
      expect(cache().holds('pgp-ed-protected'), isFalse);
      await phone.unlock('pw');
      final third = signCall();
      expect((await send(third)).result, {'result_code': 2});
      expect(stepOf(third), isA<PassphraseStep>());
    });

    test('a wrong passphrase opens nothing', () async {
      await expectLater(
        handler().openKey('pgp-ed-protected', 'not it'),
        throwsA(isA<pgp.PgpException>().having((e) => e.problem, 'problem', pgp.PgpProblem.wrongPassphrase)),
      );
      expect(cache().holds('pgp-ed-protected'), isFalse);
    });

    test('deleting the key empties its entry', () async {
      await handler().openKey('pgp-ed-protected', 'fixture passphrase');
      expect(cache().holds('pgp-ed-protected'), isTrue);
      await phone.vault.deleteKey(phone.state.keys.single);
      expect(cache().holds('pgp-ed-protected'), isFalse);
    });

    // A change made on the key's sheet (openspec: add-pgp-key-editing) stores a new private half
    test('changing the key empties its entry, and the next request asks again', () async {
      await handler().openKey('pgp-ed-protected', 'fixture passphrase');
      final key = phone.state.keys.single;
      final changed = await crypto.makeKey(
        crypto.PgpChangeRequest(
          unb64(key.privateKey),
          const crypto.AddPgpUserId(name: 'Fixture', email: 'second@example.org'),
          passphrase: 'fixture passphrase',
          now: _now,
        ),
      );

      expect(await phone.vault.replaceKeyHalves(key, changed.private, changed.public!), isTrue);

      expect(phone.state.keys.single.privateKey, isNot(key.privateKey));
      expect(cache().holds('pgp-ed-protected'), isFalse);
      final call = signCall();
      expect((await send(call)).result, {'result_code': 2});
      expect(stepOf(call), isA<PassphraseStep>().having((s) => s.vaultKeyId, 'vaultKeyId', 'pgp-ed-protected'));
    });

    test('removing the app empties its entry', () async {
      await handler().openKey('pgp-ed-protected', 'fixture passphrase');
      await phone.container.read(mailAppsProvider.notifier).remove(_thunderbird.package);
      expect(cache().holds('pgp-ed-protected'), isFalse);
    });

    test('the Sign sheet still asks for the passphrase while the cache holds the key', () async {
      await handler().openKey('pgp-ed-protected', 'fixture passphrase');
      // What the Sign sheet hands its job: the stored key, and a passphrase only once the person typed one
      final outcome = await runPgpRequest(SignRequest(now: _now, text: note, signer: jobKeyOf(phone.state.keys.single)));
      expect((outcome as PgpFailedOutcome).error.problem, pgp.PgpProblem.passphraseNeeded);
    });
  });
}
