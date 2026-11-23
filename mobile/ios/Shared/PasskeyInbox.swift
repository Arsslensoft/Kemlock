import CryptoKit
import Foundation

/// A passkey the extension made, as it seals it: what the site registered,
/// and its key. The JSON of lib/features/passkeys/passkey_inbox.dart's
/// `InboxRecord`, its keys in the same order.
struct PasskeyRecord: Equatable {
  /// base64url, no padding.
  let credentialId: String
  let rpId: String
  let rpName: String?
  /// base64url, no padding.
  let userHandle: String
  let userName: String
  let userDisplayName: String?
  /// PKCS#8 DER, base64.
  let privateKey: String
  /// Epoch ms the passkey was made.
  let createdAt: Int64

  init(
    credentialId: String, rpId: String, rpName: String? = nil, userHandle: String, userName: String, userDisplayName: String? = nil,
    privateKey: String, createdAt: Int64
  ) {
    self.credentialId = credentialId
    self.rpId = rpId
    self.rpName = rpName
    self.userHandle = userHandle
    self.userName = userName
    self.userDisplayName = userDisplayName
    self.privateKey = privateKey
    self.createdAt = createdAt
  }

  init(item: [String: Any]) throws {
    func text(_ key: String) throws -> String {
      guard let value = item[key] as? String, !value.isEmpty else { throw AutofillFormatError.field(key) }
      return value
    }
    func optional(_ key: String) -> String? { (item[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    credentialId = try text("credentialId")
    rpId = try text("rpId")
    rpName = optional("rpName")
    userHandle = try text("userHandle")
    userName = item["userName"] as? String ?? ""
    userDisplayName = optional("userDisplayName")
    privateKey = try text("privateKey")
    createdAt = (item["createdAt"] as? NSNumber)?.int64Value ?? 0
  }

  init(json data: Data) throws {
    guard let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AutofillFormatError.notJSON }
    try self.init(item: item)
  }

  /// The JSON Dart's `jsonEncode(record.toJson())` writes, byte for byte.
  func json() -> Data {
    var pairs: [(String, JSONValue)] = [("credentialId", .string(credentialId)), ("rpId", .string(rpId))]
    if let rpName { pairs.append(("rpName", .string(rpName))) }
    pairs += [("userHandle", .string(userHandle)), ("userName", .string(userName))]
    if let userDisplayName { pairs.append(("userDisplayName", .string(userDisplayName))) }
    pairs += [("privateKey", .string(privateKey)), ("createdAt", .integer(createdAt))]
    return JSONValue.object(pairs)
  }
}

/// The inbox a passkey made while the vault is locked waits in, until the
/// app opens it with the vault's inbox key (lib/features/passkeys/passkey_inbox.dart):
///
/// ```text
/// {"v": 1, "epk": base64(ephemeral public point, 65 bytes),
///  "nonce": base64(12 bytes), "ct": base64(AES-256-GCM ciphertext || tag)}
/// key = HKDF-SHA-256(ikm = ECDH(ephemeral, inbox key),
///                    salt = epk || inbox public point,
///                    info = "kemlock-passkey-inbox-v1", 32 bytes)
/// ```
///
/// The extension only seals; opening is for the tests.
enum PasskeyInbox {
  static let info = Data("kemlock-passkey-inbox-v1".utf8)
  static let version = 1

  enum Failure: Error, Equatable {
    case notInboxFile
    case doesNotOpen
  }

  /// [record] sealed to the inbox key whose public point is [recipient] (X9.63,
  /// 65 bytes). The [ephemeral] key and [nonce] are fresh unless given, as the fixtures do.
  static func seal(
    _ record: PasskeyRecord, to recipient: Data, ephemeral: P256.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil
  ) throws -> Data {
    let recipientKey = try P256.KeyAgreement.PublicKey(x963Representation: recipient)
    let epk = ephemeral.publicKey.x963Representation
    let key = fileKey(try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey), epk: epk, recipient: recipient)
    let box = try AES.GCM.seal(record.json(), using: key, nonce: try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce())
    return JSONValue.object([
      ("v", .integer(Int64(version))),
      ("epk", .string(epk.base64EncodedString())),
      ("nonce", .string(Data(box.nonce).base64EncodedString())),
      ("ct", .string((box.ciphertext + box.tag).base64EncodedString())),
    ])
  }

  /// Opens an inbox [file] with the inbox [key].
  static func open(_ file: Data, with key: P256.KeyAgreement.PrivateKey) throws -> PasskeyRecord {
    guard let root = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any], root["v"] as? Int == version,
      let epk = (root["epk"] as? String).flatMap({ Data(base64Encoded: $0) }),
      let nonce = (root["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
      let sealed = (root["ct"] as? String).flatMap({ Data(base64Encoded: $0) }), sealed.count >= 16
    else { throw Failure.notInboxFile }
    do {
      let shared = try key.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: epk))
      let fileKey = fileKey(shared, epk: epk, recipient: key.publicKey.x963Representation)
      let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
      return try PasskeyRecord(json: try AES.GCM.open(box, using: fileKey))
    } catch {
      throw Failure.doesNotOpen
    }
  }

