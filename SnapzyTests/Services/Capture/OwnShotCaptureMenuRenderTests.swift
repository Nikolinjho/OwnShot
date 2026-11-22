import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

final class OwnShotCaptureMenuRenderTests: XCTestCase {
  @MainActor
  func testМенюМикрофонаИКамерыОтображаютПиктограммы() throws {
    let state = RecordingToolbarState()
    state.captureMicrophone = false
    state.captureCamera = false
    for content in [AnyView(ToolbarMicToggleButton(state: state)), AnyView(RecordingToolbarCameraToggleButton(state: state))] {
      let host = NSHostingView(rootView: content.padding(12).background(Color.black).environment(\.colorScheme, .dark))
      let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      host.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
      window.orderFrontRegardless()
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      var visiblePixels = 0
      for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
          let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          if color.redComponent > 0.2 && color.greenComponent > 0.2 && color.blueComponent > 0.2 { visiblePixels += 1 }
        }
      }
      XCTAssertGreaterThan(visiblePixels, 30, "Выключенный источник должен оставлять видимую пиктограмму в меню")
    }
  }
}
