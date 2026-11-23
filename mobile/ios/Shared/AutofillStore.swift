import Foundation
import LocalAuthentication
import Security

/// The files the app writes and the AutoFill extension reads, in `Autofill/`
/// in the App Group container both share (openspec: add-passwords, the code-autofill spec):
///
/// - `<vault>.copy`: the vault's autofill copy, encrypted to [AutofillKey];
/// - `<vault>.index.json`: its ids, issuers and domains, while suggestions may name the service,
///   and its logins' names, usernames and domains while its passwords are on;
/// - `<vault>.picks`: accounts and logins chosen for a website, one encrypted line each, appended by the extension;
/// - `<vault>.picks.json`: the same in the clear: a code's only beside an index that names
///   accounts, a login's beside one that holds the logins;
/// - `<vault>.passkeys.json`: while the extension may save passkeys or logins to the vault, or
///   suggest strong passwords for it, what it may do, its inbox key while it saves, its name and
///   when the app last wrote it (see `PasskeyVault`; the name is from before passwords);
/// - `<vault>.passkeys/<credential id>`: a passkey the extension made, its site
///   and user name in the clear and its record sealed to [AutofillKey], so it
///   signs in before the app has moved it into the vault (see `MadePasskey`);
/// - `key.state`: the biometrics the key was made with, to tell when it stopped opening anything.
///
/// Beside `Autofill/`, `inbox/<vault>/<credential id>.json` holds each passkey
/// the extension made, sealed to the vault's inbox key (`PasskeyInbox`), until
/// the app has moved it into the vault, and `inbox/<vault>/login-<uuid>.json`
/// each login it saved and each password it generated (`LoginInbox`). It is
/// outside the folder because that goes when biometrics change, and the inbox must not.
struct AutofillStore {
  static let appGroup = "group.com.kemlock.app"

  let folder: URL

  /// The store in the App Group container, or in Application Support for a build without the group.
  static func shared() -> AutofillStore {
    let base =
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return AutofillStore(folder: base.appendingPathComponent("Autofill", isDirectory: true))
  }

