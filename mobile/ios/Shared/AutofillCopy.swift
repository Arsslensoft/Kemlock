import Foundation

// The autofill copy, its index and remembered picks, as
// lib/features/autofill/autofill_copy.dart writes them (openspec: add-passwords, the code-autofill spec).
// Shared by the app, which writes them, and the AutoFill extension, which reads them.

/// The only version of the copy, the index and the picks these readers know.
let autofillFormatVersion = 1

/// A copy, index or pick that can't be read: not JSON, another version, or a field missing.
enum AutofillFormatError: Error, Equatable {
  case notJSON
  case version(Int?)
  case field(String)
}

/// TOTP or Steam; the app never hands over HOTP accounts.
enum AutofillKind: String {
  case totp
  case steam
}

/// One account the extension can fill.
struct AutofillAccount: Equatable {
  let id: String
  let issuer: String
  let label: String
  let kind: AutofillKind
  /// `SHA1`, `SHA224`, `SHA256`, `SHA384` or `SHA512`.
  let algorithm: String
  /// 1 to 10; 5 for Steam.
  let digits: Int
  /// Seconds per code, above 0.
  let period: Int
  /// The secret's bytes, decoded by the app.
  let key: Data
  /// Hosts the account is filled on and their subdomains; one starting with `=` only on itself.
  let domains: [String]

  /// What the list shows first: the issuer, else the label.
  var name: String { issuer.isEmpty ? label : issuer }
}

/// One passkey the extension can sign in with, as `autofillPasskey` writes it:
/// with its key in the copy and in the extension's own records, without it in the index.
struct AutofillPasskey: Equatable {
  let credentialId: Data
  let rpId: String
  let rpName: String?
  let userHandle: Data
  let userName: String
  let userDisplayName: String?
  /// PKCS#8 DER; nil where only names are kept.
  let privateKey: Data?

  init(
    credentialId: Data, rpId: String, rpName: String? = nil, userHandle: Data, userName: String, userDisplayName: String? = nil,
    privateKey: Data?
  ) {
    self.credentialId = credentialId
    self.rpId = rpId
    self.rpName = rpName
    self.userHandle = userHandle
    self.userName = userName
    self.userDisplayName = userDisplayName
    self.privateKey = privateKey
  }

  /// An entry of a copy's `passkeys`, which needs its key, or of an index's, which has none.
  init(item: [String: Any], withKey: Bool) throws {
    guard let credentialId = Data(base64URL: try string(item, "credentialId")), !credentialId.isEmpty else { throw AutofillFormatError.field("credentialId") }
    guard let userHandle = Data(base64URL: try string(item, "userHandle")) else { throw AutofillFormatError.field("userHandle") }
    if withKey {
      guard let key = Data(base64Encoded: try string(item, "privateKey")), !key.isEmpty else { throw AutofillFormatError.field("privateKey") }
      privateKey = key
    } else {
      privateKey = nil
    }
    let rpId = try string(item, "rpId")
    guard !rpId.isEmpty else { throw AutofillFormatError.field("rpId") }
    self.credentialId = credentialId
    self.rpId = rpId
    rpName = item["rpName"] as? String
    self.userHandle = userHandle
    userName = item["userName"] as? String ?? ""
    userDisplayName = item["userDisplayName"] as? String
  }

  /// A record the extension made, with its key.
  init(record: PasskeyRecord) throws {
    guard let credentialId = Data(base64URL: record.credentialId), let userHandle = Data(base64URL: record.userHandle),
      let key = Data(base64Encoded: record.privateKey)
    else { throw AutofillFormatError.field("record") }
    self.init(
      credentialId: credentialId, rpId: record.rpId, rpName: record.rpName, userHandle: userHandle, userName: record.userName,
      userDisplayName: record.userDisplayName, privateKey: key)
  }

  /// What the list shows under the site: the user name, else the display name.
  var name: String { userName.isEmpty ? userDisplayName ?? "" : userName }

  /// The same passkey without its key, as an index keeps it.
  var withoutKey: AutofillPasskey {
    AutofillPasskey(
      credentialId: credentialId, rpId: rpId, rpName: rpName, userHandle: userHandle, userName: userName, userDisplayName: userDisplayName,
      privateKey: nil)
  }

  /// The entry an index keeps of it: everything but the key.
  var indexItem: [String: Any] {
    var item: [String: Any] = ["credentialId": credentialId.base64URL, "rpId": rpId, "userHandle": userHandle.base64URL, "userName": userName]
    if let rpName { item["rpName"] = rpName }
    if let userDisplayName { item["userDisplayName"] = userDisplayName }
    return item
  }
}

/// A passkey with the vault it belongs to, as the extension offers it.
struct VaultPasskey: Equatable {
  let vault: String
  let passkey: AutofillPasskey

  /// `<vault>/<credential id in base64url>`, as its identity carries it (see `AutofillRecord`).
  var record: String { "\(vault)/\(passkey.credentialId.base64URL)" }
}

