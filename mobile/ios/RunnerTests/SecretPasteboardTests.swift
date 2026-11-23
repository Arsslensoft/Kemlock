import Flutter
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Runner

/// A pasteboard that keeps what it was given, and counts changes as UIPasteboard does.
private final class RecordingPasteboard: Pasteboard {
  var changeCount = 7
  var items: [[String: Any]] = []
  var options: [UIPasteboard.OptionsKey: Any] = [:]

  func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
    self.items = items
    self.options = options
    changeCount += 1
  }
}

/// The pasteboard side of `lib/platform/secret_clipboard.dart`. iOS gives no way to read an item's
/// options back, so they are checked on a recording pasteboard; a named pasteboard of the system's
/// own checks the text and the change count.
final class SecretPasteboardTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testCopiesLocalOnlyWithAnExpiryAtTheDelay() {
    let pasteboard = RecordingPasteboard()

    let token = SecretPasteboard(pasteboard: pasteboard, now: { self.now }).copy("123456", seconds: 30)

    XCTAssertEqual(token, 8)
    XCTAssertEqual(pasteboard.items.count, 1)
    XCTAssertEqual(pasteboard.items.first?[UTType.utf8PlainText.identifier] as? String, "123456")
    XCTAssertEqual(pasteboard.options[.localOnly] as? Bool, true)
    XCTAssertEqual(pasteboard.options[.expirationDate] as? Date, now.addingTimeInterval(30))
  }

  func testGivesACopyNoExpiryWhenTheDelayIsNever() {
    let pasteboard = RecordingPasteboard()

    SecretPasteboard(pasteboard: pasteboard, now: { self.now }).copy("123456", seconds: nil)

    XCTAssertEqual(pasteboard.options[.localOnly] as? Bool, true)
    XCTAssertNil(pasteboard.options[.expirationDate])
  }

  func testClearsItsOwnCopyAndLeavesOneMadeSince() {
    let pasteboard = RecordingPasteboard()
    let secret = SecretPasteboard(pasteboard: pasteboard, now: { self.now })

    let token = secret.copy("123456", seconds: 30)
    XCTAssertTrue(secret.clearIfOurs(token))
    XCTAssertTrue(pasteboard.items.isEmpty)

    let next = secret.copy("654321", seconds: 30)
    // An address copied in another app moves the count
    pasteboard.setItems([[UTType.utf8PlainText.identifier: "1 Infinite Loop"]], options: [:])
    XCTAssertFalse(secret.clearIfOurs(next))
    XCTAssertEqual(pasteboard.items.first?[UTType.utf8PlainText.identifier] as? String, "1 Infinite Loop")
  }

  func testWorksOnTheSystemsOwnPasteboard() throws {
    let pasteboard = UIPasteboard.withUniqueName()
    defer { UIPasteboard.remove(withName: pasteboard.name) }
    let secret = SecretPasteboard(pasteboard: pasteboard)

    let token = secret.copy("123456", seconds: 60)
    XCTAssertEqual(pasteboard.string, "123456")
    XCTAssertEqual(token, pasteboard.changeCount)

    pasteboard.string = "copied elsewhere"
    XCTAssertFalse(secret.clearIfOurs(token))
    XCTAssertEqual(pasteboard.string, "copied elsewhere")

    XCTAssertTrue(secret.clearIfOurs(secret.copy("123456", seconds: nil)))
    XCTAssertNil(pasteboard.string)
  }

  func testAnswersTheChannelWithTheTokenAsText() {
    let pasteboard = RecordingPasteboard()
    let secret = SecretPasteboard(pasteboard: pasteboard, now: { self.now })
    var answers: [Any?] = []

    secret.handle(FlutterMethodCall(methodName: "copy", arguments: ["text": "123456", "seconds": 10])) { answers.append($0) }
    XCTAssertEqual(answers.first as? String, "8")
    XCTAssertEqual(pasteboard.options[.expirationDate] as? Date, now.addingTimeInterval(10))
    secret.handle(FlutterMethodCall(methodName: "clearIfOurs", arguments: ["token": "not ours"])) { answers.append($0) }
    XCTAssertFalse(pasteboard.items.isEmpty)
    secret.handle(FlutterMethodCall(methodName: "clearIfOurs", arguments: ["token": "8"])) { answers.append($0) }

    XCTAssertTrue(pasteboard.items.isEmpty)
    XCTAssertEqual(answers.count, 3)
  }
}
