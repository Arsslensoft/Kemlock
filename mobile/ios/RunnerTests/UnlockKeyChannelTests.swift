import Flutter
import Foundation
import LocalAuthentication
import Security
import XCTest

@testable import Runner

/// The Keychain items behind biometric unlock (UnlockKeychain) on the simulator's real
/// Keychain, and the errors the channel sends. Reading a key shows Face ID, which a test can't
/// answer, so the items are written and checked here and opened on a phone (the design's Risks).
/// Writing an item behind `.biometryCurrentSet` needs Face ID enrolled on the simulator
/// (Features › Face ID › Enrolled) and a build that may keep Keychain items; without either the
/// Keychain tests are skipped.
final class UnlockKeyChannelTests: XCTestCase {
  private let key = Data((0..<32).map { UInt8($0) })

  private func requireKeychain() throws {
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.kemlock.app.tests", kSecAttrAccount as String: UUID().uuidString,
    ]
    let status = SecItemAdd(item.merging([kSecValueData as String: Data([1])]) { first, _ in first } as CFDictionary, nil)
    SecItemDelete(item as CFDictionary)
    guard status != errSecMissingEntitlement else { throw XCTSkip("An unsigned build has no Keychain to keep the key in") }
    guard AutofillKey.biometricsAvailable() else { throw XCTSkip("Face ID isn't enrolled on this simulator") }
  }

  override func tearDown() {
    UnlockKeychain.deleteAll()
    super.tearDown()
  }

  /// [method] answered as Flutter would ask it, on the main thread.
  private func call(_ method: String, _ arguments: [String: Any] = [:]) async -> Any? {
    let channel = UnlockKeyChannel()
    return await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        channel.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { continuation.resume(returning: $0) }
      }
    }
  }

  func testWritesAnItemPerVaultOnThisPhoneBehindTheBiometricsEnrolledNow() throws {
    try requireKeychain()
    let state = AutofillKey.biometricState()

    try UnlockKeychain.write(key, vault: "main", state: state)
    try UnlockKeychain.write(Data(repeating: 7, count: 32), vault: "0123456789ab", state: state)

    for vault in ["main", "0123456789ab"] {
      let attributes = try XCTUnwrap(UnlockKeychain.attributes(vault), vault)
      XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.kemlock.app.unlock")
      XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, vault)
      XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
      XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool ?? false, false)
      // Only the biometrics enrolled now open it, and never the passcode
      let access = String(describing: try XCTUnwrap(attributes[kSecAttrAccessControl as String]))
      XCTAssertTrue(access.contains("cbio"), access)
      XCTAssertFalse(access.contains("cpo") || access.contains("DeviceOwnerAuthentication"), access)
      // In the app's own group, never the one the AutoFill extension shares
      let group = try XCTUnwrap(attributes[kSecAttrAccessGroup as String] as? String)
      if let own = UnlockKeychain.accessGroup { XCTAssertEqual(group, own) }
      XCTAssertNotEqual(group, AutofillKey.accessGroup)
      XCTAssertTrue(UnlockKeychain.isCurrent(vault, state: state))
    }
  }

  func testSeesThatAnItemWasWrittenWithOtherBiometrics() throws {
    try requireKeychain()

    try UnlockKeychain.write(key, vault: "main", state: Data([1, 2, 3]))

    XCTAssertFalse(UnlockKeychain.isCurrent("main", state: Data([4, 5, 6])))
    XCTAssertTrue(UnlockKeychain.isCurrent("main", state: Data([1, 2, 3])))
    XCTAssertFalse(UnlockKeychain.isCurrent("0123456789ab", state: Data([1, 2, 3])), "no item, nothing to open")
  }

  func testDeletesOneVaultsItemOnly() async throws {
    try requireKeychain()
    try UnlockKeychain.write(key, vault: "main", state: nil)
    try UnlockKeychain.write(key, vault: "0123456789ab", state: nil)

    let deleted = await call("delete", ["vault": "0123456789ab"])

    XCTAssertNil(deleted)
    XCTAssertNil(UnlockKeychain.attributes("0123456789ab"))
    XCTAssertNotNil(UnlockKeychain.attributes("main"))
  }

  func testDeletesEveryVaultsItemAndLeavesTheAutofillKey() async throws {
    try requireKeychain()
    try UnlockKeychain.write(key, vault: "main", state: nil)
    try UnlockKeychain.write(key, vault: "0123456789ab", state: nil)
    // A key under AutofillKey's tag, without the biometrics a real one needs, and an item of another service
    let hadAutofillKey = AutofillKey.find() != nil
    var error: Unmanaged<CFError>?
    if !hadAutofillKey {
      let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: AutofillKey.tag] as [String: Any],
      ]
      XCTAssertNotNil(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    }
    let other: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.kemlock.app.tests", kSecAttrAccount as String: "main"]
    SecItemAdd(other.merging([kSecValueData as String: Data([1])]) { first, _ in first } as CFDictionary, nil)
    defer {
      SecItemDelete(other as CFDictionary)
      if !hadAutofillKey { AutofillKey.delete() }
    }

    let deleted = await call("deleteAll")

    XCTAssertNil(deleted)
    XCTAssertNil(UnlockKeychain.attributes("main"))
    XCTAssertNil(UnlockKeychain.attributes("0123456789ab"))
    XCTAssertNotNil(AutofillKey.find(), "the AutoFill key stays")
    XCTAssertEqual(SecItemCopyMatching(other as CFDictionary, nil), errSecSuccess, "another service's item stays")
  }

  func testAnswersWhetherThePhoneHasBiometrics() async {
    let status = await call("status")

    XCTAssertEqual(status as? Bool, AutofillKey.biometricsAvailable())
  }

  func testRefusesASealWithoutAKey() async {
    let sealed = await call("seal", ["vault": "main", "key": FlutterStandardTypedData(bytes: Data(count: 16)), "reason": "Turn it on"])

    XCTAssertEqual((sealed as? FlutterError)?.code, "failed")
  }

  func testMapsWhatTheKeychainAndLocalAuthenticationSay() {
    XCTAssertNil(UnlockKeyError.from(errSecSuccess))
    XCTAssertEqual(UnlockKeyError.from(errSecUserCanceled), .cancelled)
    XCTAssertEqual(UnlockKeyError.from(errSecItemNotFound), .invalidated)
    // A read whose prompt failed is the prompt's failure, which Dart never falls back from
    XCTAssertEqual(UnlockKeyError.from(errSecAuthFailed)?.code, "prompt")
    XCTAssertEqual(UnlockKeyError.from(errSecInteractionNotAllowed)?.code, "failed")

    func la(_ code: LAError.Code) -> Error {
      NSError(domain: LAError.errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "Face not recognised"])
    }
    for code in [LAError.Code.userCancel, .systemCancel, .appCancel, .userFallback] {
      XCTAssertEqual(UnlockKeyError.from(la(code), opening: true), .cancelled)
      XCTAssertEqual(UnlockKeyError.from(la(code), opening: false), .cancelled)
    }
    // Biometrics or the passcode gone: an item written before opens nothing, and nothing can be written
    for code in [LAError.Code.biometryNotEnrolled, .passcodeNotSet] {
      XCTAssertEqual(UnlockKeyError.from(la(code), opening: true), .invalidated)
      XCTAssertEqual(UnlockKeyError.from(la(code), opening: false), .unavailable)
    }
    XCTAssertEqual(UnlockKeyError.from(la(.biometryNotAvailable), opening: true), .unavailable)
    XCTAssertEqual(UnlockKeyError.from(la(.biometryLockout), opening: true).code, "prompt")
    XCTAssertEqual(UnlockKeyError.from(la(.authenticationFailed), opening: false), .promptFailed("Face not recognised"))
    XCTAssertEqual(UnlockKeyError.from(la(.authenticationFailed), opening: false).message, "Face not recognised")
    XCTAssertEqual(UnlockKeyError.from(NSError(domain: "other", code: 1), opening: true).code, "failed")
    XCTAssertEqual(
      ["cancelled", "invalidated", "unavailable", "prompt", "failed"],
      [UnlockKeyError.cancelled, .invalidated, .unavailable, .promptFailed("x"), .failed("x")].map(\.code)
    )
  }
}
