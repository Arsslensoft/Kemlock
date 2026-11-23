import Flutter
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testRefusesTheKeyboardsOfOtherApps() {
    let delegate = AppDelegate()

    XCTAssertFalse(delegate.application(UIApplication.shared, shouldAllowExtensionPointIdentifier: .keyboard))
    // Any other kind of extension is the system's to allow
    let other = UIApplication.ExtensionPointIdentifier(rawValue: "com.apple.share-services")
    XCTAssertTrue(delegate.application(UIApplication.shared, shouldAllowExtensionPointIdentifier: other))
  }

}
