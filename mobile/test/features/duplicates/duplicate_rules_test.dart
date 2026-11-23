import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/duplicates/duplicate_normalise.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/models/backup_service.dart';
import 'package:kemlock/models/identity.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/passkey.dart';
import 'package:kemlock/models/payment_card.dart';
import 'package:kemlock/models/secure_note.dart';
import 'package:kemlock/models/website_rule.dart';

// A stand-in for the Public Suffix List: the last two labels of a host, and okta.com tenants kept whole
final _sites = SiteResolver(
  registrable: (host) => host.split('.').reversed.take(2).toList().reversed.join('.'),
  isShared: (host) => host == 'okta.com' || host.endsWith('.okta.com'),
);

Login _login(String id, {String? username, String? password, List<String>? websites, List<WebsiteRule>? uris}) =>
    Login(id: id, name: 'Login $id', username: username, password: password, websites: websites, uris: uris, addedAt: 0);

OtpAccount _code(String id, String issuer, String secret, {OtpType? type, int? counter}) =>
    OtpAccount(id: id, issuer: issuer, label: 'me', secret: secret, type: type, counter: counter, addedAt: 0);

Passkey _passkey(String id, String rpId, String credentialId) =>
    Passkey(id: id, credentialId: credentialId, rpId: rpId, userHandle: 'h', userName: 'u', privateKey: 'k', addedAt: 0);

BackupService _codes(String id, String name, List<String> codes) => BackupService(
  id: id,
  serviceName: name,
  codes: [for (final code in codes) BackupCode(code: code)],
  addedAt: 0,
);

SecureNote _note(String id, String text) => SecureNote(id: id, title: 'Note $id', text: text, addedAt: 0);

List<List<String>> _arrays(List<TagInput> inputs) => [for (final input in inputs) input.array];

