import Foundation

// What the AutoFill extension decides for a password request, apart from its screens, so the
// tests reach it (openspec: add-passwords, design decision 11).

/// What the login list shows: the logins for the website first, then every login.
struct LoginListModel {
  let rows: [VaultLogin]
  /// The website asking for a login, if iOS said.
  let host: String?
  /// The rows for [host]: by their domains, or because the person picked them there before.
  let suggested: [VaultLogin]

  /// [logins] of every vault, by name then username; [picked] holds the
  /// records (`<vault>/<login id>`) the person picked for [host] before.
  init(logins: [VaultLogin], host: String?, picked: Set<String>) {
    rows = logins.sorted { a, b in
      let byName = a.login.name.localizedCaseInsensitiveCompare(b.login.name)
      guard byName == .orderedSame else { return byName == .orderedAscending }
      return (a.login.username ?? "").localizedCaseInsensitiveCompare(b.login.username ?? "") == .orderedAscending
    }
    self.host = host
    if let host {
      suggested = rows.filter { picked.contains($0.record) || HostMatch.matches(host: host, domains: $0.login.domains) }
    } else {
      suggested = []
    }
  }

  /// [rows] whose name, username or a domain holds [query], whatever its case; all of them for none.
  static func found(_ rows: [VaultLogin], query: String) -> [VaultLogin] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return rows }
    return rows.filter { row in ([row.login.name, row.login.username ?? ""] + row.login.domains).contains { $0.localizedCaseInsensitiveContains(q) } }
  }

  /// The login a suggestion's [record] names among the opened [copies], with its password.
  static func login(_ record: AutofillRecord, in copies: [AutofillCopy]) -> AutofillLogin? {
    copies.first { $0.vault == record.vault }?.logins.first { $0.id == record.account }
  }
}

/// What the extension answers iOS 26.2's requests to generate and save passwords with, apart from its screens.
enum LoginProvider {
  /// The rules a generate request hands over: the password field's own, else
  /// those Apple keeps for the site (password-manager-resources); nil when
  /// neither says anything, and the defaults are made alone.
  static func rules(field: String?, quirks: String?) -> PasswordRules? {
    for text in [field, quirks].compactMap({ $0 }) {
      let rules = PasswordRules.parse(text)
      if !rules.isEmpty { return rules }
    }
    return nil
  }

  /// A strong password for a generate request: the defaults, held to [rules], from [source].
  static func strongPassword(rules: PasswordRules?, source: ByteSource = SecureByteSource()) throws -> String {
    try generatePassword(source, PasswordChoices(), rules: rules)
  }

  /// Whether [password] holds letters and digits alone, as a site that refuses symbols makes it,
  /// which iOS names "alphanumeric" rather than "strong".
  static func isAlphanumeric(_ password: String) -> Bool {
    password.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
  }

  /// What a save request keeps, and where.
  struct Save: Equatable {
    /// What is sealed to the vault's inbox.
    let record: LoginRecord
    /// The vault it goes to, or nil when the person picks one of [vaults].
    let vault: PasskeyVault?
    /// The vaults that save logins, the one the app wrote last first.
    let vaults: [PasskeyVault]
    /// It changes a login the vault holds, rather than adding one.
    let update: Bool
  }

  /// What saving [password] for [username] keeps (openspec: add-passwords, the
  /// password-autofill spec), on the website [site], or in the app [appName]
  /// names when iOS gives no website; nil when there is no password, no name,
  /// or no vault saves logins. [vaults] are those that save, the one used last
  /// first; [logins] and [picks] what their indexes name.
  ///
  /// A password iOS filled from Kemlock's generator and the form not yet sent
  /// ([generatedFilled]) is a generated record for the vault used last, kept
  /// even if no save follows. Otherwise a login of one of the vaults for the
  /// same site, or app of that name, and username, whatever its case, is
  /// updated in its own vault, keeping its id so the app takes the password
  /// in as a change; any other is new, named after the site or the app, and
  /// goes to the only vault that saves, or the one the person picks.
  static func save(
    site: String?, appName: String, username: String, password: String, generatedFilled: Bool, generated: Bool, vaults: [PasskeyVault],
    logins: [VaultLogin], picks: [String: [AutofillPick]], at: Int64, newId: () -> String
  ) -> Save? {
    guard !password.isEmpty, let first = vaults.first else { return nil }
    if generatedFilled {
      return Save(record: .generated(password: password, site: site, at: at), vault: first, vaults: vaults, update: false)
    }
    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let wanted = user.isEmpty ? nil : user.lowercased()
    func mine(_ entry: VaultLogin) -> Bool {
      guard let site else { return entry.login.domains.isEmpty && entry.login.name == appName }
      let picked = picks[entry.vault]?.contains { $0.host == site && $0.account == entry.login.id } ?? false
      return picked || HostMatch.matches(host: site, domains: entry.login.domains)
    }
    for vault in vaults {
      let held = logins.first {
        $0.vault == vault.vault && mine($0) && $0.login.username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
      }
      guard let held else { continue }
      let record = LoginRecord.login(
        id: held.login.id, name: held.login.name, username: user.isEmpty ? nil : user, password: password, site: site, app: nil,
        generated: generated, at: at)
      return Save(record: record, vault: vault, vaults: vaults, update: true)
    }
    let name = site.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? appName
    guard !name.isEmpty else { return nil }
    let record = LoginRecord.login(
      id: newId(), name: name, username: user.isEmpty ? nil : user, password: password, site: site, app: nil, generated: generated, at: at)
    return Save(record: record, vault: vaults.count == 1 ? first : nil, vaults: vaults, update: false)
  }
}
