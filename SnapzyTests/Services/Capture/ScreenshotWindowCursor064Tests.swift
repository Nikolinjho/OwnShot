import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class ScreenshotWindowCursor064Tests: XCTestCase {
  func testКурсорОкнаСодержитКамеруИСохраняетТочкуНажатия() throws {
    let cursor = try XCTUnwrap(ScreenshotWindowCursorSpec.makeCursor())
    XCTAssertEqual(cursor.hotSpot, NSPoint(x: 14, y: 11))
    XCTAssertEqual(cursor.image.size, NSSize(width: 28, height: 25))
    let rep = try XCTUnwrap(cursor.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    XCTAssertTrue((0..<rep.pixelsHigh).contains { y in
      (0..<rep.pixelsWide).contains { x in
        (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.7
      }
    })
  }

  func testБезИсходногоРисункаКурсорНеСоздаётся() {
    XCTAssertNil(ScreenshotWindowCursorSpec.makeCursor(asset: nil))
  }
}
