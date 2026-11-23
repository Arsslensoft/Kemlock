import CryptoKit
import Foundation
import XCTest

@testable import Runner

/// The passkey bytes and the inbox (ios/Shared), held to the same bytes as
/// the Dart app and the Android provider through
/// mobile/test/fixtures/passkeys/passkeys.json, which is never regenerated.
final class PasskeyTests: XCTestCase {
  static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../test/fixtures/passkeys/passkeys.json")
    .standardizedFileURL

  static func fixture() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
  }

  private func part(_ name: String) throws -> [String: Any] { try XCTUnwrap(Self.fixture()[name] as? [String: Any]) }

  private func bytes(_ part: [String: Any], _ key: String) throws -> Data {
    try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(part[key] as? String)), key)
  }

  // ─── Keys ──────────────────────────────────────────────────────────────────

  func testTheAAGUIDIsKemlocks() throws {
    XCTAssertEqual(PasskeyBytes.aaguid.uuidString.lowercased(), try Self.fixture()["aaguid"] as? String)
    XCTAssertEqual(PasskeyBytes.aaguidBytes.count, 16)
    XCTAssertEqual(PasskeyBytes.aaguidBytes.prefix(2), Data([0xf8, 0x58]))
  }

  func testReadsTheCredentialKeyFromItsPKCS8AndWritesItBackTheSame() throws {
    let credential = try part("credential")
    let key = try P256.Signing.PrivateKey(derRepresentation: try bytes(credential, "privateKey"))

    XCTAssertEqual(key.rawRepresentation, try bytes(credential, "d"))
    XCTAssertEqual(key.publicKey.x963Representation, try bytes(credential, "point"))
    XCTAssertEqual(key.derRepresentation, try bytes(credential, "privateKey"))
  }

  // ─── Registration ──────────────────────────────────────────────────────────

  func testBuildsTheRegistrationBytes() throws {
    let credential = try part("credential")
    let registration = try part("registration")
    let point = try bytes(credential, "point")
    let credentialId = try XCTUnwrap(Data(base64URL: try XCTUnwrap(credential["credentialId"] as? String)))
    XCTAssertEqual(credentialId, Data(0..<16))

    XCTAssertEqual(PasskeyBytes.coseKey(point: point), try bytes(registration, "coseKey"))
    let authData = PasskeyBytes.registrationAuthData(rpId: try XCTUnwrap(credential["rpId"] as? String), credentialId: credentialId, point: point)
    XCTAssertEqual(authData, try bytes(registration, "authData"))
    XCTAssertEqual(PasskeyBytes.attestationObject(authData: authData), try bytes(registration, "attestationObject"))
  }

  func testWritesCBORInItsShortestForm() {
    XCTAssertEqual(CBOR.integer(0), Data([0x00]))
    XCTAssertEqual(CBOR.integer(23), Data([0x17]))
    XCTAssertEqual(CBOR.integer(24), Data([0x18, 0x18]))
    XCTAssertEqual(CBOR.integer(-7), Data([0x26]))
    XCTAssertEqual(CBOR.integer(-25), Data([0x38, 0x18]))
    XCTAssertEqual(CBOR.integer(1000), Data([0x19, 0x03, 0xe8]))
    XCTAssertEqual(CBOR.integer(1_000_000), Data([0x1a, 0x00, 0x0f, 0x42, 0x40]))
    XCTAssertEqual(CBOR.bytes(Data(count: 300)).prefix(3), Data([0x59, 0x01, 0x2c]))
    XCTAssertEqual(CBOR.text("fmt"), Data([0x63, 0x66, 0x6d, 0x74]))
    XCTAssertEqual(CBOR.map([]), Data([0xa0]))
  }

  // ─── Assertion ─────────────────────────────────────────────────────────────

  func testBuildsTheAssertionBytesAndItsSignaturesVerify() throws {
    let credential = try part("credential")
    let assertion = try part("assertion")
    let point = try bytes(credential, "point")
    let clientData = Data(try XCTUnwrap(assertion["clientDataJSON"] as? String).utf8)
    let hash = Data(SHA256.hash(data: clientData))
    XCTAssertEqual(hash, try bytes(assertion, "clientDataHash"))

    let authData = PasskeyBytes.assertionAuthData(rpId: try XCTUnwrap(credential["rpId"] as? String))
    XCTAssertEqual(authData, try bytes(assertion, "authData"))
    let signed = PasskeyBytes.assertionSignedBytes(authData: authData, clientDataHash: hash)
    XCTAssertEqual(signed, try bytes(assertion, "signedBytes"))

    // The fixture's deterministic signature and one made now both verify; neither does over other bytes
    let key = try P256.Signing.PrivateKey(derRepresentation: try bytes(credential, "privateKey"))
    let signature = try PasskeyBytes.sign(signed, with: key)
    XCTAssertTrue(PasskeyBytes.verify(try bytes(assertion, "signature"), of: signed, point: point))
    XCTAssertTrue(PasskeyBytes.verify(signature, of: signed, point: point))
    XCTAssertFalse(PasskeyBytes.verify(signature, of: signed + Data([0]), point: point))
    XCTAssertFalse(PasskeyBytes.verify(try bytes(assertion, "signature"), of: signed + Data([0]), point: point))
  }

  // ─── The inbox ─────────────────────────────────────────────────────────────

  func testSealsTheInboxRecordToTheSameFileAndOpensIt() throws {
    let inbox = try part("inbox")
    let inboxKey = try P256.KeyAgreement.PrivateKey(derRepresentation: try bytes(try XCTUnwrap(inbox["key"] as? [String: Any]), "privateKey"))
    let ephemeral = try P256.KeyAgreement.PrivateKey(
      derRepresentation: try bytes(try XCTUnwrap(inbox["ephemeral"] as? [String: Any]), "privateKey"))
    let recordJSON = try XCTUnwrap(inbox["record"] as? [String: Any])
    let record = try PasskeyRecord(item: recordJSON)
    let recipient = inboxKey.publicKey.x963Representation
    XCTAssertEqual(recipient, try bytes(try XCTUnwrap(inbox["key"] as? [String: Any]), "point"))

    let shared = try ephemeral.sharedSecretFromKeyAgreement(with: inboxKey.publicKey)
    XCTAssertEqual(shared.withUnsafeBytes { Data($0) }, try bytes(inbox, "sharedSecret"))
    let fileKey = PasskeyInbox.fileKey(shared, epk: ephemeral.publicKey.x963Representation, recipient: recipient)
    XCTAssertEqual(fileKey.withUnsafeBytes { Data($0) }, try bytes(inbox, "fileKey"))

    let file = try PasskeyInbox.seal(record, to: recipient, ephemeral: ephemeral, nonce: try bytes(inbox, "nonce"))
    XCTAssertEqual(String(decoding: file, as: UTF8.self), inbox["file"] as? String)

    let opened = try PasskeyInbox.open(Data(try XCTUnwrap(inbox["file"] as? String).utf8), with: inboxKey)
    XCTAssertEqual(opened, record)
    XCTAssertEqual(opened.createdAt, 1_763_200_000_000)
  }

  func testWritesTheRecordAsDartDoes() throws {
    let record = PasskeyRecord(
      credentialId: "AAE", rpId: "example.com", userHandle: "dQ", userName: "a\"b\\c/é\n\u{1}", privateKey: "x+/=", createdAt: 5)

    XCTAssertEqual(
      String(decoding: record.json(), as: UTF8.self),
      #"{"credentialId":"AAE","rpId":"example.com","userHandle":"dQ","userName":"a\"b\\c/é\n\u0001","privateKey":"x+/=","createdAt":5}"#)
    XCTAssertEqual(try PasskeyRecord(json: record.json()), record)
  }

  func testSealsAFreshFileEachTimeThatOpensOnlyWithTheInboxKey() throws {
    let inboxKey = P256.KeyAgreement.PrivateKey()
    let record = PasskeyRecord(credentialId: "AAE", rpId: "example.com", userHandle: "dQ", userName: "alice", privateKey: "AA==", createdAt: 1)

    let first = try PasskeyInbox.seal(record, to: inboxKey.publicKey.x963Representation)
    let second = try PasskeyInbox.seal(record, to: inboxKey.publicKey.x963Representation)

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try PasskeyInbox.open(first, with: inboxKey), record)
    XCTAssertThrowsError(try PasskeyInbox.open(first, with: P256.KeyAgreement.PrivateKey())) {
      XCTAssertEqual($0 as? PasskeyInbox.Failure, .doesNotOpen)
    }
    XCTAssertThrowsError(try PasskeyInbox.open(Data("{}".utf8), with: inboxKey)) { XCTAssertEqual($0 as? PasskeyInbox.Failure, .notInboxFile) }
  }

  // ─── Logins in the inbox (openspec: add-passwords, task 6.4) ───────────────

  private static let loginsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../test/fixtures/passkeys/logins.json")
    .standardizedFileURL

  private func hex(_ text: String) -> Data {
    let digits = Array(text.utf8)
    return Data(stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16)! })
  }

  private func inboxKeys() throws -> (inbox: P256.KeyAgreement.PrivateKey, ephemeral: P256.KeyAgreement.PrivateKey) {
    let inbox = try part("inbox")
    return (
      try P256.KeyAgreement.PrivateKey(derRepresentation: try bytes(try XCTUnwrap(inbox["key"] as? [String: Any]), "privateKey")),
      try P256.KeyAgreement.PrivateKey(derRepresentation: try bytes(try XCTUnwrap(inbox["ephemeral"] as? [String: Any]), "privateKey"))
    )
  }

  func testSealsEveryLoginRecordToTheFileDartWrote() throws {
    let (inboxKey, ephemeral) = try inboxKeys()
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.loginsURL)) as? [String: Any])
    let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 3)

    for item in cases {
      let name = item["name"] as? String ?? ""
      let record = try LoginRecord(item: try XCTUnwrap(item["record"] as? [String: Any]))
      let file = try XCTUnwrap(item["file"] as? String)

      let sealed = try LoginInbox.seal(record, to: inboxKey.publicKey.x963Representation, ephemeral: ephemeral, nonce: hex(try XCTUnwrap(item["nonce"] as? String)))

      XCTAssertEqual(String(decoding: sealed, as: UTF8.self), file, name)
      XCTAssertEqual(try LoginInbox.open(Data(file.utf8), with: inboxKey), record, name)
    }
  }

  func testWritesLoginRecordsAsDartDoes() {
    let login = LoginRecord.login(
      id: "l1", name: "a\"b/é", username: nil, password: "p\\w", site: nil, app: InboxApp(packageName: "x.y", cert: "ab"), generated: false, at: 7)
    let generated = LoginRecord.generated(password: "x", site: "larkspur.example", at: 9)

    XCTAssertEqual(
      String(decoding: login.json(), as: UTF8.self),
      #"{"kind":"login","id":"l1","name":"a\"b/é","password":"p\\w","app":{"package":"x.y","cert":"ab"},"generated":false,"at":7}"#)
    XCTAssertEqual(String(decoding: generated.json(), as: UTF8.self), #"{"kind":"generated","password":"x","site":"larkspur.example","at":9}"#)
    XCTAssertEqual(try LoginRecord(json: login.json()), login)
    XCTAssertEqual(try LoginRecord(json: generated.json()), generated)
    XCTAssertThrowsError(try LoginRecord(json: Data(#"{"kind":"passkey","password":"x"}"#.utf8)))
  }

  func testALoginFileNeverOpensAsAPasskeyNorAPasskeyFileAsALogin() throws {
    let inboxKey = P256.KeyAgreement.PrivateKey()
    let recipient = inboxKey.publicKey.x963Representation
    let login = try LoginInbox.seal(.generated(password: "x", site: nil, at: 1), to: recipient)
    let passkey = try PasskeyInbox.seal(try Self.record(Data(repeating: 1, count: 16)), to: recipient)

    XCTAssertThrowsError(try PasskeyInbox.open(login, with: inboxKey))
    XCTAssertThrowsError(try LoginInbox.open(passkey, with: inboxKey)) { XCTAssertEqual($0 as? PasskeyInbox.Failure, .notInboxFile) }
    XCTAssertThrowsError(try LoginInbox.open(login, with: P256.KeyAgreement.PrivateKey())) {
      XCTAssertEqual($0 as? PasskeyInbox.Failure, .doesNotOpen)
    }
  }

  func testSavesALoginToTheVaultsInboxBesideItsPasskeys() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let inboxKey = P256.KeyAgreement.PrivateKey()
    let vault = PasskeyVault(vault: "main", inboxKey: inboxKey.publicKey.x963Representation, name: nil, writtenAt: 1, takes: VaultTakes(logins: true))
    let record = LoginRecord.login(
      id: "5f0c9a8e", name: "larkspur.example", username: "ada@example.org", password: "hunter2", site: "larkspur.example", app: nil,
      generated: false, at: 1_795_300_000_000)
    try store.save(PasskeyProvider.register(rpId: "example.com", userName: "a", userHandle: Data([1])).record, in: vault, publicKey: nil)

    let name = try store.saveLogin(record, in: vault)

    XCTAssertNotNil(name.range(of: #"^login-[0-9a-f-]{36}\.json$"#, options: .regularExpression), name)
    let waiting = store.inbox("main")
    XCTAssertEqual(waiting.count, 2)
    let file = try XCTUnwrap(waiting.first { $0.name == name })
    XCTAssertEqual(try LoginInbox.open(Data(file.content.utf8), with: inboxKey), record)
    // A vault without its inbox key saves nothing
    XCTAssertThrowsError(try store.saveLogin(record, in: PasskeyVault(vault: "main", inboxKey: nil, name: nil, writtenAt: 1, takes: VaultTakes(suggest: true))))
  }

  // ─── The copy and the index ────────────────────────────────────────────────

  /// The fixture's passkey as `autofillPasskey` writes it, with its key or without.
  private func fixturePasskeyItem(withKey: Bool) throws -> [String: Any] {
    var item = try XCTUnwrap(try part("inbox")["record"] as? [String: Any])
    item["createdAt"] = nil
    if !withKey { item["privateKey"] = nil }
    return item
  }

  private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

  func testReadsACopyWithoutPasskeysAsHoldingNone() throws {
    let codes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../test/fixtures/autofill/codes.json")
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: codes)) as? [String: Any])

    let copy = try AutofillCopy(json: try json(try XCTUnwrap(root["copy"] as? [String: Any])))

    XCTAssertFalse(copy.accounts.isEmpty)
    XCTAssertEqual(copy.passkeys, [])
    XCTAssertEqual(try AutofillIndex(json: Data(#"{"v":1,"vault":"main","accounts":[]}"#.utf8)).passkeys, [])
  }

  func testReadsTheCopysPasskeysWithTheirKeys() throws {
    let credential = try part("credential")
    let copy = try AutofillCopy(json: try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [try fixturePasskeyItem(withKey: true)]]))

    let passkey = try XCTUnwrap(copy.passkeys.first)
    XCTAssertEqual(copy.passkeys.count, 1)
    XCTAssertEqual(passkey.credentialId, Data(0..<16))
    XCTAssertEqual(passkey.rpId, "webauthn.io")
    XCTAssertEqual(passkey.rpName, "WebAuthn.io")
    XCTAssertEqual(passkey.userHandle, Data("user-fixture-1".utf8))
    XCTAssertEqual(passkey.userName, "fixture@example.org")
    XCTAssertEqual(passkey.userDisplayName, "Fixture User")
    XCTAssertEqual(passkey.privateKey, try bytes(credential, "privateKey"))
  }

  func testReadsAnIndexWithOnlyPasskeysAndNoKeys() throws {
    let index = try AutofillIndex(json: try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [try fixturePasskeyItem(withKey: false)]]))

    XCTAssertEqual(index.accounts, [])
    XCTAssertEqual(index.passkeys.map(\.userName), ["fixture@example.org"])
    XCTAssertNil(index.passkeys.first?.privateKey)
  }

  func testRefusesACopysPasskeyWithoutItsKeyOrWithABadId() throws {
    let withoutKey = try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [try fixturePasskeyItem(withKey: false)]])
    XCTAssertThrowsError(try AutofillCopy(json: withoutKey)) { XCTAssertEqual($0 as? AutofillFormatError, .field("privateKey")) }

    var badId = try fixturePasskeyItem(withKey: true)
    badId["credentialId"] = "not/base64url"
    XCTAssertThrowsError(try AutofillCopy(json: try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [badId]]))) {
      XCTAssertEqual($0 as? AutofillFormatError, .field("credentialId"))
    }
    XCTAssertThrowsError(try AutofillCopy(json: try json(["v": 1, "vault": "main", "accounts": [], "passkeys": "none"]))) {
      XCTAssertEqual($0 as? AutofillFormatError, .field("passkeys"))
    }
  }

  // ─── The extension's own records ───────────────────────────────────────────

  static func temporaryStore() -> (AutofillStore, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (AutofillStore(folder: base.appendingPathComponent("Autofill")), base)
  }

  static func testKey() throws -> SecKey {
    var error: Unmanaged<CFError>?
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
    return try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
  }

  static func record(_ credentialId: Data, rpId: String = "example.com", userName: String = "alice") throws -> PasskeyRecord {
    PasskeyRecord(
      credentialId: credentialId.base64URL, rpId: rpId, userHandle: Data(userName.utf8).base64URL, userName: userName,
      privateKey: P256.Signing.PrivateKey().derRepresentation.base64EncodedString(), createdAt: 1)
  }

  /// Writes [record] as the extension keeps a passkey it made for [vault].
  static func make(_ record: PasskeyRecord, vault: String, in store: AutofillStore, key: SecKey) throws {
    let made = try MadePasskey(record: record, sealedTo: try XCTUnwrap(SecKeyCopyPublicKey(key)))
    try FileManager.default.createDirectory(at: store.madeFolder(vault), withIntermediateDirectories: true)
    try store.write(try made.json(), to: store.madeURL(vault, credentialId: made.names.credentialId))
  }

  func testOpensTheCopysPasskeysAndThoseTheExtensionMade() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let key = try Self.testKey()
    let inCopy = try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [try fixturePasskeyItem(withKey: true)]])
    try store.write(try AutofillKey.encrypt(inCopy, to: key), to: store.copyURL("main"))
    try store.write(
      try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [try fixturePasskeyItem(withKey: false)]]), to: store.indexURL("main"))
    let made = try Self.record(Data(repeating: 7, count: 16))
    try Self.make(made, vault: "main", in: store, key: key)
    // A passkey both made here and already in the copy is offered once, from the copy
    try Self.make(try Self.record(Data(0..<16), rpId: "webauthn.io"), vault: "main", in: store, key: key)

    let opened = try store.openPasskeys(with: key)

    XCTAssertEqual(opened.map(\.record), ["main/AAECAwQFBgcICQoLDA0ODw", "main/BwcHBwcHBwcHBwcHBwcHBw"])
    XCTAssertEqual(opened.first?.passkey.userName, "fixture@example.org")
    XCTAssertEqual(opened.last?.passkey, try AutofillPasskey(record: made))
    XCTAssertNotNil(opened.last?.passkey.privateKey)
    // Before biometrics: the same passkeys from the index and the made ones' names, without keys
    let names = store.passkeyNames()
    XCTAssertEqual(names.map(\.record), opened.map(\.record))
    XCTAssertEqual(names.compactMap(\.passkey.privateKey), [])
  }

  func testRefusesARecordWhoseSealedPartIsAnotherPasskeys() throws {
    let key = try Self.testKey()
    let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
    let first = try MadePasskey(record: try Self.record(Data(repeating: 1, count: 16)), sealedTo: publicKey)
    let second = try MadePasskey(record: try Self.record(Data(repeating: 2, count: 16)), sealedTo: publicKey)
    var mixed = try XCTUnwrap(JSONSerialization.jsonObject(with: try first.json()) as? [String: Any])
    mixed["sealed"] = second.sealed.base64EncodedString()

    XCTAssertEqual(try MadePasskey(json: try first.json()), first)
    XCTAssertNoThrow(try first.open(with: key))
    XCTAssertThrowsError(try MadePasskey(json: try json(mixed)).open(with: key))
  }

  // ─── Suggestions ───────────────────────────────────────────────────────────

  func testSuggestsEachPasskeyByItsSiteAndUserName() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("The identities are synced from iOS 18") }
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let key = try Self.testKey()
    try store.write(Data([1]), to: store.copyURL("main"))
    try store.write(
      try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [try fixturePasskeyItem(withKey: false)]]), to: store.indexURL("main"))
    try store.write(Data([1]), to: store.copyURL("0123456789ab"))
    try Self.make(try Self.record(Data(repeating: 7, count: 16), userName: "bob"), vault: "0123456789ab", in: store, key: key)

    let identities = IdentitySync.passkeyIdentities(in: store)

    XCTAssertEqual(identities.map(\.relyingPartyIdentifier), ["example.com", "webauthn.io"])
    XCTAssertEqual(identities.map(\.userName), ["bob", "fixture@example.org"])
    XCTAssertEqual(identities.map(\.credentialID), [Data(repeating: 7, count: 16), Data(0..<16)])
    XCTAssertEqual(identities.map(\.userHandle), [Data("bob".utf8), Data("user-fixture-1".utf8)])
    XCTAssertEqual(identities.compactMap(\.recordIdentifier), ["0123456789ab/BwcHBwcHBwcHBwcHBwcHBw", "main/AAECAwQFBgcICQoLDA0ODw"])
    // An index without accounts names no service for codes
    XCTAssertEqual(IdentitySync.identities(in: store).count, 0)
  }

  func testSuggestsNoPasskeyOfAVaultWithoutACopy() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("The identities are synced from iOS 18") }
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    try Self.make(try Self.record(Data(repeating: 7, count: 16)), vault: "main", in: store, key: try Self.testKey())

    XCTAssertEqual(IdentitySync.passkeyIdentities(in: store).count, 0)
  }

  // ─── Registration ──────────────────────────────────────────────────────────

  private func held(_ credentialId: Data, rpId: String) -> VaultPasskey {
    VaultPasskey(vault: "main", passkey: AutofillPasskey(credentialId: credentialId, rpId: rpId, userHandle: Data([1]), userName: "alice", privateKey: nil))
  }

  func testRefusesARequestThatTakesNoES256() {
    XCTAssertEqual(PasskeyProvider.refusal(algorithms: [-257], excluded: [], rpId: "example.com", held: []), .algorithm)
    XCTAssertEqual(PasskeyProvider.refusal(algorithms: [-8, -257], excluded: [], rpId: "example.com", held: []), .algorithm)
    XCTAssertNil(PasskeyProvider.refusal(algorithms: [-257, -7], excluded: [], rpId: "example.com", held: []))
    // No list is WebAuthn's default, which takes ES256
    XCTAssertNil(PasskeyProvider.refusal(algorithms: [], excluded: [], rpId: "example.com", held: []))
  }

  func testRefusesARequestThatExcludesAPasskeyKemlockHoldsForTheSite() {
    let mine = Data(repeating: 1, count: 16)
    let held = [held(mine, rpId: "Example.com."), held(Data(repeating: 2, count: 16), rpId: "other.org")]

    XCTAssertEqual(PasskeyProvider.refusal(algorithms: [-7], excluded: [Data([9]), mine], rpId: "example.com", held: held), .excluded)
    XCTAssertNil(PasskeyProvider.refusal(algorithms: [-7], excluded: [Data([9])], rpId: "example.com", held: held))
    XCTAssertNil(PasskeyProvider.refusal(algorithms: [-7], excluded: [Data(repeating: 2, count: 16)], rpId: "example.com", held: held))
    XCTAssertNil(PasskeyProvider.refusal(algorithms: [-7], excluded: [mine], rpId: "sub.example.com", held: held))
  }

  func testMakesThePasskeyAndTheAttestationTheFixtureHolds() throws {
    let credential = try part("credential")
    let key = try P256.Signing.PrivateKey(derRepresentation: try bytes(credential, "privateKey"))

    let made = PasskeyProvider.register(
      rpId: "webauthn.io", userName: "fixture@example.org", userHandle: Data("user-fixture-1".utf8), key: key, credentialId: Data(0..<16),
      at: Date(timeIntervalSince1970: 1_763_200_000))

    XCTAssertEqual(made.attestationObject, try bytes(try part("registration"), "attestationObject"))
    XCTAssertEqual(made.credentialId, Data(0..<16))
    XCTAssertEqual(made.record.credentialId, "AAECAwQFBgcICQoLDA0ODw")
    XCTAssertEqual(made.record.userHandle, "dXNlci1maXh0dXJlLTE")
    XCTAssertEqual(made.record.privateKey, credential["privateKey"] as? String)
    XCTAssertEqual(made.record.createdAt, 1_763_200_000_000)
  }

  func testMakesAFreshKeyAndSixteenByteIdEachTime() {
    let first = PasskeyProvider.register(rpId: "example.com", userName: "alice", userHandle: Data([1]))
    let second = PasskeyProvider.register(rpId: "example.com", userName: "alice", userHandle: Data([1]))

    XCTAssertEqual(first.credentialId.count, 16)
    XCTAssertNotEqual(first.credentialId, second.credentialId)
    XCTAssertNotEqual(first.record.privateKey, second.record.privateKey)
  }

  func testKeepsANewPasskeyInTheVaultsInboxAndBesideTheCopy() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let inboxKey = P256.KeyAgreement.PrivateKey()
    let vault = PasskeyVault(vault: "main", inboxKey: inboxKey.publicKey.x963Representation, name: nil, writtenAt: 1)
    let key = try Self.testKey()
    try store.write(Data([1]), to: store.copyURL("main"))
    let made = PasskeyProvider.register(rpId: "example.com", userName: "alice", userHandle: Data("alice".utf8))

    try store.save(made.record, in: vault, publicKey: SecKeyCopyPublicKey(key))

    let file = base.appendingPathComponent("inbox/main/\(made.credentialId.base64URL).json")
    XCTAssertEqual(try PasskeyInbox.open(try Data(contentsOf: file), with: inboxKey), made.record)
    XCTAssertEqual(store.madePasskeys("main").count, 1)
    XCTAssertEqual(try store.madePasskeys("main").first?.open(with: key), try AutofillPasskey(record: made.record))
    XCTAssertEqual(store.passkeyNames().map(\.passkey.userName), ["alice"])
  }

  func testKeepsANewPasskeyInTheInboxAloneWithoutTheHardwareKey() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let inboxKey = P256.KeyAgreement.PrivateKey()
    let made = PasskeyProvider.register(rpId: "example.com", userName: "alice", userHandle: Data([1]))

    try store.save(made.record, in: PasskeyVault(vault: "main", inboxKey: inboxKey.publicKey.x963Representation, name: nil, writtenAt: 1), publicKey: nil)

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.inboxFolder("main").path), ["\(made.credentialId.base64URL).json"])
    XCTAssertEqual(store.madePasskeys("main"), [])
  }

  func testOffersTheVaultUsedLastFirst() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let point = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    for (vault, name, at) in [("main", nil, 5), ("0123456789ab", "Work", 9), ("aaaaaaaaaaaa", "Old", 1)] as [(String, String?, Int64)] {
      try store.write(Data([1]), to: store.copyURL(vault))
      try store.write(try PasskeyVault(vault: vault, inboxKey: point, name: name, writtenAt: at).json(), to: store.passkeyVaultURL(vault))
    }
    // Passkeys on without a copy, and a file naming another vault, offer nothing
    try store.write(try PasskeyVault(vault: "bbbbbbbbbbbb", inboxKey: point, name: nil, writtenAt: 99).json(), to: store.passkeyVaultURL("bbbbbbbbbbbb"))
    try store.write(Data([1]), to: store.copyURL("cccccccccccc"))
    try store.write(try PasskeyVault(vault: "main", inboxKey: point, name: nil, writtenAt: 99).json(), to: store.passkeyVaultURL("cccccccccccc"))

    let vaults = store.passkeyVaults()

    XCTAssertEqual(vaults.map(\.vault), ["0123456789ab", "main", "aaaaaaaaaaaa"])
    XCTAssertEqual(vaults.map(\.name), ["Work", nil, "Old"])
    XCTAssertEqual(vaults.first?.inboxKey, point)
  }

  // openspec: add-passwords, task 6.2
  func testKeepsWhatAVaultTakesBesideItsInboxKey() throws {
    let point = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let saving = PasskeyVault(vault: "main", inboxKey: point, name: "Work", writtenAt: 5, takes: VaultTakes(logins: true, suggest: true))
    // Suggesting needs no inbox key, so a vault that only suggests has none
    let suggesting = PasskeyVault(vault: "main", inboxKey: nil, name: nil, writtenAt: 5, takes: VaultTakes(suggest: true))

    XCTAssertEqual(try PasskeyVault(json: try saving.json()), saving)
    XCTAssertEqual(try PasskeyVault(json: try suggesting.json()), suggesting)
    XCTAssertFalse(saving.savesPasskeys)
    XCTAssertTrue(saving.savesLogins)
    XCTAssertFalse(suggesting.savesPasskeys)
    XCTAssertFalse(suggesting.savesLogins)
    // Taking logins without the key saves none
    XCTAssertFalse(PasskeyVault(vault: "main", inboxKey: nil, name: nil, writtenAt: 5, takes: VaultTakes(passkeys: true, logins: true)).savesLogins)
  }

  func testReadsAVaultWrittenBeforePasswordsAsTakingPasskeysAlone() throws {
    let point = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let before = #"{"inboxKey":"\#(point.base64EncodedString())","name":"Work","v":1,"vault":"main","writtenAt":5}"#

    let vault = try PasskeyVault(json: Data(before.utf8))

    XCTAssertEqual(vault.takes, VaultTakes(passkeys: true))
    XCTAssertEqual(vault.inboxKey, point)
    XCTAssertTrue(vault.savesPasskeys)
    XCTAssertFalse(vault.savesLogins)
    XCTAssertFalse(vault.takes.suggest)
  }

  func testReadsWhatAVaultTakesAsTheAppSendsIt() {
    XCTAssertEqual(VaultTakes(item: ["passkeys": true, "logins": false, "suggest": true]), VaultTakes(passkeys: true, suggest: true))
    XCTAssertEqual(VaultTakes(item: ["logins": true]), VaultTakes(logins: true))
    XCTAssertEqual(VaultTakes(item: [:]), VaultTakes())
  }

  func testOffersLoginsToTheVaultsThatSaveThemUsedLastFirst() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let point = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let vaults: [(String, Data?, Int64, VaultTakes)] = [
      ("main", point, 5, VaultTakes(passkeys: true, logins: true)),
      ("0123456789ab", point, 9, VaultTakes(logins: true, suggest: true)),
      ("aaaaaaaaaaaa", point, 7, VaultTakes(passkeys: true)),
      ("bbbbbbbbbbbb", nil, 8, VaultTakes(suggest: true)),
    ]
    for (vault, key, at, takes) in vaults {
      try store.write(Data([1]), to: store.copyURL(vault))
      try store.write(try PasskeyVault(vault: vault, inboxKey: key, name: nil, writtenAt: at, takes: takes).json(), to: store.passkeyVaultURL(vault))
    }

    XCTAssertEqual(store.loginVaults().map(\.vault), ["0123456789ab", "main"])
    XCTAssertEqual(store.passkeyVaults().map(\.vault), ["aaaaaaaaaaaa", "main"])
    XCTAssertTrue(store.suggestsPasswords())

    // A vault whose record went with its copy suggests nothing
    store.removeVault("0123456789ab")
    store.removeVault("bbbbbbbbbbbb")
    XCTAssertFalse(store.suggestsPasswords())
    XCTAssertEqual(store.loginVaults().map(\.vault), ["main"])
  }

  func testRefusesAnInboxKeyThatIsNoPoint() {
    XCTAssertThrowsError(try PasskeyVault(json: Data(#"{"v":1,"vault":"main","inboxKey":"AAAA","writtenAt":1}"#.utf8))) {
      XCTAssertEqual($0 as? AutofillFormatError, .field("inboxKey"))
    }
  }

  func testRemovingAVaultRemovesItsPasskeysAndItsInbox() throws {
    let (store, base) = Self.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let vault = PasskeyVault(vault: "main", inboxKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, name: nil, writtenAt: 1)
    try store.write(Data([1]), to: store.copyURL("main"))
    try store.write(try vault.json(), to: store.passkeyVaultURL("main"))
    try store.save(PasskeyProvider.register(rpId: "example.com", userName: "a", userHandle: Data([1])).record, in: vault, publicKey: SecKeyCopyPublicKey(try Self.testKey()))
    try store.save(PasskeyProvider.register(rpId: "example.com", userName: "b", userHandle: Data([2])).record, in: PasskeyVault(vault: "0123456789ab", inboxKey: vault.inboxKey, name: nil, writtenAt: 1), publicKey: nil)

    store.removeVault("main")

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.inboxFolder("main").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.madeFolder("main").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.passkeyVaultURL("main").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.inboxFolder("0123456789ab").path))
  }

  // ─── Signing in ────────────────────────────────────────────────────────────

  private func offered(_ rpId: String, _ id: UInt8, userName: String = "alice", vault: String = "main", key: Data? = nil) -> VaultPasskey {
    VaultPasskey(
      vault: vault,
      passkey: AutofillPasskey(credentialId: Data(repeating: id, count: 16), rpId: rpId, userHandle: Data(userName.utf8), userName: userName, privateKey: key))
  }

  private func ids(_ passkeys: [VaultPasskey]) -> [UInt8] { passkeys.map { $0.passkey.credentialId[0] } }

  func testOffersASitesOwnPasskeysAndNoOtherSites() {
    let all = [
      offered("example.com", 1), offered("example.com", 2, userName: "bob"), offered("sub.example.com", 3), offered("com", 4),
      offered("example.com.evil.io", 5), offered("Example.COM.", 6, vault: "0123456789ab"), offered("evilexample.com", 7),
    ]

    // Two accounts on one site, from either vault, are both offered
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "example.com")), [1, 2, 6])
    // A subdomain's passkey isn't its parent's, nor the parent's the subdomain's
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "sub.example.com")), [3])
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "other.example.com")), [])
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "evil.io")), [])
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "")), [])
  }

  func testOffersOnlyTheCredentialsTheRequestAllows() {
    let all = [offered("example.com", 1), offered("example.com", 2, userName: "bob"), offered("other.org", 3)]

    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "example.com", allowed: [Data(repeating: 2, count: 16)])), [2])
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "example.com", allowed: [Data(repeating: 9, count: 16)])), [])
    // Another site's credential, even when allowed, isn't offered here
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "example.com", allowed: [Data(repeating: 3, count: 16)])), [])
    XCTAssertEqual(ids(PasskeyProvider.passkeys(all, for: "example.com", allowed: [])), [1, 2])
  }

  func testSignsTheFixturesAssertionWithThePasskeysKey() throws {
    let credential = try part("credential")
    let assertion = try part("assertion")
    let passkey = AutofillPasskey(
      credentialId: Data(0..<16), rpId: "webauthn.io", userHandle: Data("user-fixture-1".utf8), userName: "fixture@example.org",
      privateKey: try bytes(credential, "privateKey"))

    let signed = try PasskeyProvider.assert(passkey, clientDataHash: try bytes(assertion, "clientDataHash"))

    XCTAssertEqual(signed.authenticatorData, try bytes(assertion, "authData"))
    XCTAssertTrue(PasskeyBytes.verify(signed.signature, of: try bytes(assertion, "signedBytes"), point: try bytes(credential, "point")))
    XCTAssertThrowsError(try PasskeyProvider.assert(passkey.withoutKey, clientDataHash: Data(count: 32)))
  }

  func testFindsThePickedPasskeyInItsOwnVaultWithItsKey() {
    let key = Data([1, 2, 3])
    let chosen = offered("example.com", 1)
    let opened = [offered("example.com", 1, vault: "0123456789ab", key: Data([9])), offered("example.com", 1, key: key)]

    XCTAssertEqual(PasskeyProvider.find(chosen, in: opened)?.privateKey, key)
    XCTAssertNil(PasskeyProvider.find(offered("other.org", 1), in: opened))
    XCTAssertNil(PasskeyProvider.find(chosen, in: [offered("example.com", 1)]))
    XCTAssertNil(PasskeyProvider.find(chosen, in: []))
  }

  func testReadsBase64URL() {
    XCTAssertEqual(Data(base64URL: "AAECAwQFBgcICQoLDA0ODw"), Data(0..<16))
    XCTAssertEqual(Data(base64URL: "-_8"), Data([0xfb, 0xff]))
    XCTAssertEqual(Data([0xfb, 0xff]).base64URL, "-_8")
    XCTAssertNil(Data(base64URL: "a+b/"))
    XCTAssertNil(Data(base64URL: "A"))
  }
}
