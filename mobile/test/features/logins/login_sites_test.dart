import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/two_factor_directory.dart';
import 'package:kemlock/features/logins/login_sites.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/models/otp_account.dart';

import '../../helpers/test_app.dart';

Login _login(List<String> websites) => Login(id: 'l', name: 'L', password: 'p', websites: websites, addedAt: 0);

void main() {
  final directory = TwoFactorDirectory.fromJson(
    jsonDecode(File('assets/data/two_factor_directory.json').readAsStringSync()) as Map<String, Object?>,
  );

  test('a host matches its domain and the hosts under it, label by label', () {
    expect(hostMatches('larkspur.example', 'larkspur.example'), isTrue);
    expect(hostMatches('Mail.Larkspur.example.', 'larkspur.example'), isTrue);
    expect(hostMatches('larkspur.example.evil.test', 'larkspur.example'), isFalse);
    expect(hostMatches('evillarkspur.example', 'larkspur.example'), isFalse);
    expect(hostMatches('acme.okta.com', '=acme.okta.com'), isTrue);
    expect(hostMatches('x.acme.okta.com', '=acme.okta.com'), isFalse);
    expect(hostMatches('', 'larkspur.example'), isFalse);
  });

  test('a login fills on the domain each of its websites is under', () {
    expect(loginDomains(_login(['accounts.larkspur.example', 'larkspur.example']), suffixes: bundledSuffixes), ['larkspur.example']);
    expect(loginDomains(_login(['shop.example.co.uk']), suffixes: bundledSuffixes), ['example.co.uk']);
  });

  test('a login on a host anyone can open a site under fills only there', () {
    // Under a suffix of the list only: its own site; on AutoFill's list of tenant hosts too: that host alone
    expect(loginDomains(_login(['www.alice.duckdns.org']), suffixes: bundledSuffixes), ['alice.duckdns.org']);
    expect(loginDomains(_login(['alice.herokuapp.com']), suffixes: bundledSuffixes), ['=alice.herokuapp.com']);
    expect(loginDomains(_login(['acme.okta.com']), suffixes: bundledSuffixes), ['=acme.okta.com']);
    expect(loginDomains(_login(['192.168.1.1']), suffixes: bundledSuffixes), ['=192.168.1.1']);
  });

  test('without the Public Suffix List, a login fills on its own host, never on a neighbour’s', () {
    // A tenant's host the list knows and AutoFill's own list of tenant hosts doesn't
    final domains = loginDomains(_login(['alice.duckdns.org', 'accounts.larkspur.example']));

    expect(domains, ['alice.duckdns.org', 'accounts.larkspur.example']);
    expect(domains.any((domain) => hostMatches('bob.duckdns.org', domain)), isFalse);
    expect(domains.any((domain) => hostMatches('www.alice.duckdns.org', domain)), isTrue);
  });

  test('offers the account whose site or service is the login’s', () {
    const github = OtpAccount(id: 'g', issuer: 'GitHub', label: 'octocat', secret: 'S', addedAt: 0);
    const nextcloud = OtpAccount(id: 'n', issuer: 'Cloud', label: 'ada', secret: 'S', addedAt: 0, websites: ['cloud.example.org']);
    final accounts = [github, nextcloud];

    expect(offeredAccount('', ['gist.github.com'], accounts, directory: directory)?.id, 'g');
    expect(offeredAccount('Nextcloud', ['files.cloud.example.org'], accounts, directory: directory)?.id, 'n');
    expect(offeredAccount('GitHub', const [], accounts, directory: directory)?.id, 'g');
    expect(offeredAccount('Larkspur', ['larkspur.example'], accounts, directory: directory), isNull);
    expect(offeredAccount('', const [], accounts, directory: directory), isNull);
  });
}
