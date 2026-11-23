// Which sites a login belongs to, as AutoFill and the app read them
// (openspec: add-passwords, design decision 3).
import 'package:collection/collection.dart';

import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../models/login.dart';
import '../../models/otp_account.dart';
import '../../models/website_rule.dart';
import '../accounts/service_names.dart';
import '../autofill/autofill_copy.dart';
import '../backup/coverage.dart';
import '../backup/two_factor_directory.dart';

final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

/// Whether [domain] is filled on [host]: the domain itself or a host under
/// it, compared label by label, so `larkspur.example` fills on
/// `mail.larkspur.example` and not on `evillarkspur.example`. A domain
/// written with a leading `=` fills only on that very host, as the Kotlin and
/// Swift readers match.
bool hostMatches(String host, String domain) {
  var h = host.toLowerCase().trim();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.isEmpty) return false;
  if (domain.startsWith('=')) return h == domain.substring(1);
  return h == domain || h.endsWith('.$domain');
}

/// The domains [login] is filled on: the registrable domain of each of its
/// websites, by the Public Suffix List ([suffixes]), so a login saved on
/// `accounts.larkspur.example` fills on `mail.larkspur.example`; a host
/// anyone can open a tenant under, or an address, only on itself (`=`).
/// Without the list, each website as it is (see [registrableDomain]).
List<String> loginDomains(Login login, {PublicSuffixList? suffixes}) {
  // Websites with rules: each rule says how its host fills on phones
  final rules = login.uris;
  if (rules != null) {
    return phoneDomains(
      rules,
      WebsiteKind.login,
      registrable: (host) => registrableDomain(host, suffixes: suffixes),
      isShared: isSharedHost,
    );
  }
  final domains = <String>[];
  for (final website in login.websites ?? const <String>[]) {
    final exact = _ipv4.hasMatch(website) || sharedHosts.any((shared) => website == shared || website.endsWith('.$shared'));
    final domain = exact ? '=$website' : registrableDomain(website, suffixes: suffixes);
    if (!domains.contains(domain)) domains.add(domain);
  }
  return domains;
}

/// The account of [accounts] a login named [name] with [websites] is offered
/// as its code: the first whose domains fill on one of the websites, else
/// the first whose service has the same name; null for none.
OtpAccount? offeredAccount(
  String name,
  List<String> websites,
  List<OtpAccount> accounts, {
  TwoFactorDirectory? directory,
  PublicSuffixList? suffixes,
  List<WebsiteRule>? rules,
}) {
  // A login's websites with rules: those on Never, Regular expression or a rule
  // this version doesn't know give no host, so they link no code
  if (rules != null) websites = fillHosts(rules);
  for (final account in accounts) {
    final domains = autofillDomains(
      account.issuer,
      directory: directory,
      suffixes: suffixes,
      websites: account.websites ?? const [],
      rules: account.uris,
    );
    if (websites.any((website) => domains.any((domain) => hostMatches(website, domain)))) return account;
  }
  if (name.trim().isEmpty) return null;
  return accounts.firstWhereOrNull((account) => sameService(serviceOf(account), name));
}