/// [passkeys] with each credential id of a vault once, the first kept.
func uniquePasskeys(_ passkeys: [VaultPasskey]) -> [VaultPasskey] {
  var seen = Set<String>()
  return passkeys.filter { seen.insert($0.record).inserted }
}

/// A copy's or an index's `passkeys`: none when the key is missing, as in every copy before passkeys.
private func readPasskeys(_ root: [String: Any], withKey: Bool) throws -> [AutofillPasskey] {
  guard let value = root["passkeys"] else { return [] }
  guard let list = value as? [[String: Any]] else { throw AutofillFormatError.field("passkeys") }
  return try list.map { try AutofillPasskey(item: $0, withKey: withKey) }
}

/// One login the extension can fill, as `AutofillLogin` in autofill_copy.dart writes it: with its
/// password in the copy, without it in the index.
struct AutofillLogin: Equatable {
  let id: String
  let name: String
  let username: String?
  /// Nil in an index, which never holds it, and for a login that has none.
  let password: String?
  /// Registrable domains, or exact hosts marked `=`, it is filled on; none for a login saved in an app.
  let domains: [String]

  init(id: String, name: String, username: String? = nil, password: String? = nil, domains: [String]) {
    self.id = id
    self.name = name
    self.username = username
    self.password = password
    self.domains = domains
  }

  /// An entry of a copy's or an index's `logins`, or nil for one without its id or its domains,
  /// which is left out rather than the whole copy refused.
  init?(item: [String: Any]) {
    func optional(_ key: String) -> String? { (item[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    guard let id = optional("id"), let domains = item["domains"] as? [String] else { return nil }
    self.init(id: id, name: optional("name") ?? "", username: optional("username"), password: optional("password"), domains: domains)
  }

  /// What a suggestion names it by: the username, else the login's name.
  var shownName: String { username ?? name }

  /// The same login without its password, as an index keeps it.
  var withoutPassword: AutofillLogin { AutofillLogin(id: id, name: name, username: username, domains: domains) }
}

/// A login with the vault it belongs to, as the extension offers it.
struct VaultLogin: Equatable, Identifiable {
  let vault: String
  let login: AutofillLogin

  /// `<vault>/<login id>`, as its identity carries it (see `AutofillRecord`).
  var record: String { "\(vault)/\(login.id)" }
  var id: String { record }
}

/// A copy's or an index's `logins`: none when the key is missing, as in every copy before
/// passwords. An entry this version can't read is left out, and the rest kept.
private func readLogins(_ root: [String: Any]) -> [AutofillLogin] {
  (root["logins"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(AutofillLogin.init(item:)) }
}

/// One vault's autofill copy.
struct AutofillCopy: Equatable {
  let vault: String
  let accounts: [AutofillAccount]
  /// While passkeys are on for the vault; empty otherwise.
  let passkeys: [AutofillPasskey]
  /// While passwords are on for the vault, with their passwords; empty otherwise.
  let logins: [AutofillLogin]

  init(vault: String, accounts: [AutofillAccount], passkeys: [AutofillPasskey] = [], logins: [AutofillLogin] = []) {
    self.vault = vault
    self.accounts = accounts
    self.passkeys = passkeys
    self.logins = logins
  }

  /// Reads the JSON of `autofillCopy`, refusing any version but this one.
  init(json data: Data) throws {
    let root = try versioned(data)
    vault = try string(root, "vault")
    guard let list = root["accounts"] as? [[String: Any]] else { throw AutofillFormatError.field("accounts") }
    accounts = try list.map { item in
      guard let kind = AutofillKind(rawValue: try string(item, "kind")) else { throw AutofillFormatError.field("kind") }
      guard let key = Data(base64Encoded: try string(item, "key")) else { throw AutofillFormatError.field("key") }
      return AutofillAccount(
        id: try string(item, "id"),
        issuer: try string(item, "issuer"),
        label: try string(item, "label"),
        kind: kind,
        algorithm: try string(item, "algorithm"),
        digits: try int(item, "digits"),
        period: try int(item, "period"),
        key: key,
        domains: item["domains"] as? [String] ?? []
      )
    }
    passkeys = try readPasskeys(root, withKey: true)
    logins = readLogins(root)
  }
}

/// One vault's index: what suggestions may name before biometrics.
struct AutofillIndex: Equatable {
  struct Entry: Equatable {
    let id: String
    let issuer: String
    let domains: [String]
  }

  let vault: String
  /// Empty when suggestions mustn't name the service.
  let accounts: [Entry]
  /// The passkeys' sites and user names, without keys, while passkeys are on.
  let passkeys: [AutofillPasskey]
  /// The logins' names, usernames and domains, never their passwords, while passwords are on.
  let logins: [AutofillLogin]

  /// Reads the JSON of `autofillIndex`, refusing any version but this one.
  init(json data: Data) throws {
    let root = try versioned(data)
    vault = try string(root, "vault")
    guard let list = root["accounts"] as? [[String: Any]] else { throw AutofillFormatError.field("accounts") }
    accounts = try list.map { item in
      Entry(id: try string(item, "id"), issuer: try string(item, "issuer"), domains: item["domains"] as? [String] ?? [])
    }
    passkeys = try readPasskeys(root, withKey: false)
    logins = readLogins(root).map(\.withoutPassword)
  }

  /// Whether [data] is an index that names accounts, as one does while the
  /// vault names services in suggestions. An index written for passkeys
  /// alone names none, and the vault's picks then stay encrypted. One this
  /// version can't read names none.
  static func namesAccounts(_ data: Data?) -> Bool {
    guard let data, let index = try? AutofillIndex(json: data) else { return false }
    return !index.accounts.isEmpty
  }

  /// Whether [data] is an index that holds the vault's logins, as one does
  /// while its passwords are on: the picks of its logins may then be kept in
  /// the clear, as the usernames are. One this version can't read holds none.
  static func holdsLogins(_ data: Data?) -> Bool {
    guard let data, let index = try? AutofillIndex(json: data) else { return false }
    return !index.logins.isEmpty
  }
}

/// An account or a login the person chose for a website, to suggest there from then on.
struct AutofillPick: Equatable {
  /// `web:<host>`.
  let target: String
  /// The account's id, or the login's.
  let account: String

  static func web(_ host: String, account: String) -> AutofillPick {
    AutofillPick(target: "web:\(HostMatch.normalize(host))", account: account)
  }

  /// The host of a web pick, or nil for any other kind.
  var host: String? { target.hasPrefix("web:") ? String(target.dropFirst(4)) : nil }

  var json: [String: Any] { ["target": target, "account": account] }

  init(target: String, account: String) {
    self.target = target
    self.account = account
  }

  init(item: [String: Any]) throws {
    target = try string(item, "target")
    account = try string(item, "account")
  }

  /// One encrypted line of `<vault>.picks`, before encryption.
  func lineJSON() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["v": autofillFormatVersion, "target": target, "account": account], options: [.sortedKeys])
  }

  /// A decrypted line of `<vault>.picks`.
  init(lineJSON data: Data) throws {
    try self.init(item: try versioned(data))
  }
}

/// The plaintext picks of `<vault>.picks.json`, kept while the vault's index is.
struct AutofillPlainPicks: Equatable {
  let picks: [AutofillPick]

  init(picks: [AutofillPick]) {
    self.picks = picks
  }

  init(json data: Data) throws {
    let root = try versioned(data)
    guard let list = root["picks"] as? [[String: Any]] else { throw AutofillFormatError.field("picks") }
    picks = try list.map(AutofillPick.init(item:))
  }

  func json() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["v": autofillFormatVersion, "picks": picks.map(\.json)], options: [.sortedKeys])
  }

