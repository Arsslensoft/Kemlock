import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// The app opened with a set-up link (SetupLinks), by the Share extension (SharedItemsChannel), or by another
  /// app's export (CredentialExchangeChannel).
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    connectionOptions.urlContexts.forEach { SetupLinks.shared.arrived($0.url) }
    connectionOptions.urlContexts.forEach { SharedItemsChannel.shared.arrived($0.url) }
    connectionOptions.userActivities.forEach { CredentialExchangeChannel.shared.arrived($0) }
  }

  /// A set-up link, or a shared item, handed over while the app runs.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    URLContexts.forEach { SetupLinks.shared.arrived($0.url) }
    URLContexts.forEach { SharedItemsChannel.shared.arrived($0.url) }
  }

  /// Another app's export, on iOS 26 and later, while the app runs: the system continues the activity that holds
  /// the import token (the cold start is `scene(_:willConnectTo:)`).
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    CredentialExchangeChannel.shared.arrived(userActivity)
  }
}