  /// The AES key of an inbox file whose ephemeral point is [epk], for the inbox key at [recipient],
  /// with the HKDF [info] of its kind: a passkey's unless given.
  static func fileKey(_ shared: SharedSecret, epk: Data, recipient: Data, info: Data = PasskeyInbox.info) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: epk + recipient, sharedInfo: info, outputByteCount: 32)
  }
}

/// The app a login was saved in, on Android: its package and the SHA-256 of
/// its original signing certificate, in hex. iOS saves none, but writes one
/// as the other two do.
struct InboxApp: Equatable {
  let packageName: String
  let cert: String
}

/// What waits in a vault's inbox for the app besides passkeys
/// (lib/features/logins/login_inbox.dart's `LoginInboxRecord`): a login saved
/// or updated after a form was sent, or a password generated and filled,
/// kept even if no save follows. `at` is epoch milliseconds.
enum LoginRecord: Equatable {
  /// A login, with the id it takes in the vault so a pick remembered for it finds it;
  /// [generated] says its password was one Kemlock made.
  case login(id: String, name: String, username: String?, password: String, site: String?, app: InboxApp?, generated: Bool, at: Int64)
  /// A password generated and filled for [site], which no save may follow.
  case generated(password: String, site: String?, at: Int64)

  /// A record as [json] writes it; throws for one that is neither kind, or misses what it needs.
  init(item: [String: Any]) throws {
    func text(_ key: String) throws -> String {
      guard let value = item[key] as? String, !value.isEmpty else { throw AutofillFormatError.field(key) }
      return value
    }
    func optional(_ key: String) -> String? { (item[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    let at = (item["at"] as? NSNumber)?.int64Value ?? 0
    switch item["kind"] as? String {
    case "login":
      let app = (item["app"] as? [String: Any]).flatMap { app in
        (app["package"] as? String).flatMap { name in (app["cert"] as? String).map { InboxApp(packageName: name, cert: $0) } }
      }
      self = .login(
        id: try text("id"), name: try text("name"), username: optional("username"), password: try text("password"), site: optional("site"),
        app: app, generated: item["generated"] as? Bool == true, at: at)
    case "generated":
      self = .generated(password: try text("password"), site: optional("site"), at: at)
    default:
      throw AutofillFormatError.field("kind")
    }
  }

  init(json data: Data) throws {
    guard let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AutofillFormatError.notJSON }
    try self.init(item: item)
  }

  /// The JSON Dart's `jsonEncode(record.toJson())` writes, byte for byte: keys in its order, none for a nil value.
  func json() -> Data {
    var pairs: [(String, JSONValue)]
    switch self {
    case let .login(id, name, username, password, site, app, generated, at):
      pairs = [("kind", .string("login")), ("id", .string(id)), ("name", .string(name))]
      if let username { pairs.append(("username", .string(username))) }
      pairs.append(("password", .string(password)))
      if let site { pairs.append(("site", .string(site))) }
      if let app { pairs.append(("app", .nested([("package", .string(app.packageName)), ("cert", .string(app.cert))]))) }
      pairs += [("generated", .bool(generated)), ("at", .integer(at))]
    case let .generated(password, site, at):
      pairs = [("kind", .string("generated")), ("password", .string(password))]
      if let site { pairs.append(("site", .string(site))) }
      pairs.append(("at", .integer(at)))
    }
    return JSONValue.object(pairs)
  }
}

/// The login files of a vault's inbox, beside its passkey files, sealed to
/// the same inbox key with another HKDF info, so the two kinds never share a
/// key (openspec: add-passwords, design decision 9):
///
/// ```text
/// {"v": 1, "kind": "login", "epk": base64(ephemeral public point, 65 bytes),
///  "nonce": base64(12 bytes), "ct": base64(AES-256-GCM ciphertext || tag)}
/// key = HKDF-SHA-256(ikm = ECDH(ephemeral, inbox key),
///                    salt = epk || inbox public point,
///                    info = "kemlock-login-inbox-v1", 32 bytes)
/// plaintext = the record's JSON, see `LoginRecord`
/// ```
///
/// The outer `kind` lets the app pick the info before opening a file. The
/// extension only seals; opening is for the tests.
enum LoginInbox {
  static let info = Data("kemlock-login-inbox-v1".utf8)
  static let kind = "login"

  /// A new file's name, `login-<uuid>.json`.
  static func fileName() -> String { "login-\(UUID().uuidString.lowercased()).json" }

  /// [record] sealed to the inbox key whose public point is [recipient] (X9.63,
  /// 65 bytes). The [ephemeral] key and [nonce] are fresh unless given, as the fixtures do.
  static func seal(_ record: LoginRecord, to recipient: Data, ephemeral: P256.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil) throws -> Data {
    let recipientKey = try P256.KeyAgreement.PublicKey(x963Representation: recipient)
    let epk = ephemeral.publicKey.x963Representation
    let key = PasskeyInbox.fileKey(try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey), epk: epk, recipient: recipient, info: info)
    let box = try AES.GCM.seal(record.json(), using: key, nonce: try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce())
    return JSONValue.object([
      ("v", .integer(Int64(PasskeyInbox.version))),
      ("kind", .string(kind)),
      ("epk", .string(epk.base64EncodedString())),
      ("nonce", .string(Data(box.nonce).base64EncodedString())),
      ("ct", .string((box.ciphertext + box.tag).base64EncodedString())),
    ])
  }

  /// Opens a login [file] with the inbox [key].
  static func open(_ file: Data, with key: P256.KeyAgreement.PrivateKey) throws -> LoginRecord {
    guard let root = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any], root["v"] as? Int == PasskeyInbox.version,
      root["kind"] as? String == kind,
      let epk = (root["epk"] as? String).flatMap({ Data(base64Encoded: $0) }),
      let nonce = (root["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
      let sealed = (root["ct"] as? String).flatMap({ Data(base64Encoded: $0) }), sealed.count >= 16
    else { throw PasskeyInbox.Failure.notInboxFile }
    do {
      let shared = try key.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: epk))
      let fileKey = PasskeyInbox.fileKey(shared, epk: epk, recipient: key.publicKey.x963Representation, info: info)
      let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
      return try LoginRecord(json: try AES.GCM.open(box, using: fileKey))
    } catch {
      throw PasskeyInbox.Failure.doesNotOpen
    }
  }
}

/// The JSON values the inbox needs, written as Dart's `jsonEncode` writes
/// them: keys in the order given, `/` and non-ASCII left as they are.
enum JSONValue {
  case string(String)
  case integer(Int64)
  case bool(Bool)
  /// An object inside another, its keys in the order given.
  case nested([(String, JSONValue)])

  static func object(_ pairs: [(String, JSONValue)]) -> Data { Data(objectText(pairs).utf8) }

  private static func objectText(_ pairs: [(String, JSONValue)]) -> String {
    var out = "{"
    for (index, (key, value)) in pairs.enumerated() {
      if index > 0 { out += "," }
      out += quoted(key) + ":"
      switch value {
      case .string(let text): out += quoted(text)
      case .integer(let number): out += String(number)
      case .bool(let flag): out += flag ? "true" : "false"
      case .nested(let inner): out += objectText(inner)
      }
    }
    return out + "}"
  }

  private static func quoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\u{09}": out += "\\t"
      case "\u{0A}": out += "\\n"
      case "\u{0C}": out += "\\f"
      case "\u{0D}": out += "\\r"
      case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}
