import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/service_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServiceIcons catalog;
  String? titleFor(String name) => catalog.iconFor(name)?.title;

  setUpAll(() async {
    catalog = await ServiceIcons.load();
  });

  group('iconFor', () {
    for (final name in [
      'GitHub',
      'github',
      'GITHUB',
      '  GitHub  ',
      'GitHub.com',
      'www.github.com',
      'https://github.com/login',
      'GitHub, Inc.',
      'GitHub Inc',
      'GitHub (work)',
    ]) {
      test('finds GitHub from "$name"', () {
        expect(titleFor(name), 'GitHub');
      });
    }

    for (final (name, title) in [
      ('gmail', 'Google'),
      ('googleaccount', 'Google'),
      ('Google Account', 'Google'),
      ('Google Workspace', 'Google'),
      ('Google LLC', 'Google'),
      ('YouTube', 'Google'),
      ('Twitter', 'X'),
      ('twitter.com', 'X'),
      ('X', 'X'),
      ('x.com', 'X'),
      ('X Corp.', 'X'),
      ('Battle.net', 'Battle.net'),
      ('Blizzard', 'Battle.net'),
      ('Blizzard Entertainment', 'Battle.net'),
      ('Proton', 'Proton'),
      ('Proton AG', 'Proton'),
      ('Proton Pass', 'Proton'),
      ('ProtonMail', 'Proton Mail'),
      ('Proton Mail', 'Proton Mail'),
      ('epicgames', 'Epic Games'),
      ('Epic Games Account', 'Epic Games'),
      ('PlayStation Network', 'PlayStation'),
      ('PSN', 'PlayStation'),
      ('digitalocean', 'DigitalOcean'),
      ('Digital Ocean', 'DigitalOcean'),
      ('Linode', 'Akamai'),
      ('Apple ID', 'Apple'),
      ('iCloud', 'Apple'),
      ('Docker Hub', 'Docker'),
      ('npmjs', 'npm'),
      ('TransferWise', 'Wise'),
      ('Amex', 'American Express'),
      ('Uber Eats', 'Uber'),
      ('Steam Guard', 'Steam'),
      ('Hetzner Online GmbH', 'Hetzner'),
      ('Mi Account', 'Xiaomi'),
      ('Ko-fi', 'Ko-fi'),
      ('kofi', 'Ko-fi'),
    ]) {
      test('maps the issuer "$name" to $title', () {
        expect(titleFor(name), title);
      });
    }

    test('ignores accents', () {
      expect(titleFor('Bitwärden'), 'Bitwarden');
      expect(titleFor('Hétzner'), 'Hetzner');
    });

    for (final (name, title) in [
      ('accounts.google.com', 'Google'),
      ('google.co.uk', 'Google'),
      ('eu.battle.net', 'Battle.net'),
      ('mastodon.social', 'Mastodon'),
      ('bsky.social', 'Bluesky'),
      ('proton.me', 'Proton'),
      ('pm.me', 'Proton Mail'),
      ('test.pypi.org', 'PyPI'),
      ('Booking.com', 'Booking.com'),
      ('itch.io', 'Itch.io'),
      ('steampowered.com', 'Steam'),
      ('git.sr.ht', 'SourceHut'),
      ('binance.us', 'Binance'),
    ]) {
      test('reads the domain "$name" as $title', () {
        expect(titleFor(name), title);
      });
    }

    test('takes the issuer from an "Issuer:account" label', () {
      expect(titleFor('Google:alice@gmail.com'), 'Google');
      expect(titleFor('GitHub:alice'), 'GitHub');
      expect(titleFor('Battle.net: alice#1234'), 'Battle.net');
    });

    test('never takes the logo from the account half of a label', () {
      expect(catalog.iconFor('Acme:alice@gmail.com'), isNull);
      expect(catalog.iconFor('alice@gmail.com'), isNull);
    });

    for (final name in [
      'Mygoogleclone',
      'Google Clone',
      'Googl',
      'githubb',
      'notgithub.com',
      'github.evil.com',
      'evil-github.com',
      'Steamy',
      'Battle',
      'Acme Corp',
      'My Bank',
      'Inc.',
      'account',
      '.com',
      '',
      '   ',
    ]) {
      test('has no logo for the unknown or lookalike name "$name"', () {
        expect(catalog.iconFor(name), isNull);
      });
    }

    for (final name in [
      'Microsoft',
      'Microsoft account',
      'Outlook',
      'Hotmail',
      'Xbox',
      'Azure',
      'AWS',
      'Amazon Web Services',
      'Amazon',
      'LinkedIn',
      'Slack',
      'Yahoo',
      'Heroku',
      'Twilio',
      'Nintendo Account',
      'Kraken',
      'Crypto.com',
      'cryptocom',
    ]) {
      test('has no logo for "$name", which simple-icons does not ship', () {
        expect(catalog.iconFor(name), isNull);
      });
    }

    test('the asset carries only the title, colour, path and names of each logo', () async {
      final json = jsonDecode(await rootBundle.loadString(ServiceIcons.asset)) as Map<String, Object?>;
      expect(json['license'], contains('CC0'));
      for (final row in (json['icons']! as List<Object?>).cast<Map<String, Object?>>()) {
        expect(row.keys.toList()..sort(), ['hex', 'names', 'path', 'title']);
      }
    });
  });

  group('the bundled logos', () {
    test('are a curated set, not the whole icon pack', () {
      expect(catalog.rows.length, greaterThanOrEqualTo(150));
      expect(catalog.rows.length, lessThanOrEqualTo(250));
    });

    test('have one row per brand', () {
      final titles = [for (final row in catalog.rows) row.icon.title];
      expect(titles.toSet(), hasLength(titles.length));
    });

    test('each have a path, a colour and names that all lead back to them', () {
      for (final (:icon, :names) in catalog.rows) {
        expect(icon.path, matches(RegExp(r'^[Mm][\d.\s,-]')), reason: icon.title);
        expect(icon.path, isNot(matches(RegExp('["<>&]'))), reason: icon.title);
        expect(icon.hex, matches(RegExp(r'^[0-9A-Fa-f]{6}$')), reason: icon.title);
        expect(names.first, icon.title);
        for (final name in names) {
          expect(catalog.iconFor(name), same(icon), reason: '${icon.title}: $name');
        }
      }
    });

    test('load once and share the result', () async {
      expect(await ServiceIcons.load(), same(catalog));
    });

    test('wrap a path in a 24×24 SVG document', () {
      const icon = ServiceIcon(title: 'T', hex: '000000', path: 'M0 0h24v24H0z');
      expect(
        icon.svg(fill: '#0A0B0D'),
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#0A0B0D"/></svg>',
      );
    });
  });

  group('isLightBrand', () {
    for (final (hex, light) in [
      ('FFFC00', true), // Snapchat yellow
      ('FFFFFF', true),
      ('FFE01B', true), // Mailchimp
      ('F0B90B', true), // Binance
      ('FFB3C7', true), // Klarna
      ('181717', false), // GitHub
      ('000000', false),
      ('FF4500', false), // Reddit
      ('25D366', false), // WhatsApp
      ('5865F2', false), // Discord
    ]) {
      test('$hex → $light', () {
        expect(isLightBrand(hex), light);
      });
    }

    test('tolerates a leading #', () {
      expect(isLightBrand('#FFFC00'), isTrue);
    });

    test('agrees with the bundled Snapchat and GitHub colours', () {
      expect(isLightBrand(catalog.iconFor('Snapchat')?.hex ?? ''), isTrue);
      expect(isLightBrand(catalog.iconFor('GitHub')?.hex ?? ''), isFalse);
    });
  });
}
