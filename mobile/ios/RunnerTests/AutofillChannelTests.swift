import AuthenticationServices
import CryptoKit
import Flutter
import Foundation
import Security
import XCTest

@testable import Runner

/// The channel the Dart side calls (lib/platform/autofill.dart), driven with
/// the calls `AutofillHost` makes when passkeys are turned on and off for a
/// vault, on the simulator's real Keychain key, with the files in a folder of
/// their own. The identities are checked as the channel hands them to iOS:
/// the identity store takes them, but doesn't give them back to the app.
/// Writing a copy needs Face ID enrolled on the simulator (Features › Face
/// ID › Enrolled) and a signed build, since an unsigned one
/// (CODE_SIGNING_ALLOWED=NO, as CI builds) has no Keychain; without either
/// that test is skipped.
final class AutofillChannelTests: XCTestCase {
  /// Whether this build may keep items in the Keychain.
  private static var keychainUsable: Bool {
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.kemlock.app.tests", kSecAttrAccount as String: UUID().uuidString,
    ]
    let status = SecItemAdd(item.merging([kSecValueData as String: Data([1])]) { first, _ in first } as CFDictionary, nil)
    SecItemDelete(item as CFDictionary)
    return status != errSecMissingEntitlement
  }

  /// [method] answered as Flutter would ask it, on the main thread.
  private func call(_ channel: AutofillChannel, _ method: String, _ arguments: [String: Any] = [:]) async -> Any? {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        channel.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { continuation.resume(returning: $0) }
      }
    }
  }

  private func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  func testTurningPasskeysOnWritesThemOutAndTurningThemOffWithdrawsThem() async throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Passkeys need iOS 18") }
    guard AutofillKey.biometricsAvailable() else { throw XCTSkip("Face ID isn't enrolled on this simulator") }
    guard Self.keychainUsable else { throw XCTSkip("An unsigned build has no Keychain to keep the key in") }
    let (store, base) = PasskeyTests.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let channel = AutofillChannel(store: store)
    let inbox = P256.KeyAgreement.PrivateKey()
    let key = P256.Signing.PrivateKey()
    var passkey: [String: Any] = [
      "credentialId": Data(0..<16).base64URL, "rpId": "webauthn.io", "userHandle": Data("alice".utf8).base64URL, "userName": "alice",
    ]
    let index = try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [passkey]])
    passkey["privateKey"] = key.derRepresentation.base64EncodedString()
    let copy = try json(["v": 1, "vault": "main", "accounts": [], "passkeys": [passkey]])

    // On: AutofillHost writes the copy and the index with the inbox key
    let on = ["vault": "main", "copy": copy, "index": index, "inboxKey": inbox.publicKey.x963Representation.base64EncodedString()]
    let wroteOn = await call(channel, "writeVault", on)
    XCTAssertNil(wroteOn, "\((wroteOn as? FlutterError)?.code ?? "") \((wroteOn as? FlutterError)?.message ?? "")")

    let sealed = try XCTUnwrap(store.read(store.copyURL("main")))
    XCTAssertNil(sealed.range(of: Data(copy.utf8)), "the copy is written encrypted")
    XCTAssertEqual(try AutofillIndex(json: try XCTUnwrap(store.read(store.indexURL("main")))).passkeys.map(\.userName), ["alice"])
    XCTAssertEqual(store.passkeyVaults().map(\.inboxKey), [inbox.publicKey.x963Representation])
    XCTAssertEqual(IdentitySync.passkeyIdentities(in: store).map(\.relyingPartyIdentifier), ["webauthn.io"])

    // A passkey the extension made while the vault was locked waits in the inbox until the app clears it
    let made = PasskeyProvider.register(rpId: "example.com", userName: "bob", userHandle: Data("bob".utf8))
    try store.save(made.record, in: try XCTUnwrap(store.passkeyVaults().first), publicKey: AutofillKey.find().flatMap(SecKeyCopyPublicKey))
    XCTAssertEqual(IdentitySync.passkeyIdentities(in: store).count, 2)
    let waiting = await call(channel, "readInbox", ["vault": "main"])
    let files = try XCTUnwrap(waiting as? [[String: String]])
    XCTAssertEqual(files.map { $0["name"] }, ["\(made.credentialId.base64URL).json"])
    XCTAssertEqual(try PasskeyInbox.open(Data(try XCTUnwrap(files.first?["content"]).utf8), with: inbox), made.record)
    let cleared = await call(channel, "clearInbox", ["vault": "main", "names": ["../main.copy", files[0]["name"]!]])
    XCTAssertNil(cleared)
    let left = await call(channel, "readInbox", ["vault": "main"])
    XCTAssertEqual((left as? [Any])?.count, 0)
    XCTAssertNotNil(store.read(store.copyURL("main")), "a name outside the inbox is left alone")

    // Off, codes still on: the copy and the index without passkeys, and no inbox key
    let codes = try json(["v": 1, "vault": "main", "accounts": []])
    let codesOnly = ["vault": "main", "copy": codes, "index": codes]
    let wroteOff = await call(channel, "writeVault", codesOnly)
    XCTAssertNil(wroteOff)

    XCTAssertNil(store.read(store.passkeyVaultURL("main")))
    XCTAssertEqual(store.madePasskeys("main"), [])
    XCTAssertEqual(try AutofillIndex(json: try XCTUnwrap(store.read(store.indexURL("main")))).passkeys, [])
    XCTAssertEqual(IdentitySync.passkeyIdentities(in: store).count, 0)

    // Both off: AutofillHost removes the vault's files
    let removed = await call(channel, "removeVault", ["vault": "main"])
    XCTAssertNil(removed)
    XCTAssertNil(store.read(store.copyURL("main")))
    XCTAssertNil(store.read(store.indexURL("main")))
  }

  func testRefusesAnInboxKeyThatIsNoPoint() async throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Passkeys need iOS 18") }
    let (store, base) = PasskeyTests.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let channel = AutofillChannel(store: store)

    let answer = await call(channel, "writeVault", ["vault": "main", "copy": "{}", "index": "{}", "inboxKey": "AAAA"])

    XCTAssertEqual((answer as? FlutterError)?.code, "writeFailed")
    XCTAssertNil(store.read(store.copyURL("main")))
  }

  func testRemovingEverythingEmptiesTheInboxes() async throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Passkeys need iOS 18") }
    let (store, base) = PasskeyTests.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let vault = PasskeyVault(vault: "main", inboxKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, name: nil, writtenAt: 1)
    try store.save(PasskeyProvider.register(rpId: "example.com", userName: "a", userHandle: Data([1])).record, in: vault, publicKey: nil)
    XCTAssertEqual(store.inbox("main").count, 1)

    let removed = await call(AutofillChannel(store: store), "removeAll")

    XCTAssertNil(removed)
    XCTAssertEqual(store.inbox("main").count, 0)
  }

  func testSaysWhetherTheExtensionProvidesPasskeys() async throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Passkeys need iOS 18") }
    let answer = await call(AutofillChannel(), "passkeyStatus")
    let status = try XCTUnwrap(answer as? [String: Bool])

    // The test host is the app, with the AutoFill extension embedded
    XCTAssertEqual(status["supported"], true)
    XCTAssertNotNil(status["enabled"])
  }

  // openspec: add-passwords, task 6.6
  func testSaysThePhoneSavesPasswordsFromIOS262() async throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Filling needs iOS 18") }
    let answer = await call(AutofillChannel(), "status")
    let status = try XCTUnwrap(answer as? [String: Any])

    // The test host is the app, with the AutoFill extension embedded
    if #available(iOS 26.2, *) {
      XCTAssertEqual(status["savesPasswords"] as? Bool, true)
    } else {
      XCTAssertEqual(status["savesPasswords"] as? Bool, false)
    }
  }

  func testReadsTheVaultsNameFromTheAppsPreferences() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
    defaults.set(#"{"name":"Work","kdf":"scrypt"}"#, forKey: "CapacitorStorage.backmycodes_vault_config::0123456789ab")
    defaults.set(#"{"kdf":"scrypt"}"#, forKey: "CapacitorStorage.backmycodes_vault_config")

    XCTAssertEqual(AutofillChannel.vaultName("0123456789ab", defaults: defaults), "Work")
    XCTAssertNil(AutofillChannel.vaultName("main", defaults: defaults))
    XCTAssertNil(AutofillChannel.vaultName("aaaaaaaaaaaa", defaults: defaults))
  }
}
