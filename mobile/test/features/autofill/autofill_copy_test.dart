import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/public_suffixes.dart';
import 'package:kemlock/features/accounts/otp.dart';
import 'package:kemlock/features/autofill/autofill_copy.dart';
import 'package:kemlock/features/backup/two_factor_directory.dart';
import 'package:kemlock/models/otp_account.dart';

typedef Json = Map<String, Object?>;

OtpAccount account({
  String id = 'a1',
  OtpType? type,
  String issuer = 'GitHub',
  String label = 'alice@example.com',
  String secret = 'JBSWY3DPEHPK3PXP',
  String algorithm = 'SHA1',
  int digits = 6,
  int period = 30,
}) => OtpAccount(
  id: id,
  type: type,
  issuer: issuer,
  label: label,
  secret: secret,
  algorithm: algorithm,
  digits: digits,
  period: period,
  addedAt: 0,
);

void main() {
  final directory = TwoFactorDirectory.fromJson(jsonDecode(File('assets/data/two_factor_directory.json').readAsStringSync()) as Json);
  final suffixes = PublicSuffixList.parse(File(publicSuffixListAsset).readAsStringSync());

  group('autofillEntry', () {
    test('takes a TOTP account with its decoded secret', () {
      final entry = autofillEntry(account(), directory: directory)!;
      expect(entry.toJson(), {
        'id': 'a1',
        'issuer': 'GitHub',
        'label': 'alice@example.com',
        'kind': 'totp',
        'algorithm': 'SHA1',
        'digits': 6,
        'period': 30,
        'key': base64.encode(base32Decode('JBSWY3DPEHPK3PXP')),
        'domains': ['github.com'],
      });
    });

    test('reads accounts saved before HOTP and Steam as TOTP', () {
      expect(autofillEntry(account())!.kind, OtpType.totp);
      expect(autofillEntry(account(type: OtpType.totp))!.kind, OtpType.totp);
    });

    test('fills Steam codes as five characters of SHA-1, whatever the account says', () {
      final entry = autofillEntry(account(type: OtpType.steam, issuer: 'Steam', algorithm: 'SHA512', digits: 8))!;
      expect((entry.kind, entry.algorithm, entry.digits), (OtpType.steam, 'SHA1', 5));
    });

    test('names the algorithm as the Swift and Kotlin code know it', () {
      expect(autofillEntry(account(algorithm: 'sha-256'))!.algorithm, 'SHA256');
      expect(autofillEntry(account(algorithm: 'SHA2-512'))!.algorithm, 'SHA512');
      expect(autofillEntry(account(algorithm: 'SSL3-SHA1'))!.algorithm, 'SHA1');
    });

    test('leaves out HOTP, whose counter only the vault can move on', () {
      expect(autofillEntry(account(type: OtpType.hotp)), isNull);
    });

    test('leaves out accounts that make no code, or none the phone would make the same way', () {
      expect(autofillEntry(account(secret: 'not base32!')), isNull, reason: 'secret');
      expect(autofillEntry(account(secret: '')), isNull, reason: 'empty secret');
      expect(autofillEntry(account(algorithm: 'MD5')), isNull, reason: 'algorithm');
      expect(autofillEntry(account(algorithm: 'SHA3-256')), isNull, reason: 'SHA-3, which the app has no hash for');
      expect(autofillEntry(account(digits: 0)), isNull, reason: 'no digits');
      expect(autofillEntry(account(digits: 11)), isNull, reason: 'too many digits');
      expect(autofillEntry(account(period: 0)), isNull, reason: 'a code that never changes');
      expect(autofillEntry(account(period: -30)), isNull, reason: 'negative period');
      expect(autofillEntry(account(digits: 10)), isNotNull);
    });

    test('keeps no label or secret in the index', () {
      expect(autofillEntry(account(), directory: directory)!.toIndexJson(), {
        'id': 'a1',
        'issuer': 'GitHub',
        'domains': ['github.com'],
      });
    });
  });

  test('an account’s websites are among the domains its entry is filled on', () {
    final nextcloud = account(issuer: 'Nextcloud').copyWith(websites: ['cloud.example.org']);
    expect(autofillEntry(nextcloud, directory: directory)!.domains, ['cloud.example.org']);
  });

  group('autofillDomains', () {
    test('finds the service in the 2FA directory', () {
      expect(autofillDomains('GitHub, Inc.', directory: directory), ['github.com']);
      expect(autofillDomains('Google', directory: directory, suffixes: suffixes), ['google.com']);
    });

    test('takes an issuer that is a domain or a URL, without www', () {
      expect(autofillDomains('example.org'), ['example.org']);
      expect(autofillDomains('https://www.Example.org/login?next=1'), ['example.org']);
      expect(autofillDomains('https://sso.example.org:8443/'), ['sso.example.org']);
    });

    test('adds the directory domain after the issuer’s own, once', () {
      expect(autofillDomains('github.com', directory: directory), ['github.com']);
      expect(autofillDomains('gist.github.com', directory: directory), ['gist.github.com', 'github.com']);
    });

    test('takes the domain a directory entry’s subdomain is under', () {
      // The directory names mail.google.com and store.steampowered.com; their sign-in pages are elsewhere.
      expect(autofillDomains('Gmail', directory: directory, suffixes: suffixes), ['google.com']);
      expect(autofillDomains('Steam', directory: directory, suffixes: suffixes), ['steampowered.com']);
    });

    test('without the Public Suffix List, keeps a directory entry’s host as it is', () {
      expect(autofillDomains('Gmail', directory: directory), ['mail.google.com']);
      expect(autofillDomains('Steam', directory: directory), ['store.steampowered.com']);
    });

    test('marks hosts anyone can open a tenant under as exact only', () {
      expect(autofillDomains('Okta', directory: directory), ['=okta.com']);
      expect(autofillDomains('acme.okta.com', directory: directory), ['=acme.okta.com', '=okta.com']);
      expect(autofillDomains('https://me.github.io'), ['=me.github.io']);
    });

    test('adds the websites given to the account, as they are, after the others', () {
      expect(autofillDomains('Nextcloud', directory: directory, websites: ['cloud.example.org']), ['cloud.example.org']);
      expect(autofillDomains('GitHub', directory: directory, websites: ['github.com', 'git.example.org']), [
        'github.com',
        'git.example.org',
      ]);
      expect(autofillDomains('Acme SSO', websites: ['acme.okta.com']), ['=acme.okta.com']);
    });

    test('finds nothing for a name that is neither a domain nor in the directory', () {
      expect(autofillDomains('My bank', directory: directory), isEmpty);
      expect(autofillDomains(''), isEmpty);
      expect(autofillDomains('localhost'), isEmpty);
      expect(autofillDomains('10.0.0.1'), isEmpty);
      expect(autofillDomains('alice@example.com'), isEmpty);
    });
  });

  group('registrableDomain without the Public Suffix List', () {
    test('keeps the host as it is, so a tenant’s host never takes in its neighbours', () {
      // alice.duckdns.org and bob.duckdns.org are two people's sites; their last two labels, one
      for (final host in ['alice.duckdns.org', 'mail.google.com', 'mobile.everyday.com.au', 'google.com', 'impots.gouv.fr']) {
        expect(registrableDomain(host), host, reason: host);
      }
    });
  });

  group('registrableDomain with the Public Suffix List', () {
    test('drops the subdomains', () {
      expect(registrableDomain('mail.google.com', suffixes: suffixes), 'google.com');
      expect(registrableDomain('google.com', suffixes: suffixes), 'google.com');
      expect(registrableDomain('mobile.everyday.com.au', suffixes: suffixes), 'everyday.com.au');
      expect(registrableDomain('commercial.metrobankonline.co.uk', suffixes: suffixes), 'metrobankonline.co.uk');
      expect(registrableDomain('store.steampowered.com', suffixes: suffixes), 'steampowered.com');
    });

    test('keeps government hosts, whose parents belong to many services', () {
      for (final host in ['impots.gouv.fr', 'access.service.gov.uk', 'realme.govt.nz', 'my.ny.gov', 'atlas-myrmv.massdot.state.ma.us']) {
        expect(registrableDomain(host, suffixes: suffixes), host, reason: host);
      }
    });

    test('keeps a site under a suffix anyone can open a site under as its own', () {
      expect(registrableDomain('alice.herokuapp.com', suffixes: suffixes), 'alice.herokuapp.com');
      expect(registrableDomain('docs.user.github.io', suffixes: suffixes), 'user.github.io');
      expect(registrableDomain('shop.example.co.jp', suffixes: suffixes), 'example.co.jp');
    });

    test('marks a directory entry under a shared host as exact', () {
      expect(autofillDomains('https://me.github.io', suffixes: suffixes), ['=me.github.io']);
    });
  });

  group('autofillCopy and autofillIndex', () {
    final accounts = [
      account(),
      account(id: 'h1', type: OtpType.hotp, issuer: 'Counter'),
      account(id: 's1', type: OtpType.steam, issuer: 'Steam', label: 'gaben'),
    ];

    test('hold the fillable accounts in the vault’s order, with the format version', () {
      final entries = autofillEntries(accounts, directory: directory, suffixes: suffixes);
      final copy = autofillCopy('v1', entries);
      expect(copy['v'], autofillFormatVersion);
      expect(copy['vault'], 'v1');
      expect([for (final a in copy['accounts']! as List<Object?>) (a! as Json)['id']], ['a1', 's1']);
      final index = autofillIndex('v1', entries);
      expect(index, {
        'v': autofillFormatVersion,
        'vault': 'v1',
        'accounts': [
          {
            'id': 'a1',
            'issuer': 'GitHub',
            'domains': ['github.com'],
          },
          {
            'id': 's1',
            'issuer': 'Steam',
            'domains': ['steampowered.com'],
          },
        ],
      });
    });

    test('make JSON that survives a round trip', () {
      final copy = autofillCopy('v1', autofillEntries(accounts, directory: directory, suffixes: suffixes));
      expect(jsonDecode(jsonEncode(copy)), copy);
    });
  });
}
