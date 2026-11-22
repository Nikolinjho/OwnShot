import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotSymbolsTests: XCTestCase {
  func testДляКаждогоИнструментаЕстьСистемныйСимвол() {
    for (name, symbol) in OwnShotSymbols.names {
      XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), name)
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
        let renderer = ImageRenderer(content: OwnShotSymbols.image(name)
          .font(.system(size: 18))
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
