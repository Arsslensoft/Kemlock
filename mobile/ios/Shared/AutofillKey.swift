import Foundation
import LocalAuthentication
import Security

/// Why the key couldn't be made or used.
enum AutofillKeyError: Error, Equatable {
  /// The phone has no Face ID or Touch ID set up, which the key needs.
  case noBiometrics
  /// The key is gone, or biometrics changed since it was made, so it opens nothing.
  case stale
  /// The person cancelled the prompt.
  case cancelled
  case failed(String)
}

/// The key the autofill copy is encrypted to (openspec: add-passwords, the code-autofill spec): a
/// P-256 key in the Secure Enclave, in a Keychain access group the app and
/// the extension share. Encrypting needs only its public half, so the app
/// writes the copy without a prompt; decrypting needs Face ID or Touch ID,
/// with the biometrics enrolled when the key was made. It never leaves the
/// phone.
enum AutofillKey {
  static let tag = Data("com.kemlock.app.autofill.key".utf8)
  static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

  /// The shared access group from Info.plist's `KemlockKeychainGroup`, or nil
  /// when the build has no team prefix to make it from (an unsigned build).
  static var accessGroup: String? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "KemlockKeychainGroup") as? String else { return nil }
    // "$(AppIdentifierPrefix)com.kemlock.app.shared" with an empty prefix leaves no team id in front.
    return group.hasPrefix("com.kemlock.") || group.isEmpty ? nil : group
  }

  /// The private key's reference, without using it; [context] answers its prompt when it is used.
  static func find(context: LAContext? = nil) -> SecKey? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]
    if let context { query[kSecUseAuthenticationContext as String] = context }
    var item: CFTypeRef?
    var status = SecItemCopyMatching(withGroup(query) as CFDictionary, &item)
    if status == errSecMissingEntitlement { status = SecItemCopyMatching(query as CFDictionary, &item) }
    guard status == errSecSuccess, let item else { return nil }
    return (item as! SecKey)  // swiftlint:disable:this force_cast
  }

  /// Makes a new key, replacing any earlier one.
  static func create() throws -> SecKey {
    delete()
    var error: Unmanaged<CFError>?
    #if targetEnvironment(simulator)
      // The simulator has no Secure Enclave: a key in the Keychain, behind the same biometrics.
      let flags: SecAccessControlCreateFlags = [.biometryCurrentSet]
    #else
      let flags: SecAccessControlCreateFlags = [.privateKeyUsage, .biometryCurrentSet]
    #endif
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, &error) else {
      throw AutofillKeyError.failed(describe(error))
    }
    var attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessControl as String: access,
      ] as [String: Any],
    ]
    #if !targetEnvironment(simulator)
      attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
    #endif
    if let key = SecKeyCreateRandomKey(withGroup(attributes) as CFDictionary, &error) { return key }
    // An unsigned or ad hoc build has no access group: the app's own Keychain then. Any other
    // failure is reported, since a key outside the group would be one the extension can't see.
    let failure = error?.takeRetainedValue()
    guard let failure, CFErrorGetCode(failure) == Int(errSecMissingEntitlement) else {
      throw AutofillKeyError.failed((failure as Error?)?.localizedDescription ?? "Keychain error")
    }
    error = nil
    if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) { return key }
    throw AutofillKeyError.failed(describe(error))
  }

  static func delete() {
    let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag]
    SecItemDelete(withGroup(query) as CFDictionary)
    SecItemDelete(query as CFDictionary)
  }

  /// [data] encrypted to [privateKey]'s public half; no prompt.
  static func encrypt(_ data: Data, to privateKey: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw AutofillKeyError.failed("No public key") }
    return try encrypt(data, toPublicKey: publicKey)
  }

  static func encrypt(_ data: Data, toPublicKey publicKey: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let sealed = SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, &error) else {
      throw AutofillKeyError.failed(describe(error))
    }
    return sealed as Data
  }

  /// [data] decrypted with [privateKey], which prompts unless its context was already evaluated.
  static func decrypt(_ data: Data, with privateKey: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let plain = SecKeyCreateDecryptedData(privateKey, algorithm, data as CFData, &error) else {
      let nsError = error?.takeRetainedValue() as Error? as NSError?
      if nsError?.code == Int(errSecUserCanceled) || nsError?.code == LAError.userCancel.rawValue { throw AutofillKeyError.cancelled }
      throw AutofillKeyError.failed(nsError?.localizedDescription ?? "Decryption failed")
    }
    return plain as Data
  }

  /// Whether the phone has Face ID or Touch ID set up.
  static func biometricsAvailable() -> Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  /// A fingerprint of the enrolled biometrics, which changes when a face or finger is added or removed.
  static func biometricState() -> Data? {
    let context = LAContext()
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
    if #available(iOS 18.0, *) { return context.domainState.biometry.stateHash }
    return context.evaluatedPolicyDomainState
  }

  /// Whether Face ID or Touch ID is locked after too many failed tries, until the passcode is
  /// typed. The enrolled biometrics can't be read meanwhile, and are as they were.
  static func biometricsLockedOut() -> Bool {
    var error: NSError?
    if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return false }
    return isLockout(error)
  }

  /// Whether [error], given for biometrics that can't be used, says they are locked.
  static func isLockout(_ error: NSError?) -> Bool {
    error?.domain == LAError.errorDomain && error?.code == LAError.biometryLockout.rawValue
  }

  private static func withGroup(_ query: [String: Any]) -> [String: Any] {
    guard let group = accessGroup else { return query }
    var grouped = query
    grouped[kSecAttrAccessGroup as String] = group
    return grouped
  }

  private static func describe(_ error: Unmanaged<CFError>?) -> String {
    (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "Keychain error"
  }
}
