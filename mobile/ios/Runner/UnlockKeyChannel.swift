import Flutter
import Foundation
import LocalAuthentication
import Security

/// Why the unlock key couldn't be made or given out, as `lib/platform/unlock_keys.dart` reads
/// the error codes.
enum UnlockKeyError: Error, Equatable {
  /// The person cancelled the prompt.
  case cancelled
  /// The key no longer opens: biometrics changed, the passcode was removed, or the item is gone.
  case invalidated
  /// The phone has no Face ID or Touch ID set up, or no passcode.
  case unavailable
  /// The prompt itself failed: a lockout after too many tries, a failed match, a prompt that
  /// couldn't show. Dart opens nothing else in its place, where `failed` lets an old entry open
  /// the vault behind local_auth's prompt.
  case promptFailed(String)
  /// The Keychain failed.
  case failed(String)

  var code: String {
    switch self {
    case .cancelled: return "cancelled"
    case .invalidated: return "invalidated"
    case .unavailable: return "unavailable"
    case .promptFailed: return "prompt"
    case .failed: return "failed"
    }
  }

  var message: String? {
    switch self {
    case .promptFailed(let message), .failed(let message): return message
    case .cancelled, .invalidated, .unavailable: return nil
    }
  }

  /// What a failed `canEvaluatePolicy` or `evaluatePolicy` means. With [opening], no biometrics
  /// or no passcode means the key is gone: `.biometryCurrentSet` items stop opening when the
  /// biometrics change, and the passcode's removal deletes them.
  static func from(_ error: Error?, opening: Bool) -> UnlockKeyError {
    guard let error = error as NSError?, error.domain == LAError.errorDomain else {
      return .failed((error as NSError?)?.localizedDescription ?? "Biometric check failed")
    }
    switch LAError.Code(rawValue: error.code) {
    case .userCancel, .systemCancel, .appCancel, .userFallback:
      return .cancelled
    case .biometryNotEnrolled, .passcodeNotSet:
      return opening ? .invalidated : .unavailable
    case .biometryNotAvailable:
      return .unavailable
    default:
      // A lockout, a failed match, a prompt that couldn't show: the prompt's own failure
      return .promptFailed(error.localizedDescription)
    }
  }

  /// What a Keychain read or write that returned [status] means. A read whose prompt failed,
  /// a lockout or a face that didn't match, says `errSecAuthFailed`.
  static func from(_ status: OSStatus) -> UnlockKeyError? {
    switch status {
    case errSecSuccess: return nil
    case errSecUserCanceled: return .cancelled
    case errSecItemNotFound: return .invalidated
    case errSecAuthFailed:
      return .promptFailed((SecCopyErrorMessageString(status, nil) as String?) ?? "Biometric check failed")
    default:
      return .failed((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
    }
  }
}

/// The Keychain items behind biometric unlock: one generic password per vault, service
/// [service], account the vault id, data its 32-byte seal key. An item opens only after Face ID
/// or Touch ID with the biometrics enrolled when it was written (`.biometryCurrentSet`), while the
/// phone has a passcode, on this phone only, and is never synced. It sits in the app's own access
/// group, which the AutoFill extension doesn't share: the extension never opens the vault.
///
/// The item's `kSecAttrGeneric` keeps a fingerprint of the enrolled biometrics, readable without
/// a prompt, so a change is caught before the prompt shows, however iOS reports the read.
enum UnlockKeychain {
  static let service = "com.kemlock.app.unlock"

  /// The app's own access group from Info.plist's `KemlockUnlockKeychainGroup`, or nil when the
  /// build has no team prefix to make it from (an unsigned build), where the default group is used.
  static var accessGroup: String? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "KemlockUnlockKeychainGroup") as? String else { return nil }
    // "$(AppIdentifierPrefix)com.kemlock.app" with an empty prefix leaves no team id in front.
    return group.hasPrefix("com.kemlock.") || group.isEmpty ? nil : group
  }

