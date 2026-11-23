import Flutter
import UIKit

/// Hands what the Share extension wrote to lib/platform/shared_items.dart (openspec:
/// add-share-extension, decision 6), as SetupLinks hands links: the item the app was opened with,
/// asked for once, and those that arrive while it runs. A `kemlock://share/<id>` link names the
/// item; on every launch and return to the front the App Group's `Share/` folder is swept of
/// anything ten minutes old, and the newest younger item is handed over when no link named one,
/// for when the extension could not open the app. A text is read and handed over; a file is moved
/// into the app's own `share/` temporary directory, which is Dart's `getTemporaryDirectory()` (the
/// Caches directory), and its path handed over. Both hand-over files are gone after.
final class SharedItemsChannel {
  static let shared = SharedItemsChannel()

  private var channel: FlutterMethodChannel?
  private var observer: NSObjectProtocol?

  /// What the app was opened with, until Dart asks for it.
  private(set) var initial: [String: Any]?
  private var asked = false

  private let files: SharedItemFile?
  private let root: URL
  private let now: () -> Date

  init(
    files: SharedItemFile? = SharedItemFile.shared(),
    root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("share", isDirectory: true),
    now: @escaping () -> Date = Date.init
  ) {
    self.files = files
    self.root = root
    self.now = now
  }

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/share", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "initial":
        result(self.initial)
        self.initial = nil
        self.asked = true
      case "clear":
        self.clear()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    // Launch and every return to the front, as the app's privacy cover listens for them
    observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) {
      [weak self] _ in self?.cameToFront()
    }
    cameToFront()
  }

  /// A link the scene was opened with or handed; true when it named a shared item, which is then
  /// handed over if it is still there.
  @discardableResult
  func arrived(_ url: URL) -> Bool {
    guard let id = SharedItemFile.id(fromLink: url) else { return false }
    hand(files?.take(id, into: root, now: now()))
    return true
  }

  /// Sweeps `Share/` and hands over the newest item younger than ten minutes, if one waits.
  func cameToFront() {
    guard let files, let id = files.sweep(now: now()) else { return }
    hand(files.take(id, into: root, now: now()))
  }

  /// Every vault was erased: nothing of a share stays in the App Group.
  func clear() {
    files?.clear()
    initial = nil
  }

  private func hand(_ taken: SharedItemFile.Taken?) {
    guard let taken else { return }
    let map = taken.channelMap
    if asked, let channel {
      channel.invokeMethod("item", arguments: map)
    } else {
      initial = map
    }
  }
}
