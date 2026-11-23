import AuthenticationServices
import Foundation

/// Which accounts belong to the website asking for a code. Hosts are
/// compared label by label, never by substring: `github.com` fills on
/// `gist.github.com`, not on `github.com.evil.io` or `evilgithub.com`.
enum HostMatch {
  /// [host] lowercased, without a trailing dot.
  static func normalize(_ host: String) -> String {
    var h = host.lowercased().trimmingCharacters(in: .whitespaces)
    if h.hasSuffix(".") { h.removeLast() }
    return h
  }

  /// Whether an account with [domain] is filled on [host]. A domain starting
  /// with `=` only matches that very host, for hosts anyone can open a tenant under.
  static func matches(host: String, domain: String) -> Bool {
    let h = normalize(host)
    guard !h.isEmpty else { return false }
    if domain.hasPrefix("=") { return h == normalize(String(domain.dropFirst())) }
    let d = normalize(domain)
    guard !d.isEmpty else { return false }
    return h == d || h.hasSuffix("." + d)
  }

  static func matches(host: String, domains: [String]) -> Bool {
    domains.contains { matches(host: host, domain: $0) }
  }

  /// The hosts iOS asks for, most specific first: a domain as it is, a URL as its host. A page
  /// not reached over https gives none: anyone on the network can serve it under the site's name.
  static func hosts(of identifiers: [ASCredentialServiceIdentifier]) -> [String] {
    var hosts: [String] = []
    for identifier in identifiers {
      let host: String?
      switch identifier.type {
      case .URL:
        let url = URL(string: identifier.identifier)
        host = url?.scheme?.lowercased() == "https" ? url?.host : nil
      default: host = identifier.identifier
      }
      if let host, !host.isEmpty, !hosts.contains(normalize(host)) { hosts.append(normalize(host)) }
    }
    return hosts
  }

  /// The websites iOS asks for, as [hosts] gives them, from its domains and
  /// URLs alone: an app that names no website gives none, so its bundle id is
  /// never matched as a host.
  static func websites(of identifiers: [ASCredentialServiceIdentifier]) -> [String] {
    hosts(of: identifiers.filter { $0.type == .domain || $0.type == .URL })
  }
}