  /// Vault ids are `main` or 12 hex characters, which keeps file names inside the folder.
  static func isVaultId(_ id: String) -> Bool {
    id == "main" || (id.count == 12 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  func copyURL(_ vault: String) -> URL { folder.appendingPathComponent("\(vault).copy") }
  func indexURL(_ vault: String) -> URL { folder.appendingPathComponent("\(vault).index.json") }
  func picksURL(_ vault: String) -> URL { folder.appendingPathComponent("\(vault).picks") }
  func plainPicksURL(_ vault: String) -> URL { folder.appendingPathComponent("\(vault).picks.json") }
  func madeFolder(_ vault: String) -> URL { folder.appendingPathComponent("\(vault).passkeys", isDirectory: true) }
  func madeURL(_ vault: String, credentialId: Data) -> URL { madeFolder(vault).appendingPathComponent(credentialId.base64URL) }
  func passkeyVaultURL(_ vault: String) -> URL { folder.appendingPathComponent("\(vault).passkeys.json") }
  var stateURL: URL { folder.appendingPathComponent("key.state") }

  /// The inbox, beside the folder.
  var inboxRoot: URL { folder.deletingLastPathComponent().appendingPathComponent("inbox", isDirectory: true) }
  func inboxFolder(_ vault: String) -> URL { inboxRoot.appendingPathComponent(vault, isDirectory: true) }
  func inboxURL(_ vault: String, credentialId: Data) -> URL { inboxFolder(vault).appendingPathComponent("\(credentialId.base64URL).json") }

  /// The vaults that have a copy.
  func vaults() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".copy") }.map { String($0.dropLast(5)) }.filter(Self.isVaultId).sorted()
  }

  func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if url.path.hasPrefix(folder.path + "/") { try keepFolderOutOfBackups() }
    try data.write(to: url, options: [.atomic, .completeFileProtection])
  }

  /// Keeps `Autofill/`, once made, out of the phone's backups, as the share hand-over files are
  /// (`SharedItemFile`): its indexes, picks and passkey names say in the clear what the vault
  /// encrypts, and what is sealed there opens only with this phone's key. Said again at every
  /// write, since the folder goes and comes back when biometrics change. The inbox, beside it,
  /// stays in backups: it is sealed to the vault's key and holds passkeys the vault doesn't yet.
  private func keepFolderOutOfBackups() throws {
    var url = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

  func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

  /// Removes the vault's files, its passkeys and the passkeys waiting in its inbox.
  func removeVault(_ vault: String) {
    let urls = [copyURL(vault), indexURL(vault), picksURL(vault), plainPicksURL(vault), passkeyVaultURL(vault), madeFolder(vault), inboxFolder(vault)]
    for url in urls { remove(url) }
  }

  func removeAll() { remove(folder) }

  // ─── The app's side ────────────────────────────────────────────────────────

  /// Writes the vault's copy, encrypted, and its index, or removes the index
  /// and the plaintext picks when [index] is nil. Makes the key first when
  /// there's none or biometrics changed since it was made, which also
  /// removes every vault's files, since the old key opens nothing now; the
  /// inboxes stay. [takes] says what else the extension may do with the
  /// vault; an app from before passwords sends none, and its [inboxKey] then
  /// means passkeys are on. Saving passkeys or logins needs the inbox key,
  /// suggesting passwords doesn't. While the extension may do any, what it
  /// may, the inbox key, the vault's [name] and the time are kept for it;
  /// while it may save passkeys, the passkeys it made that the copy now holds
  /// are dropped. Otherwise it forgets the vault's record, and the passkeys
  /// it made for the vault once it may save none.
  func writeVault(
    _ vault: String, copy: Data, index: Data?, inboxKey: Data? = nil, takes: VaultTakes? = nil, name: String? = nil, at date: Date = Date()
  ) throws {
    guard Self.isVaultId(vault) else { throw AutofillKeyError.failed("Not a vault id") }
    guard AutofillKey.biometricsAvailable(), let state = AutofillKey.biometricState() else { throw AutofillKeyError.noBiometrics }
    var key = AutofillKey.find()
    if key == nil || read(stateURL) != state {
      removeAll()
      key = try AutofillKey.create()
      try write(state, to: stateURL)
    }
    try write(try AutofillKey.encrypt(copy, to: key!), to: copyURL(vault))
    if let index {
      try write(index, to: indexURL(vault))
      keepNamedPicks(vault, copy: copy, index: index)
    } else {
      remove(indexURL(vault))
      remove(plainPicksURL(vault))
    }
    let asked = takes ?? (inboxKey == nil ? VaultTakes() : .beforePasswords)
    let kept = VaultTakes(passkeys: asked.passkeys && inboxKey != nil, logins: asked.logins && inboxKey != nil, suggest: asked.suggest)
    if !kept.passkeys { remove(madeFolder(vault)) }
    guard kept != VaultTakes() else { return remove(passkeyVaultURL(vault)) }
    let writtenAt = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let record = PasskeyVault(vault: vault, inboxKey: inboxKey, name: name, writtenAt: writtenAt, takes: kept)
    try write(try record.json(), to: passkeyVaultURL(vault))
    guard kept.passkeys else { return }
    for passkey in (try? AutofillCopy(json: copy))?.passkeys ?? [] {
      remove(madeURL(vault, credentialId: passkey.credentialId))
    }
  }

  /// Keeps in the clear only the picks the vault's new [index] may name (see `AutofillPlainPicks.named`).
  private func keepNamedPicks(_ vault: String, copy: Data, index: Data) {
    guard !AutofillIndex.namesAccounts(index) else { return }
    let url = plainPicksURL(vault)
    let kept = AutofillPlainPicks.named(plainPicks(vault), copy: copy, index: index)
    guard !kept.isEmpty else { return remove(url) }
    do {
      try write(try AutofillPlainPicks(picks: kept).json(), to: url)
    } catch {
      remove(url)
    }
  }

  /// The passkeys and logins waiting in [vault]'s inbox: each file's name and its sealed content.
  func inbox(_ vault: String) -> [(name: String, content: String)] {
    guard Self.isVaultId(vault) else { return [] }
    let folder = inboxFolder(vault)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
      read(folder.appendingPathComponent(name)).flatMap { String(data: $0, encoding: .utf8) }.map { (name: name, content: $0) }
    }
  }

  /// Deletes the inbox files [names] of [vault], once the app has their passkeys and logins. A name that
  /// isn't a file of the inbox, such as one with a slash, is left alone.
  func clearInbox(_ vault: String, names: [String]) {
    guard Self.isVaultId(vault) else { return }
    for name in names where name.hasSuffix(".json") && !name.contains("/") && !name.hasPrefix(".") {
      remove(inboxFolder(vault).appendingPathComponent(name))
    }
  }

  /// Removes every vault's files and the key. The inboxes stay: see [removeEverything].
  func reset() {
    removeAll()
    AutofillKey.delete()
  }

  /// Removes every vault's files, the key and the passkeys waiting in the inboxes, when every vault is wiped.
  func removeEverything() {
    reset()
    remove(inboxRoot)
  }

  // ─── The extension's side ──────────────────────────────────────────────────

  /// Whether the key still opens the copies: it exists, and biometrics are as they were when it was made.
  func keyIsCurrent() -> Bool {
    guard let saved = read(stateURL), AutofillKey.find() != nil else { return false }
    return AutofillKey.biometricState() == saved
  }

  /// Whether the key is here but biometrics can't be read to compare, because Face ID or Touch
  /// ID is locked after too many failed tries. Nothing changed, so nothing is to be removed:
  /// once the passcode is typed, the key opens the copies as before.
  func keyWaitsForPasscode() -> Bool {
    read(stateURL) != nil && AutofillKey.find() != nil && AutofillKey.biometricsLockedOut()
  }

  /// Every vault's copy, decrypted with the key [context] unlocked. A copy that won't open is left out.
  func openCopies(context: LAContext) throws -> [AutofillCopy] {
    guard let key = AutofillKey.find(context: context) else { throw AutofillKeyError.stale }
    return try openCopies(with: key)
  }

  func openCopies(with key: SecKey) throws -> [AutofillCopy] {
    var copies: [AutofillCopy] = []
    for vault in vaults() {
      guard let sealed = read(copyURL(vault)) else { continue }
      let plain = try AutofillKey.decrypt(sealed, with: key)
      if let copy = try? AutofillCopy(json: plain), copy.vault == vault { copies.append(copy) }
    }
    return copies
  }

  /// The picks remembered for [vault], decrypted with the key [context] unlocked; later lines win.
  func openPicks(_ vault: String, context: LAContext) -> [AutofillPick] {
    guard let key = AutofillKey.find(context: context), let data = read(picksURL(vault)), let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
      guard let sealed = Data(base64Encoded: String(line)), let plain = try? AutofillKey.decrypt(sealed, with: key) else { return nil }
      return try? AutofillPick(lineJSON: plain)
    }
  }

  /// Remembers [pick] for [vault]: an encrypted line, which needs only the
  /// public key, and the same in the clear while the vault's index names it
  /// in suggestions (see `AutofillPlainPicks.remembering`); [login] says it
  /// is a login's pick, not a code's.
  func remember(_ pick: AutofillPick, vault: String, login: Bool = false) throws {
    guard Self.isVaultId(vault), let key = AutofillKey.find() else { return }
    let line = try AutofillKey.encrypt(try pick.lineJSON(), to: key).base64EncodedString() + "\n"
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try keepFolderOutOfBackups()
    let url = picksURL(vault)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
    } else {
      try write(Data(line.utf8), to: url)
    }
    guard let plain = AutofillPlainPicks.remembering(pick, login: login, in: plainPicks(vault), index: read(indexURL(vault))) else { return }
    try write(try AutofillPlainPicks(picks: plain).json(), to: plainPicksURL(vault))
  }

  /// Every vault's index.
  func indexes() -> [AutofillIndex] {
    vaults().compactMap { vault in read(indexURL(vault)).flatMap { try? AutofillIndex(json: $0) } }
  }

  /// The vault's picks in the clear, empty without an index.
  func plainPicks(_ vault: String) -> [AutofillPick] {
    guard let data = read(plainPicksURL(vault)), let picks = try? AutofillPlainPicks(json: data) else { return [] }
    return picks.picks
  }

  // ─── Passkeys ──────────────────────────────────────────────────────────────

  /// Every vault's record beside its copy, the one the app wrote last first.
  private func vaultRecords() -> [PasskeyVault] {
    vaults().compactMap { vault in read(passkeyVaultURL(vault)).flatMap { try? PasskeyVault(json: $0) }.flatMap { $0.vault == vault ? $0 : nil } }
      .sorted { $0.writtenAt != $1.writtenAt ? $0.writtenAt > $1.writtenAt : $0.vault < $1.vault }
  }

  /// The vaults new passkeys may go to: those with a copy and passkeys on, the one the app wrote last first.
  func passkeyVaults() -> [PasskeyVault] { vaultRecords().filter(\.savesPasskeys) }

  /// The vaults new and changed logins may go to: those with a copy and saving on, the one the app wrote last first.
  func loginVaults() -> [PasskeyVault] { vaultRecords().filter(\.savesLogins) }

  /// Whether some vault with a copy has strong passwords suggested.
  func suggestsPasswords() -> Bool { vaultRecords().contains { $0.takes.suggest } }

  /// Every vault's logins without their passwords, as the indexes name them,
  /// and their vaults' picks kept in the clear: what saving a login reads to
  /// tell an update from a new login, with no biometrics.
  func loginNames() -> (logins: [VaultLogin], picks: [String: [AutofillPick]]) {
    var logins: [VaultLogin] = []
    var picks: [String: [AutofillPick]] = [:]
    for index in indexes() where !index.logins.isEmpty {
      logins += index.logins.map { VaultLogin(vault: index.vault, login: $0) }
      picks[index.vault] = plainPicks(index.vault)
    }
    return (logins, picks)
  }

  /// Keeps a passkey the extension just made for [vault]: sealed to the
  /// vault's inbox key, for the app to move into the vault, and to the
  /// hardware key's [publicKey], to sign in with until then. Only the inbox
  /// file must be written; without it the passkey would never reach the vault.
  func save(_ record: PasskeyRecord, in vault: PasskeyVault, publicKey: SecKey?) throws {
    guard Self.isVaultId(vault.vault), let credentialId = Data(base64URL: record.credentialId), !credentialId.isEmpty else {
      throw AutofillFormatError.field("credentialId")
    }
    guard let inboxKey = vault.inboxKey else { throw AutofillFormatError.field("inboxKey") }
    try write(try PasskeyInbox.seal(record, to: inboxKey), to: inboxURL(vault.vault, credentialId: credentialId))
    guard let publicKey else { return }
    try? write(try MadePasskey(record: record, sealedTo: publicKey).json(), to: madeURL(vault.vault, credentialId: credentialId))
  }

  /// Keeps a login the extension saved, or a password it generated, for
  /// [vault]: sealed to the vault's inbox key in a file of its own beside the
  /// passkeys waiting there, for the app to take in when the vault is next
  /// opened. It needs no biometrics. Returns the file's name.
  @discardableResult
  func saveLogin(_ record: LoginRecord, in vault: PasskeyVault) throws -> String {
    guard Self.isVaultId(vault.vault), let inboxKey = vault.inboxKey else { throw AutofillFormatError.field("inboxKey") }
    let name = LoginInbox.fileName()
    try write(try LoginInbox.seal(record, to: inboxKey), to: inboxFolder(vault.vault).appendingPathComponent(name))
    return name
  }

  /// The passkeys the extension made for [vault] and keeps until the app has them.
  func madePasskeys(_ vault: String) -> [MadePasskey] {
    let folder = madeFolder(vault)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.sorted().compactMap { name in read(folder.appendingPathComponent(name)).flatMap { try? MadePasskey(json: $0) } }
  }

  /// Every vault's passkeys without their keys, for suggestions and for
  /// choosing before biometrics: the indexes', then those the extension made.
  func passkeyNames() -> [VaultPasskey] {
    uniquePasskeys(
      vaults().flatMap { vault in
        let indexed = read(indexURL(vault)).flatMap { try? AutofillIndex(json: $0) }?.passkeys ?? []
        return (indexed + madePasskeys(vault).map(\.names)).map { VaultPasskey(vault: vault, passkey: $0) }
      })
  }

  /// Every vault's passkeys with their keys, decrypted with the key [context]
  /// unlocked: the copies', then those the extension made.
  func openPasskeys(context: LAContext) throws -> [VaultPasskey] {
    guard let key = AutofillKey.find(context: context) else { throw AutofillKeyError.stale }
    return try openPasskeys(with: key)
  }

  func openPasskeys(with key: SecKey) throws -> [VaultPasskey] {
    var passkeys: [VaultPasskey] = []
    for copy in try openCopies(with: key) {
      passkeys += copy.passkeys.map { VaultPasskey(vault: copy.vault, passkey: $0) }
    }
    for vault in vaults() {
      passkeys += madePasskeys(vault).compactMap { made in (try? made.open(with: key)).map { VaultPasskey(vault: vault, passkey: $0) } }
    }
    return uniquePasskeys(passkeys)
  }
}

