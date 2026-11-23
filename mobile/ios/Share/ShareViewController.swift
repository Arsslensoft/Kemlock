import UIKit
import UniformTypeIdentifiers

/// Kemlock in the share sheet (openspec: add-share-extension, decisions 1, 3 and 6). It takes one
/// text or one file, writes it to the App Group (SharedItemFile) and says to open Kemlock, which
/// finds the item when it comes to the front, within ten minutes. It holds no key, asks for no
/// password and never reads the vault: opening a vault takes more memory than iOS gives an
/// extension, and the app does the work with the vault it has always used. A file is copied on
/// disk, never read into memory, so its size doesn't matter here.
///
/// It doesn't open the app itself. The only way it could was a custom URL scheme, `kemlock://`,
/// and iOS lets any app register the same scheme without saying which one a link then opens:
/// another app could take the share's place and show a lock screen of its own to collect the
/// master password. Opening Kemlock by hand, from its icon, can't be taken over.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let message = UILabel()
  private let done = UIButton(type: .system)
  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let mark = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
    mark.tintColor = .systemBlue
    mark.contentMode = .scaleAspectFit
    mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
    mark.isAccessibilityElement = false

    message.text = NSLocalizedString("saving", comment: "")
    message.font = .preferredFont(forTextStyle: .headline)
    message.adjustsFontForContentSizeCategory = true
    message.textAlignment = .center
    message.numberOfLines = 0

    done.setTitle(NSLocalizedString("done", comment: ""), for: .normal)
    done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    done.isHidden = true
    done.addTarget(self, action: #selector(finish), for: .touchUpInside)

    spinner.startAnimating()

    let stack = UIStackView(arrangedSubviews: [mark, spinner, message, done])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    Task { await hand() }
  }

  /// Takes the shared item, writes it for the app and says to open Kemlock. First, whatever an
  /// earlier share left that the app never took is deleted once it is ten minutes old, as the app
  /// does when it is opened: an item must not wait in the clear for an app that is never opened.
  @MainActor
  private func hand() async {
    let files = SharedItemFile.shared()
    _ = files?.sweep()
    let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    guard attachments.count == 1, let provider = attachments.first else { return say("oneItem") }
    guard let files else { return say("unreadable") }
    do {
      _ = try await write(provider, to: files)
    } catch {
      return say("unreadable")
    }
    say("openApp")
  }

  /// A text, or a file copied where it lies; the item's id.
  private func write(_ provider: NSItemProvider, to files: SharedItemFile) async throws -> String {
    let types = provider.registeredTypeIdentifiers
    // Safari shares a page as `public.url`, with its title as the suggested name, which would make it a file the
    // app can't read. An `https` address is taken as text, where the app finds a Send link in it.
    if SharedItemFile.reading(types: types, hasSuggestedName: provider.suggestedName != nil) == .webLink,
      let url = try? await loadURL(provider), let text = SharedItemFile.webLinkText(url)
    {
      return try files.write(text: text)
    }
    let isFile = types.contains(UTType.fileURL.identifier) || provider.suggestedName != nil
    if !isFile, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      let text = try await loadText(provider)
      return try files.write(text: text)
    }
    let type = types.first { $0 != UTType.fileURL.identifier } ?? UTType.data.identifier
    let mime = UTType(type)?.preferredMIMEType
    return try await withCheckedThrowingContinuation { continuation in
      // The URL is valid only inside the handler: the file is copied there, on disk
      _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        guard let url else { return continuation.resume(throwing: error ?? SharedItemFile.Problem.unreadable) }
        let name = provider.suggestedName.map { name in
          url.pathExtension.isEmpty || name.hasSuffix(".\(url.pathExtension)") ? name : "\(name).\(url.pathExtension)"
        } ?? url.lastPathComponent
        do {
          continuation.resume(returning: try files.write(fileAt: url, name: name, type: mime))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func loadURL(_ provider: NSItemProvider) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
        switch item {
        case let url as URL: continuation.resume(returning: url)
        case let text as String:
          guard let url = URL(string: text) else { return continuation.resume(throwing: SharedItemFile.Problem.unreadable) }
          continuation.resume(returning: url)
        case let data as Data:
          guard let text = String(data: data, encoding: .utf8), let url = URL(string: text) else {
            return continuation.resume(throwing: SharedItemFile.Problem.unreadable)
          }
          continuation.resume(returning: url)
        default: continuation.resume(throwing: error ?? SharedItemFile.Problem.unreadable)
        }
      }
    }
  }

  private func loadText(_ provider: NSItemProvider) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
        switch item {
        case let text as String: continuation.resume(returning: text)
        case let text as NSAttributedString: continuation.resume(returning: text.string)
        case let data as Data:
          guard let text = String(data: data, encoding: .utf8) else {
            return continuation.resume(throwing: SharedItemFile.Problem.unreadable)
          }
          continuation.resume(returning: text)
        default: continuation.resume(throwing: error ?? SharedItemFile.Problem.unreadable)
        }
      }
    }
  }

  /// Shows [key]'s message with Done in place of the spinner.
  private func say(_ key: String) {
    spinner.stopAnimating()
    spinner.isHidden = true
    message.text = NSLocalizedString(key, comment: "")
    done.isHidden = false
    UIAccessibility.post(notification: .screenChanged, argument: message)
  }

  @objc private func finish() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
