// What the website editor says about a rule: where it fills in the browser and
// on phones, why a shared host fills on itself only, and what older versions of
// Kemlock make of it (the add-cards-identities-and-websites plan, design
// decision 8). The words are the copy's `websiteRules.*` messages, so the
// functions take the translator and have no Flutter import.
import '../../core/public_suffixes.dart';
import '../../core/website_rules.dart';
import '../../models/website_rule.dart';
import 'autofill_copy.dart';

/// The copy in the app's language: `context.t` and `Messages.t`.
typedef Translate = String Function(String id, [Map<String, Object?> args]);

final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

/// Whether [host] is an address, or under a host anyone can open a site under:
/// it fills on itself only, whatever the rule.
bool fillsOnItself(String host) => _ipv4.hasMatch(host) || isSharedHost(host);

String _registrable(String host, PublicSuffixList? suffixes) => registrableDomain(host, suffixes: suffixes);

/// The phrase for a domain of the autofill copy: `=host` is that host alone, and a
/// plain domain is it and the hosts under it.
String _domain(Translate t, String domain) =>
    domain.startsWith('=') ? t('websiteRules.where.only', {'host': domain.substring(1)}) : t('websiteRules.where.under', {'host': domain});

/// Where phones fill [rules], as the hosts the autofill copy holds for them.
List<String> phoneHosts(List<WebsiteRule> rules, WebsiteKind kind, {PublicSuffixList? suffixes}) =>
    phoneDomains(rules, kind, registrable: (host) => _registrable(host, suffixes), isShared: isSharedHost);

/// Where the browser fills [rule]: the whole address it is saved with, as `fillsOn` answers.
String browserWhere(Translate t, WebsiteRule rule, {PublicSuffixList? suffixes}) {
  switch (rule.match) {
    case null || WebsiteMatch.baseDomain:
      final domains = phoneHosts([WebsiteRule(rule.uri, match: WebsiteMatch.baseDomain)], WebsiteKind.login, suffixes: suffixes);
      return domains.isEmpty ? t('websiteRules.where.nowhere') : _domain(t, domains.first);
    case WebsiteMatch.host:
      return t('websiteRules.where.only', {'host': rule.uri});
    case WebsiteMatch.startsWith:
      return t('websiteRules.where.prefix', {'address': rule.uri});
    case WebsiteMatch.exact:
      return t('websiteRules.where.address', {'address': rule.uri});
    case WebsiteMatch.regularExpression:
      return t('websiteRules.where.pattern');
  }
  return t('websiteRules.where.nowhere');
}

/// Where phones fill [rule] on a [kind] of item.
String phonesWhere(Translate t, WebsiteRule rule, WebsiteKind kind, {PublicSuffixList? suffixes}) {
  final domains = phoneHosts([rule], kind, suffixes: suffixes);
  return domains.isEmpty ? t('websiteRules.where.nowhere') : _domain(t, domains.first);
}

/// The hint under a website's row: "Fills on …" when the browser and phones
/// agree, else "Browser: … Phones: …".
String websiteHint(Translate t, WebsiteRule rule, WebsiteKind kind, {PublicSuffixList? suffixes}) {
  if (!rule.isKnown) return t('websiteRules.hint.unknown');
  final browser = browserWhere(t, rule, suffixes: suffixes);
  final phones = phonesWhere(t, rule, kind, suffixes: suffixes);
  return browser == phones
      ? t('websiteRules.hint.same', {'where': browser})
      : t('websiteRules.hint.both', {'browser': browser, 'phones': phones});
}

/// Why [rule] fills on its host alone, when it is on Default or Base domain and
/// that host is an address or one anyone can open a site under; else null.
String? sharedHostNote(Translate t, WebsiteRule rule) {
  final host = rule.host;
  if (host == null || (rule.match != null && rule.match != WebsiteMatch.baseDomain) || !fillsOnItself(host)) return null;
  return t('websiteRules.shared', {'host': host});
}

/// "AutoFill on phones: …" for all of [rules] together.
String phonesLine(Translate t, List<WebsiteRule> rules, WebsiteKind kind, {PublicSuffixList? suffixes}) {
  final domains = phoneHosts(rules, kind, suffixes: suffixes);
  if (domains.isEmpty) return t('websiteRules.phones.none');
  return t('websiteRules.phones.on', {'domains': domains.map((domain) => _domain(t, domain)).join(', ')});
}

/// The lines of "What other apps see": what older versions of Kemlock fill a
/// Host, Starts with or Exact website on, which is more than the rule says, and
/// that they don't list a website that is on Regular expression, Never or a rule
/// they don't know. Empty when nothing differs.
List<String> otherAppsLines(Translate t, List<WebsiteRule> rules, WebsiteKind kind, {PublicSuffixList? suffixes}) {
  final lines = <String>[];
  for (final rule in rules) {
    final host = rule.host;
    if (host == null) {
      lines.add(t('websiteRules.other.hidden', {'website': rule.uri}));
    } else if (rule.match == WebsiteMatch.host || rule.match == WebsiteMatch.startsWith || rule.match == WebsiteMatch.exact) {
      if (fillsOnItself(host)) continue;
      final domain = kind == WebsiteKind.login ? _registrable(host, suffixes) : host;
      lines.add(t('websiteRules.other.wider', {'host': host, 'domain': domain}));
    }
  }
  return lines;
}
