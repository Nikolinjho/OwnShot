import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotIconsTests: XCTestCase {
  func testЗначкиЗагружаютсяИзКаталогаВСвоихРазмерах() throws {
    let sizes: [String: NSSize] = [
      "annotatePipette": NSSize(width: 14, height: 14),
      "floatingOverlayDrag": NSSize(width: 39, height: 11),
      "resizeLock": NSSize(width: 23, height: 33),
      "recorderControlRestart": NSSize(width: 14, height: 17),
      "onboardingMenubar": NSSize(width: 408, height: 208),
    ]
    for (name, size) in sizes {
      let image = try XCTUnwrap(OwnShotIcons.nsImage(name), name)
      XCTAssertEqual(image.size, size, name)
    }
  }

  func testДляКаждогоСобытияЗаписиЕстьСистемныйЗвук() {
    for sound in SoundManager.RecordingSound.allCases {
      XCTAssertNotNil(NSSound(named: sound.rawValue), sound.rawValue)
    }
  }

  func testЗначкиИнструментовВидныВСветлойИТёмнойТеме() throws {
    for scheme in [ColorScheme.light, .dark] {
      for name in ["annotatePipette", "prefGeneral", "oneOverlayRecord", "popupPin", "recorderMicrophone"] {
        let renderer = ImageRenderer(content: OwnShotIcons.image(name)
          .foregroundStyle(scheme == .light ? Color.black : Color.white)
          .frame(width: 32, height: 32)
          .environment(\.colorScheme, scheme))
        let bitmap = try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in
          (0..<bitmap.pixelsWide).contains { x in
            (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.7
          }
        }, name)
      }
    }
  }
}
