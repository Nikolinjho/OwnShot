import AppKit
import XCTest
@testable import Snapzy

final class OwnShotInlineCrosshairTests: XCTestCase {
  func testОтключённоеПерекрестиеНеПоказываетЛупуДажеСВключённымZoom() {
    let view = InlineAreaMagnifierHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    view.displayBounds = view.bounds
    let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    view.backdropImage = context.makeImage()
    view.crosshairMode = .disabled
    view.magnifier.resetZoom(showByDefault: true)
    view.update(at: CGPoint(x: 200, y: 150))
    XCTAssertNil(view.magnifier.containerLayer, "Disabled скрывает лупу без сброса сохранённого Zoom")
    XCTAssertFalse(view.applyScroll(delta: 6, hasPreciseScrollingDeltas: false), "Disabled не включает лупу через Command-scroll")
    view.crosshairMode = .always
    view.update(at: CGPoint(x: 200, y: 150))
    XCTAssertNotNil(view.magnifier.containerLayer, "Возвращение режима восстанавливает лупу")
  }

  func testCommandGuidesRefreshWithoutMovingAndHideWithHost() {
    // Направляющие не зависят от движения курсора и очищаются вместе с лупой.
    let view = InlineAreaMagnifierHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    view.displayBounds = view.bounds
    view.crosshairMode = .command
    view.update(at: CGPoint(x: 300, y: 200))
    view.refreshCrosshairGuides(commandPressed: false)
    XCTAssertTrue(view.horizontalCrosshairGuideLayer?.isHidden ?? true)
    view.refreshCrosshairGuides(commandPressed: true)
    XCTAssertFalse(view.horizontalCrosshairGuideLayer?.isHidden ?? true)
    XCTAssertFalse(view.verticalCrosshairGuideLayer?.isHidden ?? true)
    XCTAssertEqual(view.horizontalCrosshairGuideLayer?.path?.boundingBox.width, 800)
    XCTAssertEqual(view.verticalCrosshairGuideLayer?.path?.boundingBox.height, 600)
    view.hide()
    XCTAssertTrue(view.horizontalCrosshairGuideLayer?.isHidden ?? false)
    XCTAssertTrue(view.verticalCrosshairGuideLayer?.isHidden ?? false)
  }

  func testGuidesDoNotCoverActiveSelectionAndDisabledMode() {
    let view = InlineAreaMagnifierHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    view.displayBounds = view.bounds
    view.crosshairMode = .always
    view.update(at: CGPoint(x: 300, y: 200))
    XCTAssertFalse(view.horizontalCrosshairGuideLayer?.isHidden ?? true)
    view.crosshairGuidesEnabled = false
    view.refreshCrosshairGuides(commandPressed: true)
    XCTAssertTrue(view.horizontalCrosshairGuideLayer?.isHidden ?? false)
    view.crosshairGuidesEnabled = true
    view.crosshairMode = .disabled
    view.refreshCrosshairGuides(commandPressed: true)
    XCTAssertTrue(view.verticalCrosshairGuideLayer?.isHidden ?? false)
  }
}
