import XCTest

@testable import Runner

/// The hand-over of a shared item from the Share extension to the app (openspec:
/// add-share-extension, decision 6): what the extension writes into the App Group, and what the
/// app's channel takes from it, in folders of the test's own.
final class SharedItemTests: XCTestCase {
  private var base: URL!
  private var files: SharedItemFile!
  private var root: URL!
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    files = SharedItemFile(folder: base.appendingPathComponent("Share", isDirectory: true))
    root = base.appendingPathComponent("caches/share", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  private func contents(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private func meta(_ id: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files.metaURL(id))) as? [String: Any])
  }

  /// A file another app shares, on disk.
  private func source(_ name: String, _ text: String) throws -> URL {
    let url = base.appendingPathComponent("source/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  // MARK: The extension writes

  func testATextWritesTheTwoFilesWithItsDescription() throws {
    let id = try files.write(text: "Meet me at nine.", now: now)

    XCTAssertEqual(contents(files.folder), ["\(id).item", "\(id).json"].sorted())
    XCTAssertEqual(try String(contentsOf: files.itemURL(id), encoding: .utf8), "Meet me at nine.")
    let json = try meta(id)
    XCTAssertEqual(json["v"] as? Int, 1)
    XCTAssertEqual(json["kind"] as? String, "text")
    XCTAssertEqual(json["type"] as? String, "text/plain")
    XCTAssertEqual((json["at"] as? NSNumber)?.int64Value, 1_800_000_000_000)
    XCTAssertNil(json["name"])
  }

  func testAFileIsCopiedWithItsNameAndType() throws {
    let id = try files.write(fileAt: try source("contract.pdf", "%PDF-1.7"), name: "../contract.pdf", type: "application/pdf", now: now)

    XCTAssertEqual(try String(contentsOf: files.itemURL(id), encoding: .utf8), "%PDF-1.7")
    let json = try meta(id)
    XCTAssertEqual(json["kind"] as? String, "file")
    XCTAssertEqual(json["name"] as? String, "contract.pdf")
    XCTAssertEqual(json["type"] as? String, "application/pdf")
    XCTAssertEqual((json["at"] as? NSNumber)?.int64Value, 1_800_000_000_000)
  }

  func testBothFilesAreProtectedAndOutOfBackups() throws {
    for id in [try files.write(text: "Meet me at nine.", now: now), try files.write(fileAt: try source("a.pdf", "x"), name: "a.pdf", type: nil, now: now)] {
      for url in [files.itemURL(id), files.metaURL(id)] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete, url.lastPathComponent)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, url.lastPathComponent)
      }
    }
  }

  func testACopyThatFailsLeavesNeitherFile() throws {
    let missing = base.appendingPathComponent("source/withdrawn.pdf")

    XCTAssertThrowsError(try files.write(fileAt: missing, name: "withdrawn.pdf", type: nil, now: now)) { error in
      XCTAssertEqual(error as? SharedItemFile.Problem, .unreadable)
    }
    XCTAssertEqual(contents(files.folder), [])
  }

  // MARK: The app takes

  func testReadingATextDeletesBothFiles() throws {
    let id = try files.write(text: "Meet me at nine.", now: now)

    XCTAssertEqual(files.take(id, into: root, now: now.addingTimeInterval(5)), .text("Meet me at nine.", at: 1_800_000_000_000))
    XCTAssertEqual(contents(files.folder), [])
  }

  func testAFileIsMovedIntoTheAppsShareDirectory() throws {
    let id = try files.write(fileAt: try source("contract.pdf", "%PDF-1.7"), name: "contract.pdf", type: "application/pdf", now: now)

    guard case .file(let path, let name, let size, let type, let at) = files.take(id, into: root, now: now.addingTimeInterval(5)) else {
      return XCTFail("no file")
    }
    XCTAssertEqual(name, "contract.pdf")
    XCTAssertEqual(size, 8)
    XCTAssertEqual(type, "application/pdf")
    XCTAssertEqual(at, 1_800_000_000_000)
    XCTAssertTrue(path.hasPrefix(root.path))
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "%PDF-1.7")
    XCTAssertEqual(contents(files.folder), [])
  }

  func testAnItemElevenMinutesOldIsDeletedAndNotHandedOver() throws {
    let old = try files.write(text: "an old one", now: now)
    let young = try files.write(text: "a young one", now: now.addingTimeInterval(2 * 60))
    let later = now.addingTimeInterval(11 * 60)

    XCTAssertEqual(files.sweep(now: later), young)
    XCTAssertFalse(FileManager.default.fileExists(atPath: files.itemURL(old).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: files.metaURL(old).path))
    XCTAssertNil(files.take(old, into: root, now: later))
    XCTAssertEqual(files.take(young, into: root, now: later), .text("a young one", at: SharedItemFile.millis(now.addingTimeInterval(2 * 60))))
  }

  func testTheChannelHandsOverTheNewestYoungerItemOnReturnToTheFront() throws {
    let channel = SharedItemsChannel(files: files, root: root, now: { self.now.addingTimeInterval(11 * 60) })
    _ = try files.write(text: "an old one", now: now)
    _ = try files.write(text: "the newest", now: now.addingTimeInterval(10 * 60))

    channel.cameToFront()

    XCTAssertEqual(channel.initial?["text"] as? String, "the newest")
    XCTAssertEqual(contents(files.folder), [])
  }

  func testClearEmptiesTheFolder() throws {
    let channel = SharedItemsChannel(files: files, root: root, now: { self.now })
    _ = try files.write(text: "Meet me at nine.", now: now)
    _ = try files.write(fileAt: try source("a.pdf", "x"), name: "a.pdf", type: nil, now: now)

    channel.clear()

    XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path))
  }

  func testALinkNamingAMissingIdHandsOverNothing() throws {
    let channel = SharedItemsChannel(files: files, root: root, now: { self.now })

    XCTAssertTrue(channel.arrived(SharedItemFile.link(UUID().uuidString)))
    XCTAssertNil(channel.initial)
  }

  func testALinkHandsOverTheItemItNames() throws {
    let channel = SharedItemsChannel(files: files, root: root, now: { self.now })
    let id = try files.write(text: "Meet me at nine.", now: now)

    XCTAssertTrue(channel.arrived(URL(string: "kemlock://share/\(id)")!))
    XCTAssertEqual(channel.initial?["text"] as? String, "Meet me at nine.")
    XCTAssertEqual(contents(files.folder), [])
  }

  func testAnOtpauthLinkIsLeftToSetupLinks() throws {
    let channel = SharedItemsChannel(files: files, root: root, now: { self.now })
    let link = URL(string: "otpauth://totp/Example:ada@example.org?secret=JBSWY3DPEHPK3PXP")!

    XCTAssertFalse(channel.arrived(link))
    XCTAssertNil(SharedItemFile.id(fromLink: link))
    XCTAssertNil(SharedItemFile.id(fromLink: URL(string: "kemlock://share/../../Library")!))
    XCTAssertNil(channel.initial)
  }

  func testNamesAreKeptInsideTheFolder() {
    XCTAssertEqual(SharedItemFile.safeName("../../Library/Preferences/x.plist"), "x.plist")
    XCTAssertEqual(SharedItemFile.safeName("rep\u{0}ort\n.txt"), "report.txt")
    XCTAssertEqual(SharedItemFile.safeName(".."), "shared")
    XCTAssertEqual(SharedItemFile.safeName(""), "shared")
  }

  // MARK: What the extension reads an attachment as

  func testASafariPageIsReadAsALinkNotAFile() {
    // Safari shares public.url with the page title as its suggested name
    XCTAssertEqual(SharedItemFile.reading(types: ["public.url"], hasSuggestedName: true), .webLink)
    XCTAssertEqual(SharedItemFile.reading(types: ["public.url", "public.plain-text"], hasSuggestedName: false), .webLink)
  }

  func testAFileURLStaysAFile() {
    XCTAssertEqual(SharedItemFile.reading(types: ["public.file-url", "public.url"], hasSuggestedName: false), .file)
    XCTAssertEqual(SharedItemFile.reading(types: ["public.png"], hasSuggestedName: true), .file)
    XCTAssertEqual(SharedItemFile.reading(types: ["com.adobe.pdf"], hasSuggestedName: false), .file)
  }

  func testPlainTextStaysText() {
    XCTAssertEqual(SharedItemFile.reading(types: ["public.plain-text"], hasSuggestedName: false), .plainText)
    XCTAssertEqual(SharedItemFile.reading(types: ["public.utf8-plain-text"], hasSuggestedName: false), .plainText)
  }

  func testOnlyAnHttpsLinkIsTakenAsText() {
    XCTAssertEqual(
      SharedItemFile.webLinkText(URL(string: "https://kem.example.com/#/send/AAAAAAAAAAAAAAAAAAAAAA/key")!),
      "https://kem.example.com/#/send/AAAAAAAAAAAAAAAAAAAAAA/key")
    XCTAssertNil(SharedItemFile.webLinkText(URL(string: "http://kem.example.com/")!))
    XCTAssertNil(SharedItemFile.webLinkText(URL(string: "file:///private/var/x.txt")!))
    XCTAssertNil(SharedItemFile.webLinkText(URL(string: "kemlock://share/abc")!))
  }
}