  /// What of [picks] may stay in the clear beside the vault's new [index] and
  /// [copy]: all of them while the index names accounts; while it holds the
  /// vault's logins alone, the logins' picks, not those of the codes the copy
  /// holds; none otherwise, as beside an index written for passkeys alone,
  /// whose vault's picks then stay encrypted.
  static func named(_ picks: [AutofillPick], copy: Data, index: Data) -> [AutofillPick] {
    if AutofillIndex.namesAccounts(index) { return picks }
    guard AutofillIndex.holdsLogins(index), let codes = try? AutofillCopy(json: copy) else { return [] }
    let ids = Set(codes.accounts.map(\.id))
    return picks.filter { !ids.contains($0.account) }
  }

  /// [picks] once [pick] is remembered beside the vault's [index], or nil when
  /// it is kept encrypted alone: a code's is kept in the clear while the index
  /// names accounts, a [login]'s while it holds the vault's logins. A website
  /// keeps one code and one login picked there in the clear, the latest.
  static func remembering(_ pick: AutofillPick, login: Bool, in picks: [AutofillPick], index: Data?) -> [AutofillPick]? {
    guard AutofillIndex.namesAccounts(index) || (login && AutofillIndex.holdsLogins(index)) else { return nil }
    let logins = Set((index.flatMap { try? AutofillIndex(json: $0) }?.logins ?? []).map(\.id))
    return picks.filter { $0.target != pick.target || logins.contains($0.account) != login } + [pick]
  }
}

private func versioned(_ data: Data) throws -> [String: Any] {
  guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AutofillFormatError.notJSON }
  let version = root["v"] as? Int
  guard version == autofillFormatVersion else { throw AutofillFormatError.version(version) }
  return root
}

private func string(_ item: [String: Any], _ key: String) throws -> String {
  guard let value = item[key] as? String else { throw AutofillFormatError.field(key) }
  return value
}

private func int(_ item: [String: Any], _ key: String) throws -> Int {
  guard let value = item[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw AutofillFormatError.field(key) }
  return value.intValue
}
