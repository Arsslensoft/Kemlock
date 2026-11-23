import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/autofill/autofill_copy.dart';
import 'package:kemlock/features/logins/login_sites.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';
import 'package:kemlock/models/website_rule.dart';

import '../../helpers/test_app.dart';

Login _login(List<WebsiteRule> rules) => Login(id: 'l', name: 'L', password: 'p', websites: fillHosts(rules), uris: rules, addedAt: 0);

OtpAccount _account(String issuer, [List<WebsiteRule>? rules]) => OtpAccount(
  id: 'a',
  issuer: issuer,
  label: 'me',
  secret: 'JBSWY3DPEHPK3PXP',
  websites: rules == null ? null : fillHosts(rules),
  uris: rules,
  addedAt: 0,
);

// the add-cards-identities-and-websites plan, tasks 6.3 and 6.4
void main() {
  group('a login with rules fills on phones', () {
    test('as each rule says: Default and Base domain on the registrable domain, Host, Starts with and Exact on their host', () {
      final login = _login(const [
        WebsiteRule('accounts.larkspur.example'),
        WebsiteRule('shop.example.co.uk', match: WebsiteMatch.baseDomain),
        WebsiteRule('app.example.net', match: WebsiteMatch.host),
        WebsiteRule('https://intranet.example.org/login', match: WebsiteMatch.startsWith),
        WebsiteRule('https://wiki.example.org/home', match: WebsiteMatch.exact),
      ]);

      expect(loginDomains(login, suffixes: bundledSuffixes), [
        'larkspur.example',
        'example.co.uk',
        '=app.example.net',
        '=intranet.example.org',
        '=wiki.example.org',
      ]);
    });

    test('nowhere on Regular expression, Never and a rule of a later version, and the website is still listed', () {
      final login = _login(const [
        WebsiteRule('^https://example\\.co/', match: WebsiteMatch.regularExpression),
        WebsiteRule('wiki.example.co', match: WebsiteMatch.never),
        WebsiteRule('later.example', match: 9),
      ]);

      expect(loginDomains(login, suffixes: bundledSuffixes), isEmpty);
      expect(login.rules, hasLength(3));
    });

    test('on a shared host or an IP address on itself only, whatever the rule', () {
      final login = _login(const [
        WebsiteRule('example-co.okta.com', match: WebsiteMatch.baseDomain),
        WebsiteRule('acme.okta.com'),
        WebsiteRule('10.0.0.20', match: WebsiteMatch.baseDomain),
      ]);

      expect(loginDomains(login, suffixes: bundledSuffixes), ['=example-co.okta.com', '=acme.okta.com', '=10.0.0.20']);
    });

    test('a login with hosts alone gets the domains it always did', () {
      const login = Login(id: 'l', name: 'L', password: 'p', websites: ['accounts.larkspur.example', 'larkspur.example'], addedAt: 0);

      expect(loginDomains(login, suffixes: bundledSuffixes), ['larkspur.example']);
    });
  });

  group('an account with rules fills on phones', () {
    test('Default on the host and its subdomains, the other rules as for a login', () {
      final domains = autofillDomains(
        'Example Co',
        suffixes: bundledSuffixes,
        websites: const ['accounts.larkspur.example', 'larkspur.example', 'example-co.okta.com'],
        rules: const [
          WebsiteRule('accounts.larkspur.example'),
          WebsiteRule('shop.example.co.uk', match: WebsiteMatch.baseDomain),
          WebsiteRule('example-co.okta.com', match: WebsiteMatch.host),
          WebsiteRule('wiki.example.co', match: WebsiteMatch.never),
        ],
      );

      expect(domains, ['accounts.larkspur.example', 'example.co.uk', '=example-co.okta.com']);
    });

    test('without rules, the websites as typed, as before', () {
      final domains = autofillDomains(
        'Example Co',
        suffixes: bundledSuffixes,
        websites: const ['accounts.larkspur.example', 'acme.okta.com'],
      );

      expect(domains, ['accounts.larkspur.example', '=acme.okta.com']);
    });

    test('the autofill copy keeps version 1, and holds the domains each rule maps onto', () {
      final account = _account('Example Co', const [
        WebsiteRule('example-co.okta.com', match: WebsiteMatch.host),
        WebsiteRule('^https://example\\.co/', match: WebsiteMatch.regularExpression),
      ]);

      final copy = autofillCopy('v', [autofillEntry(account, suffixes: bundledSuffixes)!]);

      expect(copy['v'], 1);
      expect(autofillFormatVersion, 1);
      expect(((copy['accounts']! as List<Object?>).single! as Map<String, Object?>)['domains'], contains('=example-co.okta.com'));
    });
  });

  group('a Never website does not link a code (task 6.4)', () {
    test('a code whose only website is on Never is not offered to a new login for that website', () {
      final code = _account('Example Co', const [WebsiteRule('example.co', match: WebsiteMatch.never)]);

      expect(offeredAccount('', ['example.co'], [code], suffixes: bundledSuffixes), isNull);
    });

    test('nor is a code offered for a login website that is on Never', () {
      final code = _account('Example Co', const [WebsiteRule('example.co')]);

      expect(offeredAccount('', ['example.co'], [code], suffixes: bundledSuffixes), code, reason: 'its host links it');
      expect(
        offeredAccount(
          '',
          const [],
          [code],
          suffixes: bundledSuffixes,
          rules: const [WebsiteRule('example.co', match: WebsiteMatch.never)],
        ),
        isNull,
      );
    });

    test('a website on Default links it as before', () {
      final code = _account('Example Co', const [WebsiteRule('example.co')]);

      expect(offeredAccount('', ['shop.example.co'], [code], suffixes: bundledSuffixes), code);
    });
  });
}
