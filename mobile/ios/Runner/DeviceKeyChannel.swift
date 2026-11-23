import CryptoKit
import Flutter
import Foundation
import Security

/// Why a device key couldn't be made or used, as `lib/platform/device_keys.dart` reads the error codes.
enum DeviceKeyError: Error, Equatable {
  /// The phone has no Secure Enclave (a simulator, some older phones).
  case unavailable(String)
  /// There is no key under the tag.
  case missing
  /// The Keychain or the Secure Enclave failed.
  case failed(String)

  var code: String {
    switch self {
    case .unavailable: return "unavailable"
    case .missing: return "missing"
    case .failed: return "failed"
    }
  }

  var message: String? {
    switch self {
    case .unavailable(let message), .failed(let message): return message
    case .missing: return nil
    }
  }

  static func from(_ error: Unmanaged<CFError>?, _ fallback: String) -> DeviceKeyError {
    guard let error = error?.takeRetainedValue() as Error? else { return .failed(fallback) }
    return .failed(error.localizedDescription)
  }
}

/// The Secure Enclave keys behind the Kemlock Server session: one P-256 key per tag, kept as a permanent key
/// whose application tag is `com.kemlock.app.devicekey.<tag>`. The key is accessible after the first unlock, on
/// this phone only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), and needs no user presence
/// (`.privateKeyUsage` alone), so a sync needs no prompt. A signing key signs DPoP proofs (ECDSA, SHA-256, DER);
/// a wrapping key wraps the trusted-device key by ECIES (X9.63, SHA-256, AES-GCM). The private half never leaves
/// the Secure Enclave.
enum DeviceKeychain {
  static let prefix = "com.kemlock.app.devicekey."
  static let eciesAlgorithm = SecKeyAlgorithm.eciesEncryptionStandardVariableIVX963SHA256AESGCM

  /// A tag of plain characters and a limited length, as the Android side takes.
  static func isValidTag(_ tag: String) -> Bool {
    guard (1...128).contains(tag.count) else { return false }
    return tag.unicodeScalars.allSatisfy { scalar in
      (scalar.value < 128) && (CharacterSet.alphanumerics.contains(scalar) || "_.:-".unicodeScalars.contains(scalar))
    }
  }

  static func applicationTag(_ tag: String) -> Data { Data((prefix + tag).utf8) }

  static func accessControl() throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error)
    else { throw DeviceKeyError.from(error, "Keychain error") }
    return access
  }

  /// What `SecKeyCreateRandomKey` is asked for: a permanent P-256 key in the Secure Enclave under [tag].
  static func creationAttributes(tag: String, access: SecAccessControl) -> [String: Any] {
    [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: applicationTag(tag),
        kSecAttrAccessControl as String: access,
      ] as [String: Any],
    ]
  }

  private static func lookup(_ tag: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: applicationTag(tag),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    ]
  }

  /// Makes the key under [tag], replacing any earlier one.
  static func create(_ tag: String) throws -> SecKey {
    guard SecureEnclave.isAvailable else { throw DeviceKeyError.unavailable("This phone has no Secure Enclave") }
    delete(tag)
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(creationAttributes(tag: tag, access: try accessControl()) as CFDictionary, &error) else {
      throw DeviceKeyError.from(error, "The Secure Enclave made no key")
    }
    return key
  }

  /// The private key under [tag], a reference into the Secure Enclave.
  static func privateKey(_ tag: String) throws -> SecKey {
    var query = lookup(tag)
    query[kSecReturnRef as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { throw DeviceKeyError.missing }
    guard status == errSecSuccess, let item else {
      throw DeviceKeyError.failed((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
    }
    return item as! SecKey  // swiftlint:disable:this force_cast
  }

  /// [key]'s public point, X9.63: 0x04, x, y.
  static func publicPoint(of key: SecKey) throws -> Data {
    guard let pub = SecKeyCopyPublicKey(key) else { throw DeviceKeyError.failed("The key has no public half") }
    var error: Unmanaged<CFError>?
    guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
      throw DeviceKeyError.from(error, "The public key can't be read")
    }
    return data
  }

  static func sign(_ tag: String, message: Data) throws -> Data {
    let key = try privateKey(tag)
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data? else {
      throw DeviceKeyError.from(error, "The Secure Enclave signed nothing")
    }
    return signature
  }

  static func wrap(_ tag: String, key: Data) throws -> Data {
    guard let pub = SecKeyCopyPublicKey(try privateKey(tag)) else { throw DeviceKeyError.failed("The key has no public half") }
    return try wrap(key, to: pub)
  }

  static func unwrap(_ tag: String, wrapped: Data) throws -> Data {
    try unwrap(wrapped, with: try privateKey(tag))
  }

  /// [key] wrapped by ECIES to [publicKey]: X9.63 key agreement and KDF with SHA-256, AES-GCM, the IV in the output. A
  /// key that isn't in the Secure Enclave wraps the same way, which is how the unit test runs it.
  static func wrap(_ key: Data, to publicKey: SecKey) throws -> Data {
    guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, eciesAlgorithm) else { throw DeviceKeyError.failed("The key can't wrap") }
    var error: Unmanaged<CFError>?
    guard let wrapped = SecKeyCreateEncryptedData(publicKey, eciesAlgorithm, key as CFData, &error) as Data? else {
      throw DeviceKeyError.from(error, "The key wrapped nothing")
    }
    return wrapped
  }

  /// What [wrap(_:to:)] returned, opened with the private key: another key, or a changed byte, throws.
  static func unwrap(_ wrapped: Data, with privateKey: SecKey) throws -> Data {
    guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, eciesAlgorithm) else { throw DeviceKeyError.failed("The key can't unwrap") }
    var error: Unmanaged<CFError>?
    guard let opened = SecKeyCreateDecryptedData(privateKey, eciesAlgorithm, wrapped as CFData, &error) as Data? else {
      throw DeviceKeyError.from(error, "The wrapped key doesn't open")
    }
    return opened
  }

  static func delete(_ tag: String) {
    SecItemDelete(lookup(tag) as CFDictionary)
  }
}