/// What the app lets the extension do with a vault besides filling it
/// (`VaultTakes` in lib/platform/autofill.dart): save the passkeys sites
/// make, save the logins forms send, and suggest strong passwords. Saving
/// needs the vault's inbox key; suggesting doesn't.
struct VaultTakes: Equatable {
  let passkeys: Bool
  let logins: Bool
  let suggest: Bool

  /// What a vault written before passwords takes: its inbox key meant passkeys alone.
  static let beforePasswords = VaultTakes(passkeys: true)

  init(passkeys: Bool = false, logins: Bool = false, suggest: Bool = false) {
    self.passkeys = passkeys
    self.logins = logins
    self.suggest = suggest
  }

  /// The flags as the app sends them over the channel and the vault's record keeps them; one missing is off.
  init(item: [String: Any]) {
    self.init(passkeys: item["passkeys"] as? Bool == true, logins: item["logins"] as? Bool == true, suggest: item["suggest"] as? Bool == true)
  }

  var json: [String: Any] { ["passkeys": passkeys, "logins": logins, "suggest": suggest] }
}

/// A vault the extension may do more with than fill, as the app describes it
/// beside the copy: what it may do ([takes]), the public point of its inbox
/// key (X9.63, 65 bytes) while it saves passkeys or logins, the name the lock
/// screen shows (none for an unnamed first vault), and when the app last wrote
/// it, which puts the vault used last first. Named when it was for passkeys
/// alone, as its file still is.
struct PasskeyVault: Equatable {
  let vault: String
  let inboxKey: Data?
  let name: String?
  /// Epoch ms.
  let writtenAt: Int64
  let takes: VaultTakes

