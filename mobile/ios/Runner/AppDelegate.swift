import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The ground colour laid over the app while it is inactive, so the app switcher snapshot shows
  /// no codes. Nothing shows through it, as large digits might through a blur.
  private var privacyCover: UIView?

  /// The app's ground colour for the phone's appearance: `Ground` in lib/ui/theme/tokens.dart.
  private static let ground = UIColor { traits in
    if traits.userInterfaceStyle == .dark {
      return UIColor(red: 10 / 255, green: 11 / 255, blue: 13 / 255, alpha: 1)
    }
    return UIColor(red: 244 / 255, green: 244 / 255, blue: 241 / 255, alpha: 1)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Notifications rather than SceneDelegate overrides, so FlutterSceneDelegate still tells plugins.
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(coverCodes(_:)), name: UIScene.willDeactivateNotification, object: nil)
    center.addObserver(self, selector: #selector(uncoverCodes), name: UIScene.didActivateNotification, object: nil)
    // Key reminders: flutter_local_notifications shows and answers notifications through the app delegate.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// No keyboard of another app is shown in Kemlock: iOS keeps them out of hidden password fields
  /// only, and a secret typed by hand, a note or a password being shown would go through one that
  /// may send what is typed elsewhere. FlutterAppDelegate has no answer of its own to call.
  override func application(
    _ application: UIApplication,
    shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
  ) -> Bool {
    extensionPointIdentifier != .keyboard
  }

  /// APNs gave this phone its token (PushChannel). The plugins are told too, as FlutterAppDelegate does.
  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    PushChannel.shared.registered(deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushChannel.shared.registrationFailed()
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// A push from the relay: a `sync` or `approval` nudge, sent with `content-available` so it reaches the app in
  /// front or behind. Nothing is fetched here; Dart decides, and only while the vault is open.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    PushChannel.shared.received(userInfo)
    super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockAutofill") {
      AutofillChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockUnlockKeys") {
      UnlockKeyChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockDeviceKeys") {
      DeviceKeyChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockBrowserAuth") {
      BrowserAuthChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockPush") {
      PushChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockClipboard") {
      SecretPasteboard.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockSetupLinks") {
      SetupLinks.shared.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockSecurityKeys") {
      SecurityKeyChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockSharedItems") {
      SharedItemsChannel.shared.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KemlockCredentialExchange") {
      CredentialExchangeChannel.shared.register(with: registrar)
    }
  }

  /// iOS takes the app switcher snapshot after the scene resigns active, so the codes are covered now.
  @objc private func coverCodes(_ notification: Notification) {
    guard privacyCover == nil,
      let scene = notification.object as? UIWindowScene,
      let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    else { return }
    let cover = UIView(frame: window.bounds)
    cover.backgroundColor = AppDelegate.ground
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(cover)
    privacyCover = cover
  }

  @objc private func uncoverCodes() {
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }
}