/// The phone's side of `lib/platform/device_keys.dart`, `com.kemlock.app/device_keys`. Secure Enclave work can
/// take a moment, so it runs off the main thread, one call at a time.
final class DeviceKeyChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/device_keys", binaryMessenger: registrar.messenger())
    let handler = DeviceKeyChannel()
    channel.setMethodCallHandler { call, result in handler.handle(call, result: result) }
  }

  private let queue = DispatchQueue(label: "com.kemlock.app.devicekeys")

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "hardware" { return result(SecureEnclave.isAvailable) }
    let arguments = call.arguments as? [String: Any] ?? [:]
    guard let tag = arguments["tag"] as? String, DeviceKeychain.isValidTag(tag) else {
      return result(FlutterError(code: "failed", message: "No valid tag", details: nil))
    }
    func data(_ name: String) -> Data? { (arguments[name] as? FlutterStandardTypedData)?.data }
    func answer(_ work: @escaping () throws -> Any?) {
      queue.async {
        let outcome = Result { try work() }
        DispatchQueue.main.async {
          switch outcome {
          case .success(let value): result(value)
          case .failure(let error):
            let failure = error as? DeviceKeyError ?? .failed(error.localizedDescription)
            result(FlutterError(code: failure.code, message: failure.message, details: nil))
          }
        }
      }
    }
    switch call.method {
    case "create":
      answer {
        let key = try DeviceKeychain.create(tag)
        return ["protection": "secure-enclave", "point": FlutterStandardTypedData(bytes: try DeviceKeychain.publicPoint(of: key))] as [String: Any]
      }
    case "info":
      answer {
        do {
          let key = try DeviceKeychain.privateKey(tag)
          return ["protection": "secure-enclave", "point": FlutterStandardTypedData(bytes: try DeviceKeychain.publicPoint(of: key))] as [String: Any]
        } catch DeviceKeyError.missing {
          return nil
        }
      }
    case "sign":
      guard let message = data("message") else { return result(FlutterError(code: "failed", message: "No message", details: nil)) }
      answer { FlutterStandardTypedData(bytes: try DeviceKeychain.sign(tag, message: message)) }
    case "wrap":
      guard let key = data("data") else { return result(FlutterError(code: "failed", message: "No data", details: nil)) }
      answer { FlutterStandardTypedData(bytes: try DeviceKeychain.wrap(tag, key: key)) }
    case "unwrap":
      guard let wrapped = data("data") else { return result(FlutterError(code: "failed", message: "No data", details: nil)) }
      answer { FlutterStandardTypedData(bytes: try DeviceKeychain.unwrap(tag, wrapped: wrapped)) }
    case "delete":
      answer {
        DeviceKeychain.delete(tag)
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