  init(vault: String, inboxKey: Data?, name: String?, writtenAt: Int64, takes: VaultTakes = .beforePasswords) {
    self.vault = vault
    self.inboxKey = inboxKey
    self.name = name
    self.writtenAt = writtenAt
    self.takes = takes
  }

  /// Whether new passkeys may go to the vault.
  var savesPasskeys: Bool { inboxKey != nil && takes.passkeys }

  /// Whether new and changed logins, and the passwords the extension generates, may go to the vault.
  var savesLogins: Bool { inboxKey != nil && takes.logins }

  /// Reads a record [json] wrote. One written before passwords has no `takes`, and its inbox key means passkeys alone.
  init(json data: Data) throws {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AutofillFormatError.notJSON }
    guard root["v"] as? Int == autofillFormatVersion else { throw AutofillFormatError.version(root["v"] as? Int) }
    guard let vault = root["vault"] as? String else { throw AutofillFormatError.field("vault") }
    var key: Data?
    if let text = root["inboxKey"] {
      guard let point = (text as? String).flatMap({ Data(base64Encoded: $0) }), point.count == 65, point.first == 4 else {
        throw AutofillFormatError.field("inboxKey")
      }
      key = point
    }
    self.vault = vault
    inboxKey = key
    name = (root["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    writtenAt = (root["writtenAt"] as? NSNumber)?.int64Value ?? 0
    takes = (root["takes"] as? [String: Any]).map(VaultTakes.init(item:)) ?? (key == nil ? VaultTakes() : .beforePasswords)
  }

  func json() throws -> Data {
    var root: [String: Any] = ["v": autofillFormatVersion, "vault": vault, "writtenAt": writtenAt, "takes": takes.json]
    if let inboxKey { root["inboxKey"] = inboxKey.base64EncodedString() }
    if let name { root["name"] = name }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }
}

/// A passkey the extension made, as it keeps it beside the copy until the
/// app has moved it into the vault: its names in the clear, as an index
/// keeps them, and its whole record sealed to [AutofillKey], which needs only
/// the public half to write.
struct MadePasskey: Equatable {
  /// The passkey without its key.
  let names: AutofillPasskey
  /// The record's JSON, encrypted to the key.
  let sealed: Data

