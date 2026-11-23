import Foundation
import XCTest

@testable import Runner

/// What a push message may ask for (PushPayload). The token and the alert prompt are tried on a phone (the plan's
/// task 13.4).
final class PushChannelTests: XCTestCase {
  func testASyncOrApprovalTypeIsRead() {
    XCTAssertEqual(PushPayload.nudgeType(["type": "sync"]), "sync")
    XCTAssertEqual(PushPayload.nudgeType(["type": "approval", "aps": ["content-available": 1]]), "approval")
  }

  func testAnotherTypeOrNoneIsDropped() {
    XCTAssertNil(PushPayload.nudgeType(["type": "wipe"]))
    XCTAssertNil(PushPayload.nudgeType(["type": 5]))
    XCTAssertNil(PushPayload.nudgeType([:]))
  }

  func testATokenIsLowerCaseHex() {
    XCTAssertEqual(PushPayload.hex(Data([0x00, 0x0f, 0xa0, 0xff])), "000fa0ff")
    XCTAssertEqual(PushPayload.hex(Data()), "")
  }
}
