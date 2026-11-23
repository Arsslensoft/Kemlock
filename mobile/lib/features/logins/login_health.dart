// Which logins put the person at risk (openspec: add-passwords, the
// password-health spec and design decision 6): passwords used twice, weak
// ones, sites that offer codes where no code is linked, and, only while the
// breach check switch is on, passwords seen in breaches. Worked out on the
// phone from the open vault's logins, spaces included, and never stored or
// synced.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/public_suffixes.dart';
import '../../models/json.dart' show unset;
import '../../models/login.dart';
import '../../platform/network.dart';
import '../../vault/vault_controller.dart';
import '../autofill/autofill_copy.dart' show registrableDomain;
import '../backup/two_factor_directory.dart';
import '../breaches/pwned_passwords.dart';
import '../lock/password_strength.dart';
import '../settings/prefs.dart';
import '../spaces/hidden_passwords.dart';
import 'login_sites.dart';

/// What can be wrong with a login.
enum LoginWarning { reused, weak, noCode, breached }

/// The warnings of a vault's logins.
class LoginHealth {
  const LoginHealth(this._warnings, this._sharing);

  static const empty = LoginHealth({}, {});

  final Map<String, Set<LoginWarning>> _warnings;
  final Map<String, List<String>> _sharing;

  /// The warnings of the login [id].
  Set<LoginWarning> of(String id) => _warnings[id] ?? const {};

  /// The other logins whose password is the login [id]'s.
  List<String> reusedWith(String id) => _sharing[id] ?? const [];

  /// How many logins have [warning].
  int count(LoginWarning warning) => _warnings.values.where((warnings) => warnings.contains(warning)).length;

  /// The ids of the logins with [warning], in the vault's order.
  List<String> idsWith(LoginWarning warning) => [
    for (final MapEntry(:key, :value) in _warnings.entries)
      if (value.contains(warning)) key,
  ];

  bool get isEmpty => _warnings.values.every((warnings) => warnings.isEmpty);
}

/// A password the strength meter of the setup screen rates below "strong",
/// so one password gets the same verdict everywhere in the app.
bool isWeakPassword(String password) => strengthLevel(password) < 3;

/// The registrable domains of the services the bundled 2FA directory lists
/// as offering codes.
Set<String> codeDomains(TwoFactorDirectory directory, {PublicSuffixList? suffixes}) => {
  for (final entry in directory.entries)
    if (entry.domain.isNotEmpty) registrableDomain(entry.domain, suffixes: suffixes),
};

/// Whether [login] is for a site of [offering] with no code linked, and the
/// person didn't ask not to be warned.
bool lacksItsCode(Login login, Set<String> offering, {PublicSuffixList? suffixes}) {
  if (login.accountId != null || login.codeWarning == false) return false;
  return loginDomains(
    login,
    suffixes: suffixes,
  ).any((domain) => offering.contains(domain.startsWith('=') ? registrableDomain(domain.substring(1), suffixes: suffixes) : domain));
}

/// The warnings of [logins], every scope of the vault together: a password
/// two logins share, compared by its SHA-256 held only here, a weak one, a
/// site of [offering] with no code, and the logins [breached] names.
LoginHealth loginHealth(
  List<Login> logins, {
  Set<String> offering = const {},
  Set<String> breached = const {},
  PublicSuffixList? suffixes,
}) {
  final byDigest = <String, List<String>>{};
  for (final login in logins) {
    final password = login.password;
    if (password == null || password.isEmpty) continue;
    (byDigest[_digest(password)] ??= []).add(login.id);
  }
  final sharing = <String, List<String>>{
    for (final ids in byDigest.values)
      if (ids.length > 1)
        for (final id in ids)
          id: [
            for (final other in ids)
              if (other != id) other,
          ],
  };
  final warnings = <String, Set<LoginWarning>>{
    for (final login in logins)
      login.id: {
        if (sharing.containsKey(login.id)) LoginWarning.reused,
        if (login.password case final password? when password.isNotEmpty && isWeakPassword(password)) LoginWarning.weak,
        if (lacksItsCode(login, offering, suffixes: suffixes)) LoginWarning.noCode,
        if (breached.contains(login.id)) LoginWarning.breached,
      },
  };
  return LoginHealth(warnings, sharing);
}

String _digest(String password) => sha256.convert(utf8.encode(password)).toString();

/// What Pwned Passwords answered this session, by the SHA-256 of each
/// password asked about, so each is asked once; never stored. A vault opened
/// again asks afresh.
final _leakAnswersProvider = Provider<Map<String, int>>((ref) {
  ref.watch(vaultControllerProvider.select((state) => state.session));
  return {};
});

/// The logins whose password Pwned Passwords knows from a breach, asked
/// while the breach check switch is on and offline mode is off, one request
/// per distinct password a session, each sending five characters of the
/// password's SHA-1 and asking for padding, never the password. Off, or
/// offline, none, and nothing is sent. A password the service couldn't tell
/// of is asked again next time.
final loginBreachesProvider = FutureProvider<Set<String>>((ref) async {
  final on = ref.watch(prefsProvider.select((prefs) => prefs.leakCheck));
  final offline = ref.watch(offlineProvider);
  final logins = ref.watch(vaultControllerProvider.select((state) => state.logins));
  if (!on || offline || logins.isEmpty) return const {};
  final answers = ref.watch(_leakAnswersProvider);
  final pwned = ref.read(pwnedPasswordsProvider);
  final breached = <String>{};
  // A hidden password is never sent, not even as the five characters of its hash, and whether it was breached would tell
  // something about it
  final hidden = ref.watch(hiddenPasswordsProvider);
  for (final login in logins) {
    if (hidden.hides(login)) continue;
    final password = login.password;
    if (password == null || password.isEmpty) continue;
    final digest = _digest(password);
    var count = answers[digest];
    if (count == null) {
      try {
        count = answers[digest] = await pwned.timesLeaked(password);
      } on LeakCheckError {
        continue;
      }
    }
    if (count > 0) breached.add(login.id);
  }
  return breached;
});

/// The open vault's login health, from the bundled 2FA directory and Public
/// Suffix List once they are read, and the breach check's findings.
final loginHealthProvider = Provider<LoginHealth>((ref) {
  final logins = ref.watch(vaultControllerProvider.select((state) => state.logins));
  if (logins.isEmpty) return LoginHealth.empty;
  final suffixes = ref.watch(publicSuffixListProvider).value;
  final directory = ref.watch(twoFactorDirectoryProvider).value;
  final offering = directory == null ? const <String>{} : codeDomains(directory, suffixes: suffixes);
  final breached = ref.watch(loginBreachesProvider).value ?? const <String>{};
  // A hidden password takes no part in "reused" or "weak": that a login shares its password with one the member can
  // read, or how strong it is, would tell what it is
  final hidden = ref.watch(hiddenPasswordsProvider);
  final readable = [for (final login in logins) hidden.hides(login) ? login.copyWith(password: unset) : login];
  return loginHealth(readable, offering: offering, breached: breached, suffixes: suffixes);
});
