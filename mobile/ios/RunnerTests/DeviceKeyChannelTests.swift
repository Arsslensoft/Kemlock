import Foundation
import Security
import XCTest

@testable import Runner

/// The attributes a device key is made with (DeviceKeychain), and the errors the channel sends. Making the key
/// needs a Secure Enclave, which the simulator lacks, so the key itself is made and used on a phone (the plan's
/// task 13.4); here the request to make it is checked.
final class DeviceKeyChannelTests: XCTestCase {
  func testTheKeyIsMadeInTheSecureEnclaveAsAPermanentP256Key() throws {
    let access = try DeviceKeychain.accessControl()

    let attributes = DeviceKeychain.creationAttributes(tag: "dpop.main", access: access)

    XCTAssertEqual(attributes[kSecAttrKeyType as String] as! CFString, kSecAttrKeyTypeECSECPrimeRandom)
    XCTAssertEqual(attributes[kSecAttrKeySizeInBits as String] as? Int, 256)
    XCTAssertEqual(attributes[kSecAttrTokenID as String] as! CFString, kSecAttrTokenIDSecureEnclave)
    let privateAttributes = try XCTUnwrap(attributes[kSecPrivateKeyAttrs as String] as? [String: Any])
    XCTAssertEqual(privateAttributes[kSecAttrIsPermanent as String] as? Bool, true)
    XCTAssertEqual(privateAttributes[kSecAttrApplicationTag as String] as? Data, Data("com.kemlock.app.devicekey.dpop.main".utf8))
  }

  func testOnlyTagsOfPlainCharactersAndALimitedLengthAreTaken() {
    XCTAssertTrue(DeviceKeychain.isValidTag("dpop.0a1b:vault-1_x"))
    XCTAssertFalse(DeviceKeychain.isValidTag(""))
    XCTAssertFalse(DeviceKeychain.isValidTag("a/b"))
    XCTAssertFalse(DeviceKeychain.isValidTag("a b"))
    XCTAssertFalse(DeviceKeychain.isValidTag("é"))
    XCTAssertFalse(DeviceKeychain.isValidTag(String(repeating: "x", count: 129)))
  }

  func testSendsTheCodesTheDartSideReads() {
    XCTAssertEqual(
      [DeviceKeyError.unavailable("x"), DeviceKeyError.missing, DeviceKeyError.failed("x")].map { $0.code },
      ["unavailable", "missing", "failed"])
    XCTAssertEqual(DeviceKeyError.failed("Keychain said no").message, "Keychain said no")
    XCTAssertNil(DeviceKeyError.missing.message)
  }

  func testAKeyThatIsNotThereIsMissingNotAFailure() throws {
    // The CI simulator runs an unsigned build, whose Keychain lookups fail instead of finding nothing, and it has no
    // Secure Enclave. The same lookup is made on a phone with the key itself (task 13.4), which covers this.
    #if targetEnvironment(simulator)
      let onSimulator = true
    #else
      let onSimulator = false
    #endif
    try XCTSkipIf(onSimulator, "The simulator can't look a device key up; the check on a phone covers this")
    DeviceKeychain.delete("no-such-key")

    XCTAssertThrowsError(try DeviceKeychain.privateKey("no-such-key")) { error in
      XCTAssertEqual(error as? DeviceKeyError, DeviceKeyError.missing)
    }
  }

  // The trusted-device key's wrap (add-account-crypto task 7.4): ECIES to the wrapping key's public half, opened only
  // with its private half. The unit test runs it with a software P-256 key, as a simulator has no Secure Enclave; the
  // Secure Enclave key is the same algorithm and is tried on a phone (task 13.4).

  private func softwareKey() throws -> SecKey {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    return try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
  }

  func testAWrappedKeyOpensWithThePrivateHalfOfTheKeyItWasWrappedTo() throws {
    let key = try softwareKey()
    let trusted = Data((0..<32).map { UInt8($0) })

    let wrapped = try DeviceKeychain.wrap(trusted, to: try XCTUnwrap(SecKeyCopyPublicKey(key)))

    XCTAssertGreaterThan(wrapped.count, trusted.count)
    XCTAssertNil(wrapped.range(of: trusted), "the key is not in the wrap in the clear")
    XCTAssertEqual(try DeviceKeychain.unwrap(wrapped, with: key), trusted)
  }

  func testTheSameKeyWrappedTwiceDiffers() throws {
    let key = try softwareKey()
    let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
    let trusted = Data(repeating: 7, count: 32)

    XCTAssertNotEqual(try DeviceKeychain.wrap(trusted, to: pub), try DeviceKeychain.wrap(trusted, to: pub))
  }

  func testAnotherKeyOpensNothing() throws {
    let wrapped = try DeviceKeychain.wrap(Data(repeating: 1, count: 32), to: try XCTUnwrap(SecKeyCopyPublicKey(try softwareKey())))

    XCTAssertThrowsError(try DeviceKeychain.unwrap(wrapped, with: try softwareKey())) { error in
      XCTAssertEqual((error as? DeviceKeyError)?.code, "failed")
    }
  }

  func testAChangedByteOpensNothing() throws {
    let key = try softwareKey()
    var wrapped = try DeviceKeychain.wrap(Data(repeating: 1, count: 32), to: try XCTUnwrap(SecKeyCopyPublicKey(key)))
    wrapped[wrapped.count - 1] ^= 1

    XCTAssertThrowsError(try DeviceKeychain.unwrap(wrapped, with: key))
  }
}
