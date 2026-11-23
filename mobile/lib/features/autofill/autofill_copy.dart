// What the iOS AutoFill extension and the Android autofill service read
// (openspec: add-passwords, the code-autofill spec): the accounts of one vault they can fill, written
// by the app while the vault is open and encrypted on the phone's side of the
// method channel, and an index of names and domains for suggestions shown
// before biometrics. Neither side reads the vault itself.
import 'dart:convert';
import 'dart:typed_data';

import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../models/otp_account.dart';
import '../../models/passkey.dart';
import '../../models/website_rule.dart';
import '../accounts/otp.dart';
import '../backup/two_factor_directory.dart';

/// The version of the copy and the index. The Swift and Kotlin readers
/// refuse any other, and ask for the app to be opened, which writes it again.
const autofillFormatVersion = 1;

/// Domains under which anyone can open a site or a workspace of their own,
/// such as `evil.okta.com` beside `acme.okta.com`. An account matches one of
/// them only on that exact host, so a code isn't offered to another tenant.
/// The readers see them with a leading `=`.
const sharedHosts = {
  'auth0.com',
  'okta.com',
  'onelogin.com',
  'slack.com',
  'wordpress.com',
  'zendesk.com',
  'atlassian.net',
  'github.io',
  'gitlab.io',
  'blogspot.com',
  'herokuapp.com',
  'netlify.app',
  'vercel.app',
  'pages.dev',
  'web.app',
  'firebaseapp.com',
  'appspot.com',
  'azurewebsites.net',
  'myshopify.com',
  'wixsite.com',
};

/// Whether [host] is one of [sharedHosts], or under one.
bool isSharedHost(String host) => sharedHosts.any((shared) => host == shared || host.endsWith('.$shared'));

/// One account the autofill side can fill.
class AutofillEntry {
  const AutofillEntry({
    required this.id,
    required this.issuer,
    required this.label,
    required this.kind,
    required this.algorithm,
    required this.digits,
    required this.period,
    required this.key,
    required this.domains,
  });

  final String id;
  final String issuer;
  final String label;

  /// TOTP or Steam; HOTP accounts are never filled.
  final OtpType kind;

  /// The canonical name, `SHA1`, `SHA224`, `SHA256`, `SHA384` or `SHA512`; `SHA1` for Steam.
  final String algorithm;

  /// 1 to 10; 5 for Steam.
  final int digits;

  /// Seconds per code, above 0.
  final int period;

  /// The secret's bytes, as [base32Decode] reads them.
  final Uint8List key;

  /// The hosts the account is filled on, and their subdomains; one starting
  /// with `=` only on itself (see [sharedHosts]).
  final List<String> domains;

  Map<String, Object?> toJson() => {
    'id': id,
    'issuer': issuer,
    'label': label,
    'kind': kind.name,
    'algorithm': algorithm,
    'digits': digits,
    'period': period,
    'key': base64.encode(key),
    'domains': domains,
  };

  /// What the index keeps of it: no label, which is often an email address, and no secret.
  Map<String, Object?> toIndexJson() => {'id': id, 'issuer': issuer, 'domains': domains};
}

/// [account] as the autofill side fills it, or null when it can't be filled:
/// an HOTP account, whose counter only the vault can move on, or one whose
/// secret, algorithm, digits or period make no code the Swift and Kotlin
/// code would make the same way. [linkedDomains] are those of the logins
/// linked to the account, already worked out, so its code is offered on the
/// page after their password.
AutofillEntry? autofillEntry(
  OtpAccount account, {
  TwoFactorDirectory? directory,
  PublicSuffixList? suffixes,
  List<String> linkedDomains = const [],
}) {
  if (account.kind == OtpType.hotp) return null;
  final Uint8List key;
  try {
    key = base32Decode(account.secret);
  } on FormatException {
    return null;
  }
  if (key.isEmpty || account.period <= 0) return null;
  final steam = account.kind == OtpType.steam;
  final algorithm = steam ? 'SHA1' : canonicalAlgorithm(account.algorithm);
  if (algorithm == null || algorithm.startsWith('SHA3')) return null;
  if (!steam && (account.digits < 1 || account.digits > 10)) return null;
  return AutofillEntry(
    id: account.id,
    issuer: account.issuer,
    label: account.label,
    kind: account.kind,
    algorithm: algorithm,
    digits: steam ? 5 : account.digits,
    period: account.period,
    key: key,
    domains: {
      ...autofillDomains(
        account.issuer,
        directory: directory,
        suffixes: suffixes,
        websites: account.websites ?? const [],
        rules: account.uris,
      ),
      ...linkedDomains,
    }.toList(),
  );
}

final _url = RegExp(r'^[a-z][a-z0-9+.-]*://([^/?#:]*)');
final _domain = RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$');