  init(record: PasskeyRecord, sealedTo publicKey: SecKey) throws {
    names = try AutofillPasskey(record: record).withoutKey
    sealed = try AutofillKey.encrypt(record.json(), toPublicKey: publicKey)
  }

  init(json data: Data) throws {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AutofillFormatError.notJSON }
    guard root["v"] as? Int == autofillFormatVersion else { throw AutofillFormatError.version(root["v"] as? Int) }
    guard let item = root["passkey"] as? [String: Any] else { throw AutofillFormatError.field("passkey") }
    guard let sealed = (root["sealed"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw AutofillFormatError.field("sealed") }
    names = try AutofillPasskey(item: item, withKey: false)
    self.sealed = sealed
  }

  func json() throws -> Data {
    try JSONSerialization.data(
      withJSONObject: ["v": autofillFormatVersion, "passkey": names.indexItem, "sealed": sealed.base64EncodedString()], options: [.sortedKeys])
  }

  /// The passkey with its key, decrypted with [key], which prompts unless its context was already evaluated.
  func open(with key: SecKey) throws -> AutofillPasskey {
    let passkey = try AutofillPasskey(record: try PasskeyRecord(json: try AutofillKey.decrypt(sealed, with: key)))
    guard passkey.credentialId == names.credentialId, passkey.rpId == names.rpId else { throw AutofillFormatError.field("sealed") }
    return passkey
  }
}
