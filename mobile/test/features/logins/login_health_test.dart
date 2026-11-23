import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/backup/two_factor_directory.dart';
import 'package:kemlock/features/generator/generator.dart';
import 'package:kemlock/features/logins/login_health.dart';
import 'package:kemlock/models/login.dart';

import '../../helpers/test_app.dart' show bundledSuffixes;

Login _login(String id, String? password, {List<String>? websites, String? accountId, bool? codeWarning, String? spaceId}) => Login(
  id: id,
  name: 'Login $id',
  password: password,
  websites: websites,
  accountId: accountId,
  codeWarning: codeWarning,
  spaceId: spaceId,
  addedAt: 0,
);

final _directory = TwoFactorDirectory.fromJson({
  'entries': [
    ['GitHub', 'github.com', 'https://docs.github.com/2fa', 0],
    ['Proton', 'proton.me', 0, 0],
  ],
});

// openspec: add-passwords, task 8.1
void main() {
  const strong = 'kT9#vq2L-wPz8!mR4x';

  group('reused', () {
    test('marks every login sharing a password, and names the others', () {
      final health = loginHealth([_login('a', strong), _login('b', strong), _login('c', strong), _login('d', 'Other#Pass9word')]);

      expect(health.idsWith(LoginWarning.reused), ['a', 'b', 'c']);
      expect(health.reusedWith('a'), ['b', 'c']);
      expect(health.reusedWith('d'), isEmpty);
      expect(health.count(LoginWarning.reused), 3);
    });

    test('counts the logins of the vault’s spaces with its own', () {
      final health = loginHealth([_login('mine', strong), _login('shared', strong, spaceId: 'fam')]);

      expect(health.idsWith(LoginWarning.reused), ['mine', 'shared']);
    });

    test('is gone once one of them changes', () {
      expect(loginHealth([_login('a', strong), _login('b', '$strong!')]).count(LoginWarning.reused), 0);
    });

    test('never counts logins without a password', () {
      expect(loginHealth([_login('a', null), _login('b', null), _login('c', '')]).isEmpty, isTrue);
    });
  });

  group('weak', () {
    test('is below "strong" on the setup screen’s meter', () {
      expect(isWeakPassword('summer2024'), isTrue, reason: 'fair: small letters and digits');
      expect(isWeakPassword('password'), isTrue);
      expect(isWeakPassword('Summer2024ab'), isFalse, reason: 'four of the five checks, length among them');
      // Under twelve characters the meter says no more than fair, whatever else a password has
      expect(isWeakPassword('Summer2024!'), isTrue, reason: 'four of the five checks, but eleven characters');
      expect(isWeakPassword(r'P@ssw0rd'), isTrue, reason: 'every kind of character, but eight characters');
      expect(loginHealth([_login('a', 'summer2024')]).of('a'), {LoginWarning.weak});
    });

    test('never is a password the generator made with its defaults', () {
      for (var i = 0; i < 20; i++) {
        expect(isWeakPassword(generatePassword(SecureByteSource(), const PasswordChoices())), isFalse);
      }
    });
  });

  group('without its code', () {
    final offering = codeDomains(_directory, suffixes: bundledSuffixes);

    test('is a site the 2FA directory lists, with no code linked', () {
      final health = loginHealth(
        [
          _login('gh', strong, websites: ['gist.github.com']),
          _login('linked', strong, websites: ['github.com'], accountId: 'acc'),
          _login('blog', strong, websites: ['larkspur.example']),
          _login('app', strong),
        ],
        offering: offering,
        suffixes: bundledSuffixes,
      );

      expect(health.idsWith(LoginWarning.noCode), ['gh']);
    });

    test('is not when the person asked not to be warned for the login', () {
      final quiet = _login('gh', strong, websites: ['github.com'], codeWarning: false);

      expect(lacksItsCode(quiet, offering, suffixes: bundledSuffixes), isFalse);
      expect(Login.fromJson(quiet.toJson()).codeWarning, isFalse, reason: 'kept, so it syncs');
    });
  });

  test('counts each kind, and has nothing to say when no login has a warning', () {
    final health = loginHealth(
      [
        _login('a', strong),
        _login('b', strong),
        _login('c', 'summer2024', websites: ['proton.me']),
      ],
      offering: codeDomains(_directory, suffixes: bundledSuffixes),
      breached: {'c'},
      suffixes: bundledSuffixes,
    );

    expect([for (final warning in LoginWarning.values) health.count(warning)], [2, 1, 1, 1]);
    expect(loginHealth([_login('a', strong)]).isEmpty, isTrue);
  });
}