  private static func query(_ vault: String?) -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    if let vault { query[kSecAttrAccount as String] = vault }
    if let group = accessGroup { query[kSecAttrAccessGroup as String] = group }
    return query
  }

  /// Puts [key] in [vault]'s item, replacing any earlier one; [state] is the biometrics' fingerprint.
  static func write(_ key: Data, vault: String, state: Data?) throws {
    delete(vault)
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
      throw UnlockKeyError.failed((error?.takeRetainedValue() as Error?)?.localizedDescription ?? "Keychain error")
    }
    var item = query(vault)
    item[kSecValueData as String] = key
    item[kSecAttrAccessControl as String] = access
    item[kSecAttrSynchronizable as String] = kCFBooleanFalse
    if let state { item[kSecAttrGeneric as String] = state }
    if let failure = UnlockKeyError.from(SecItemAdd(item as CFDictionary, nil)) {
      // A missing item can't be what adding one says: anything here is a failure
      throw failure == .invalidated ? UnlockKeyError.failed("Keychain error") : failure
    }
  }

  /// [vault]'s item's attributes, read without a prompt, or nil when there is none.
  static func attributes(_ vault: String) -> [String: Any]? {
    let context = LAContext()
    context.interactionNotAllowed = true
    var read = query(vault)
    read[kSecReturnAttributes as String] = true
    read[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? [String: Any]
  }

  /// Whether [vault]'s item was written with the biometrics enrolled now, whose fingerprint is [state].
  static func isCurrent(_ vault: String, state: Data?) -> Bool {
    guard let stored = attributes(vault) else { return false }
    guard let written = stored[kSecAttrGeneric as String] as? Data, let state else { return true }
    return written == state
  }

  /// [vault]'s key; [context] shows the prompt, with its `localizedReason`.
  static func read(_ vault: String, context: LAContext) throws -> Data {
    var read = query(vault)
    read[kSecReturnData as String] = true
    read[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    if let failure = UnlockKeyError.from(SecItemCopyMatching(read as CFDictionary, &item)) { throw failure }
    guard let key = item as? Data, key.count == 32 else { throw UnlockKeyError.failed("The Keychain item holds no key") }
    return key
  }

  static func delete(_ vault: String) {
    SecItemDelete(query(vault) as CFDictionary)
  }

  /// Deletes every vault's item, and nothing outside [service].
  static func deleteAll() {
    SecItemDelete(query(nil) as CFDictionary)
  }
}

/// The phone's side of `lib/platform/unlock_keys.dart`, `com.kemlock.app/unlock`. `seal` checks
/// Face ID or Touch ID with an `LAContext` before writing, so turning biometric unlock on proves
/// the person can pass; `open` hands the context to the Keychain read, which shows the prompt.
/// Biometrics only: the device passcode never passes.
///
/// It also answers `elapsed`, the milliseconds of `CLOCK_MONOTONIC_RAW`, the clock auto-lock
/// counts idle time with: it keeps counting while the phone sleeps (`ProcessInfo.systemUptime`
/// doesn't), and setting the date doesn't move it.
final class UnlockKeyChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/unlock", binaryMessenger: registrar.messenger())
    let handler = UnlockKeyChannel()
    channel.setMethodCallHandler { call, result in handler.handle(call, result: result) }
  }

  /// Keychain reads wait for the prompt, so they run here, off the main thread, one at a time.
  private let queue = DispatchQueue(label: "com.kemlock.app.unlock")

  /// Whether the phone has Face ID or Touch ID set up, with a passcode.
  static func status() -> Bool { AutofillKey.biometricsAvailable() }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let vault = arguments["vault"] as? String
    let reason = arguments["reason"] as? String ?? ""
    func answer(_ outcome: Result<Any?, UnlockKeyError>) {
      DispatchQueue.main.async {
        switch outcome {
        case .success(let value): result(value)
        case .failure(let error): result(FlutterError(code: error.code, message: error.message, details: nil))
        }
      }
    }
    switch call.method {
    case "elapsed":
      result(NSNumber(value: Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)))
    case "status":
      result(Self.status())
    case "seal":
      guard let vault, let key = (arguments["key"] as? FlutterStandardTypedData)?.data, key.count == 32 else {
        return answer(.failure(.failed("No vault or key")))
      }
      seal(key, vault: vault, reason: reason) { outcome in answer(outcome.map { _ -> Any? in "" }) }
    case "open":
      guard let vault else { return answer(.failure(.failed("No vault"))) }
      queue.async {
        let opened = Result { try Self.open(vault, reason: reason) }.mapError(Self.unlockError)
        answer(opened.map { key -> Any? in FlutterStandardTypedData(bytes: key) })
      }
    case "delete":
      guard let vault else { return result(nil) }
      queue.async {
        UnlockKeychain.delete(vault)
        answer(.success(nil))
      }
    case "deleteAll":
      queue.async {
        UnlockKeychain.deleteAll()
        answer(.success(nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func unlockError(_ error: Error) -> UnlockKeyError {
    error as? UnlockKeyError ?? .failed(error.localizedDescription)
  }

  private func seal(_ key: Data, vault: String, reason: String, done: @escaping (Result<Void, UnlockKeyError>) -> Void) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      return done(.failure(UnlockKeyError.from(error, opening: false)))
    }
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { passed, error in
      guard passed else { return done(.failure(UnlockKeyError.from(error, opening: false))) }
      self.queue.async {
        done(Result { try UnlockKeychain.write(key, vault: vault, state: AutofillKey.biometricState()) }.mapError(Self.unlockError))
      }
    }
  }

  /// [vault]'s key, after the prompt the Keychain read shows. An item written with other
  /// biometrics, or none, is deleted: it would never open again.
  static func open(_ vault: String, reason: String) throws -> Data {
    let context = LAContext()
    context.localizedReason = reason
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      let failure = UnlockKeyError.from(error, opening: true)
      if failure == .invalidated { UnlockKeychain.delete(vault) }
      throw failure
    }
    guard UnlockKeychain.isCurrent(vault, state: AutofillKey.biometricState()) else {
      UnlockKeychain.delete(vault)
      throw UnlockKeyError.invalidated
    }
    do {
      return try UnlockKeychain.read(vault, context: context)
    } catch UnlockKeyError.invalidated {
      UnlockKeychain.delete(vault)
      throw UnlockKeyError.invalidated
    }
  }
}