void main() {
  test('the rule module imports no Flutter package', () {
    for (final file in ['duplicate_rules.dart', 'duplicate_normalise.dart']) {
      final source = File('lib/features/duplicates/$file').readAsStringSync();
      expect(source, isNot(contains('package:flutter')), reason: file);
      expect(source, isNot(contains('dart:ui')), reason: file);
    }
  });

  group('logins', () {
    test('are one by id, whatever else differs', () {
      expect(sameCredential(_login('a', password: 'x'), _login('a', password: 'y')), isTrue);
    });

    test('are one by site, username and password, under another id', () {
      final held = _login('a', username: 'sam', password: 'hunter2', websites: ['larkspur.example']);
      final again = _login('b', username: ' Sam', password: 'hunter2', websites: ['mail.larkspur.example']);

      expect(sameCredential(held, again, sites: _sites), isTrue);
      // Without the list each host stands for itself
      expect(sameCredential(held, again), isFalse);
    });

    test('are not one when the site and username match but the passwords differ, or only their case does', () {
      final held = _login('a', username: 'sam', password: 'hunter2', websites: ['larkspur.example']);
      final other = _login('b', username: 'sam', password: 'other', websites: ['larkspur.example']);
      final upper = _login('c', username: 'sam', password: 'Hunter2', websites: ['larkspur.example']);

      expect(sameCredential(held, other, sites: _sites), isFalse);
      expect(sameCredential(held, upper, sites: _sites), isFalse);
    });

    test('are not one on a password alone, nor on two tenants of a shared host', () {
      final alpha = _login('a', username: 'sam', password: 'p', websites: ['alpha.example']);
      final beta = _login('b', username: 'sam', password: 'p', websites: ['beta.example']);
      final tenantA = _login('c', username: 'sam', password: 'p', websites: ['alpha.okta.com']);
      final tenantB = _login('d', username: 'sam', password: 'p', websites: ['beta.okta.com']);

      expect(sameCredential(alpha, beta, sites: _sites), isFalse);
      expect(sameCredential(tenantA, tenantB, sites: _sites), isFalse);
    });

    test('are one when any website of each has the same site', () {
      final held = _login('a', username: 'sam', password: 'p', websites: ['one.example', 'proton.me']);
      final other = _login('b', username: 'sam', password: 'p', websites: ['account.proton.me']);

      expect(sameCredential(held, other, sites: _sites), isTrue);
    });

    test('with no password are never one by credential', () {
      final a = _login('a', username: 'sam', websites: ['larkspur.example']);
      final b = _login('b', username: 'sam', websites: ['larkspur.example']);

      expect(sameCredential(a, b), isFalse);
    });

    test('with no website share the empty site', () {
      expect(sameCredential(_login('a', username: 'sam', password: 'p'), _login('b', username: 'SAM', password: 'p')), isTrue);
    });
  });

  group('codes', () {
    test('are one by their secret alone, whatever the issuer, spacing and case', () {
      expect(sameCredential(_code('1', 'Google', 'JBSWY3DPEHPK3PXP'), _code('2', 'google.com', 'jbsw y3dp ehpk 3pxp')), isTrue);
      expect(sameCredential(_code('1', 'Google', 'JBSWY3DPEHPK3PXP'), _code('2', 'Google', 'KRSXG5CTMVRXEZLU')), isFalse);
    });

    test('with an empty secret are not one', () {
      expect(sameCredential(_code('1', 'A', ''), _code('2', 'A', '')), isFalse);
    });

    test('raise a held HOTP counter to a higher one only', () {
      final held = _code('1', 'A', 'JBSWY3DPEHPK3PXP', type: OtpType.hotp, counter: 9);
      OtpAccount incoming(int? counter, {OtpType? type = OtpType.hotp}) =>
          _code('2', 'A', 'JBSWY3DPEHPK3PXP', type: type, counter: counter);

      expect(raisedCounter(held, incoming(12)), 12);
      expect(raisedCounter(held, incoming(9)), isNull);
      expect(raisedCounter(held, incoming(3)), isNull);
      expect(raisedCounter(held, incoming(null)), isNull);
      expect(raisedCounter(_code('1', 'A', 'JBSWY3DPEHPK3PXP'), incoming(12)), isNull);
    });
  });

  group('passkeys', () {
    test('are one by relying party and credential id', () {
      expect(sameCredential(_passkey('a', 'github.com', 'c1'), _passkey('b', 'GitHub.com', 'c1')), isTrue);
    });

    test('are not one by credential id alone', () {
      expect(sameCredential(_passkey('a', 'github.com', 'c1'), _passkey('b', 'gitlab.com', 'c1')), isFalse);
      expect(sameCredential(_passkey('a', 'github.com', 'c1'), _passkey('b', 'github.com', 'c2')), isFalse);
    });

    test('have a relying party in lower case alone, and a credential id as base64url without padding', () {
      expect(passkeyTagInput(_passkey('a', 'İExample.COM', 'ab')).array, ['passkey', 'iexample.com', 'ab']);
      // Neither trimmed nor put in NFC, which only a username is
      expect(passkeyTagInput(_passkey('a', ' Example.com', 'ab')).values.first, ' example.com');
      expect(passkeyTagInput(_passkey('a', 'example.com', 'a+b/c==')).values.last, 'a-b_c');
      expect(passkeyTagInput(_passkey('a', 'example.com', 'a-b_c')).values.last, 'a-b_c');
    });
  });

  group('backup-code lists', () {
    test('are one by id, or by the same set of codes in any order', () {
      expect(sameCredential(_codes('a', 'GitLab', ['1', '2']), _codes('a', 'Other', ['9'])), isTrue);
      expect(sameCredential(_codes('a', 'GitLab', ['1', '2']), _codes('b', 'GitHub', ['2', '1'])), isTrue);
    });

    test('are not one by service name, nor when empty', () {
      expect(sameCredential(_codes('a', 'GitLab', ['1', '2']), _codes('b', 'GitLab', ['3', '4'])), isFalse);
      expect(sameCredential(_codes('a', 'GitLab', const []), _codes('b', 'GitLab', const [])), isFalse);
    });
  });

  group('notes and other kinds', () {
    test('a note is one by id alone', () {
      expect(sameCredential(_note('a', 'text'), _note('a', 'other')), isTrue);
      expect(sameCredential(_note('a', 'text'), _note('b', 'text')), isFalse);
    });

    test('items of two kinds, or of a kind with no rule here, are not one', () {
      const card = PaymentCard(id: 'a', name: 'Card', addedAt: 0);

      expect(sameCredential(_login('a', password: 'p'), _note('a', 'p')), isFalse);
      expect(sameCredential(card, card), isFalse);
    });
  });

  group('tag inputs', () {
    test('a login makes cred and account for each site, and account alone without a password', () {
      final login = _login('a', username: ' Sam@Example.org', password: 'Hunter2', websites: ['accounts.larkspur.example']);

      expect(_arrays(loginTagInputs(login, _sites)), [
        ['cred', 'larkspur.example', 'sam@example.org', 'Hunter2'],
        ['account', 'larkspur.example', 'sam@example.org'],
      ]);
      expect(_arrays(loginTagInputs(_login('b', username: 'sam', websites: ['larkspur.example']), _sites)), [
        ['account', 'larkspur.example', 'sam'],
      ]);
    });

    test('a login with no website makes one of each with an empty site', () {
      expect(_arrays(loginTagInputs(_login('a', username: 'sam', password: 'p'), _sites)), [
        ['cred', '', 'sam', 'p'],
        ['account', '', 'sam'],
      ]);
    });

    test('a login with twenty sites on different domains makes the most, 32 tags, for its first 16', () {
      final login = _login('a', username: 'sam', password: 'p', websites: [for (var i = 0; i < 20; i++) 'site$i.example']);
      final inputs = loginTagInputs(login, _sites);

      expect(inputs, hasLength(maxTagsPerItem));
      expect(inputs.last.values.first, 'site15.example');
    });

    test('websites under one site make one pair, and regular-expression and never websites none', () {
      final login = _login(
        'a',
        username: 'sam',
        password: 'p',
        uris: [
          const WebsiteRule('mail.larkspur.example'),
          const WebsiteRule('accounts.larkspur.example'),
          const WebsiteRule(r'^https://.*\.example', match: WebsiteMatch.regularExpression),
          const WebsiteRule('never.example', match: WebsiteMatch.never),
        ],
      );
      expect(loginTagInputs(login, _sites), hasLength(2));

      final only = _login(
        'b',
        username: 'sam',
        password: 'p',
        uris: [const WebsiteRule('never.example', match: WebsiteMatch.never)],
      );
      expect(loginTagInputs(only, _sites), isEmpty);
    });

    test('a code, passkey, card, note, key, backup-code list and identity make one each', () {
      const card = PaymentCard(id: 'c', name: 'Card', number: '4111 1111 1111 1111', expMonth: 12, expYear: 2030, addedAt: 0);
      const identity = Identity(id: 'i', name: 'Me', givenName: ' Sam ', familyName: 'Ng', email: 'Sam@Example.org', addedAt: 0);

      expect(codeTagInput(_code('1', 'A', 'JBSWY3DPEHPK3PXP'))!.array, ['secret', 'JBSWY3DPEHPK3PXP']);
      expect(passkeyTagInput(_passkey('a', 'Example.com', 'dGVzdA')).array, ['passkey', 'example.com', 'dGVzdA']);
      expect(cardTagInput(card)!.array, ['card', '4111111111111111', '2030-12']);
      expect(noteTagInput(_note('n', 'line one \r\nline two\n'))!.array, ['note', 'line one\nline two']);
      expect(keyTagInput('SHA256:abcdef')!.array, ['key', 'SHA256:abcdef']);
      expect(codesTagInput(_codes('s', 'GitLab', ['33333333', '11111111', '22222222']))!.array, [
        'codes',
        '11111111',
        '22222222',
        '33333333',
      ]);
      expect(identityTagInput(identity)!.array, ['identity', 'sam ng', 'sam@example.org']);
    });

    test('an identity is told by its full name and email: the middle name counts, the split of the name does not', () {
      const split = Identity(
        id: 'a',
        name: 'Home',
        givenName: 'Sam',
        middleName: 'Lee',
        familyName: 'Ng',
        email: 'sam@example.org',
        addedAt: 0,
      );
      const whole = Identity(id: 'b', name: 'Work', givenName: 'Sam Lee Ng', email: ' SAM@example.org ', addedAt: 0);

      expect(identityTagInput(split)!.array, ['identity', 'sam lee ng', 'sam@example.org']);
      expect(identityTagInput(split), identityTagInput(whole));
      expect(identityTagInput(const Identity(id: 'c', name: 'Mail', email: 'Sam@Example.org', addedAt: 0))!.array, [
        'identity',
        '',
        'sam@example.org',
      ]);
    });

    test('an item with nothing to match on makes no tag', () {
      expect(codeTagInput(_code('1', 'A', '')), isNull);
      expect(cardTagInput(const PaymentCard(id: 'c', name: 'Card', addedAt: 0)), isNull);
      expect(noteTagInput(_note('n', '  \n')), isNull);
      expect(keyTagInput(null), isNull);
      expect(codesTagInput(_codes('s', 'GitLab', const [])), isNull);
      expect(identityTagInput(const Identity(id: 'i', name: 'Me', addedAt: 0)), isNull);
    });

    test('Hunter2 and hunter2 differ in cred and share account', () {
      final a = _login('a', username: 'sam', password: 'Hunter2', websites: ['larkspur.example']);
      final b = _login('b', username: 'sam', password: 'hunter2', websites: ['larkspur.example']);

      expect(loginCredKeys(a, _sites).intersection(loginCredKeys(b, _sites)), isEmpty);
      expect(loginAccountInputs(a, _sites), loginAccountInputs(b, _sites));
    });
  });

  group('reasons', () {
    test('the strongest shared kind decides, cred before account', () {
      expect(DuplicateReason.strongest([TagKind.account, TagKind.cred]), DuplicateReason.sameSignIn);
      expect(DuplicateReason.strongest([TagKind.account]), DuplicateReason.sameAccount);
      expect(DuplicateReason.strongest(const []), isNull);
    });

    test('every tag kind has a reason, and two places has none', () {
      for (final kind in TagKind.values) {
        expect(DuplicateReason.of(kind).kind, kind);
      }
      expect(DuplicateReason.inTwoPlaces.kind, isNull);
    });
  });
}
