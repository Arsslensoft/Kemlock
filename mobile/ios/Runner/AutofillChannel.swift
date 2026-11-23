import AuthenticationServices
import Flutter
import Foundation

/// The phone's side of `lib/platform/autofill.dart`: whether iOS fills from
/// Kemlock's AutoFill extension, turning it on, and the files the extension
/// reads (see AutofillStore), with the copy encrypted here to the key the
/// Secure Enclave holds; and the passkeys and logins the extension saved,
/// waiting in the inboxes. Filling codes and passkeys needs iOS 18; before it the app
/// says it can't, and writes nothing.
final class AutofillChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/autofill", binaryMessenger: registrar.messenger())
    let handler = AutofillChannel()
    channel.setMethodCallHandler { call, result in handler.handle(call, result: result) }
  }

  /// The files the extension reads; another folder in the tests.
  private let store: AutofillStore

  init(store: AutofillStore = .shared()) {
    self.store = store
  }

  /// File and Keychain work runs here, off the main thread, one call at a time.
  private let queue = DispatchQueue(label: "com.kemlock.app.autofill")

  /// Whether this build's extension says it provides passkeys.
  static var extensionProvidesPasskeys: Bool { extensionCapability("ProvidesPasskeys") }

  /// Whether this phone suggests strong passwords from Kemlock and saves new
  /// logins to it: iOS 26.2 and later, with an extension that says it saves
  /// them. Before, logins are only filled.
  static var savesPasswords: Bool {
    guard #available(iOS 26.2, *) else { return false }
    return extensionCapability("SupportsSavePasswordCredentials")
  }

  /// Whether this build's extension declares the capability [key].
  private static func extensionCapability(_ key: String) -> Bool {
    guard let plugins = Bundle.main.builtInPlugInsURL,
      let info = NSDictionary(contentsOf: plugins.appendingPathComponent("AutoFill.appex/Info.plist")),
      let attributes = (info["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any],
      let capabilities = attributes["ASCredentialProviderExtensionCapabilities"] as? [String: Any]
    else { return false }
    return capabilities[key] as? Bool == true
  }

  /// The name the lock screen shows for [vault], from the vault's config in
  /// the app's preferences (`VaultRegistry.vaultName`), or nil for none.
  static func vaultName(_ vault: String, defaults: UserDefaults = .standard) -> String? {
    let key = "CapacitorStorage.backmycodes_vault_config" + (vault == "main" ? "" : "::\(vault)")
    guard let raw = defaults.string(forKey: key), let config = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
      let name = config["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return name
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 18.0, *) else {
      switch call.method {
      case "status": result(["supported": false, "enabled": false, "biometrics": false, "chromeNeedsSetting": false, "savesPasswords": false])
      case "passkeyStatus": result(["supported": false, "enabled": false])
      case "turnOn", "openChromeSettings", "openPasskeySettings": result(false)
      case "readInbox": result([])
      default: result(nil)
      }
      return
    }
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status":
      ASCredentialIdentityStore.shared.getState { state in
        let status: [String: Any] = [
          "supported": true,
          "enabled": state.isEnabled,
          "biometrics": AutofillKey.biometricsAvailable(),
          "chromeNeedsSetting": false,
          "savesPasswords": Self.savesPasswords,
        ]
        DispatchQueue.main.async { result(status) }
      }
    case "turnOn":
      ASSettingsHelper.requestToTurnOnCredentialProviderExtension { enabled in
        if enabled { IdentitySync.refresh() }
        DispatchQueue.main.async { result(enabled) }
      }
    case "openChromeSettings":
      result(false)
    case "passkeyStatus":
      let supported = Self.extensionProvidesPasskeys
      ASCredentialIdentityStore.shared.getState { state in
        let status: [String: Any] = ["supported": supported, "enabled": supported && state.isEnabled]
        DispatchQueue.main.async { result(status) }
      }
    case "openPasskeySettings":
      ASSettingsHelper.openCredentialProviderAppSettings { error in
        DispatchQueue.main.async { result(error == nil) }
      }
    case "writeVault":
      guard let vault = arguments["vault"] as? String, let copy = arguments["copy"] as? String else {
        return result(FlutterError(code: "writeFailed", message: "writeVault needs a vault and a copy", details: nil))
      }
      let index = arguments["index"] as? String
      // The inbox key comes with the copy while passkeys or saving logins are on
      let inboxText = arguments["inboxKey"] as? String
      let inboxKey = inboxText.flatMap { Data(base64Encoded: $0) }
      if inboxText != nil, inboxKey?.count != 65 || inboxKey?.first != 4 {
        return result(FlutterError(code: "writeFailed", message: "The inbox key isn't a P-256 point", details: nil))
      }
      // What else the extension may do with the vault; an app from before passwords sends none
      let takes = (arguments["takes"] as? [String: Any]).map(VaultTakes.init(item:))
      let name = Self.vaultName(vault)
      let store = self.store
      queue.async {
        do {
          try store.writeVault(vault, copy: Data(copy.utf8), index: index.map { Data($0.utf8) }, inboxKey: inboxKey, takes: takes, name: name)
          IdentitySync.refresh(store)
          DispatchQueue.main.async { result(nil) }
        } catch AutofillKeyError.noBiometrics {
          DispatchQueue.main.async { result(FlutterError(code: "noBiometrics", message: "No Face ID or Touch ID set up", details: nil)) }
        } catch AutofillKeyError.failed(let message) {
          DispatchQueue.main.async { result(FlutterError(code: "keyFailed", message: message, details: nil)) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "writeFailed", message: error.localizedDescription, details: nil)) }
        }
      }
    case "readInbox":
      guard let vault = arguments["vault"] as? String else { return result([]) }
      let store = self.store
      queue.async {
        let files = store.inbox(vault).map { ["name": $0.name, "content": $0.content] }
        DispatchQueue.main.async { result(files) }
      }
    case "clearInbox":
      guard let vault = arguments["vault"] as? String, let names = arguments["names"] as? [String] else { return result(nil) }
      let store = self.store
      queue.async {
        store.clearInbox(vault, names: names)
        DispatchQueue.main.async { result(nil) }
      }
    case "removeVault":
      guard let vault = arguments["vault"] as? String, AutofillStore.isVaultId(vault) else { return result(nil) }
      let store = self.store
      queue.async {
        store.removeVault(vault)
        IdentitySync.refresh(store)
        DispatchQueue.main.async { result(nil) }
      }
    case "removeAll":
      let store = self.store
      queue.async {
        store.removeEverything()
        IdentitySync.clear()
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