/// The hosts an account of [issuer] is filled on: the issuer itself when
/// it is a domain or a URL, the domain the 2FA directory's entry for the
/// service is under (see [registrableDomain], which [suffixes] decides), and
/// the [websites] the person gave it, as they are.
/// Hosts in [sharedHosts], and their subdomains, come with a leading `=`.
List<String> autofillDomains(
  String issuer, {
  TwoFactorDirectory? directory,
  PublicSuffixList? suffixes,
  List<String> websites = const [],
  List<WebsiteRule>? rules,
}) {
  final domains = <String>[];
  void add(String host, {bool exact = false}) {
    var h = host.toLowerCase().trim();
    if (h.startsWith('www.')) h = h.substring(4);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (!_domain.hasMatch(h)) return;
    final shared = sharedHosts.any((s) => h == s || h.endsWith('.$s'));
    final entry = shared || exact ? '=$h' : h;
    if (!domains.contains(entry)) domains.add(entry);
  }

  final name = issuer.trim().toLowerCase();
  final url = _url.firstMatch(name);
  if (url != null) {
    add(url[1]!);
  } else if (_domain.hasMatch(name)) {
    add(name);
  }
  if (name.isNotEmpty && directory != null) {
    final entry = directory.findService(issuer);
    if (entry != null) add(registrableDomain(entry.domain, suffixes: suffixes));
  }
  if (rules == null) {
    websites.forEach(add);
  } else {
    // The websites with their rules: each rule says how its host fills on phones
    for (final domain in phoneDomains(
      rules,
      WebsiteKind.account,
      registrable: (host) => registrableDomain(host, suffixes: suffixes),
      isShared: isSharedHost,
    )) {
      add(domain.startsWith('=') ? domain.substring(1) : domain, exact: domain.startsWith('='));
    }
  }
  return domains;
}

// Labels of government domains, which share their suffix between services and often are public suffixes
// themselves (service.gov.uk, nsw.gov.au, state.ma.us).
const _governmentLabels = {'gov', 'gouv', 'govt', 'gob', 'gv', 'go', 'state', 'admin', 'mil'};

/// The domain an organisation owns [host] under, for a 2FA directory entry
/// that names a subdomain: `mail.google.com` is filled on `accounts.google.com`
/// too, so the account gets `google.com`. A government host stays as it is,
/// since its parent belongs to many services. The Public Suffix List
/// ([suffixes]) decides the rest: a host under a suffix anyone can open a
/// site under (`alice.herokuapp.com`) is its own. Without the list, [host]
/// stays as it is, filled on itself and the hosts under it: guessed from
/// its last labels, a tenant's host the list knows and [sharedHosts]
/// doesn't (`alice.duckdns.org`) would be taken for its provider's, and
/// filled on every other tenant's.
String registrableDomain(String host, {PublicSuffixList? suffixes}) {
  final labels = host.split('.');
  if (suffixes == null || labels.length <= 2 || labels.skip(1).any(_governmentLabels.contains)) return host;
  return suffixes.registrableDomain(host) ?? host;
}

/// The vault's autofill copy: the [entries] its accounts gave, and its
/// [passkeys] while passkeys are on, with their keys. A copy without
/// `passkeys`, as every one before them, holds none; the version stays.
Map<String, Object?> autofillCopy(
  String vaultId,
  List<AutofillEntry> entries, {
  List<Passkey> passkeys = const [],
  List<AutofillLogin> logins = const [],
}) => {
  'v': autofillFormatVersion,
  'vault': vaultId,
  'accounts': [for (final entry in entries) entry.toJson()],
  if (passkeys.isNotEmpty) 'passkeys': [for (final passkey in passkeys) autofillPasskey(passkey, withKey: true)],
  if (logins.isNotEmpty) 'logins': [for (final login in logins) login.toJson()],
};

/// The vault's index, for suggestions shown before biometrics: ids, issuers
/// and domains, each passkey's site and account, never its key, and each
/// login's name, username and domains, never its password.
Map<String, Object?> autofillIndex(
  String vaultId,
  List<AutofillEntry> entries, {
  List<Passkey> passkeys = const [],
  List<AutofillLogin> logins = const [],
}) => {
  'v': autofillFormatVersion,
  'vault': vaultId,
  'accounts': [for (final entry in entries) entry.toIndexJson()],
  if (passkeys.isNotEmpty) 'passkeys': [for (final passkey in passkeys) autofillPasskey(passkey, withKey: false)],
  if (logins.isNotEmpty) 'logins': [for (final login in logins) login.toIndexJson()],
};

/// A login as the autofill side fills it (openspec: password-autofill): its
/// id, name, username and password, and the [domains] it is filled on, as
/// `loginDomains` works them out. A copy without `logins`, as every one
/// before them, holds none; the version stays.
class AutofillLogin {
  const AutofillLogin({required this.id, required this.name, this.username, this.password, required this.domains});

  final String id;
  final String name;
  final String? username;
  final String? password;
  final List<String> domains;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'username': ?username, 'password': ?password, 'domains': domains};

  /// What the index keeps of it: never the password.
  Map<String, Object?> toIndexJson() => {'id': id, 'name': name, 'username': ?username, 'domains': domains};
}

/// [passkey] as the provider reads it; its key only in the copy.
Map<String, Object?> autofillPasskey(Passkey passkey, {required bool withKey}) => {
  'credentialId': passkey.credentialId,
  'rpId': passkey.rpId,
  'rpName': ?passkey.rpName,
  'userHandle': passkey.userHandle,
  'userName': passkey.userName,
  'userDisplayName': ?passkey.userDisplayName,
  if (withKey) 'privateKey': passkey.privateKey,
};

/// The entries of [accounts] the autofill side can fill, in the vault's order.
List<AutofillEntry> autofillEntries(
  List<OtpAccount> accounts, {
  TwoFactorDirectory? directory,
  PublicSuffixList? suffixes,
  Map<String, List<String>> linkedDomains = const {},
}) => [
  for (final account in accounts)
    ?autofillEntry(account, directory: directory, suffixes: suffixes, linkedDomains: linkedDomains[account.id] ?? const []),
];
