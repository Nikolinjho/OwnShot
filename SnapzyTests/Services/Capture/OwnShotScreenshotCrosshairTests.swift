import AppKit
import XCTest
@testable import Snapzy

final class OwnShotScreenshotCrosshairTests: AreaSelectionOverlayTestCase {
  func testDisabledБлокируетЛупуПриCommandScroll() {
    UserDefaults.standard.set("disabled", forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    let image = createSolidColorImage(color: .white, size: CGSize(width: 800, height: 600))
    overlayView.applyBackdrop(AreaSelectionBackdrop(displayID: 0, image: image, scaleFactor: 1))
    overlayView.testScrollWheel(deltaY: 6, modifierFlags: .command)
    XCTAssertEqual(overlayView.testMagnifierZoom, 1, "Disabled не включает увеличение")
    XCTAssertNil(overlayView.testMagnifierContainerLayer)
  }

  private var savedMode: Any?

  override func setUp() {
    super.setUp()
    savedMode = UserDefaults.standard.object(forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
  }

  override func tearDown() {
    if let savedMode {
      UserDefaults.standard.set(savedMode, forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    } else {
      UserDefaults.standard.removeObject(forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    }
    super.tearDown()
  }

  func testCommandCrosshairChangesWithoutMouseMovement() {
    // Переключение Command обновляет обе направляющие при неподвижном курсоре.
    UserDefaults.standard.set("command", forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    overlayView.setSelectionEnabled(true)
    overlayView.setInteractionMode(.manualRegion, resetSelection: false)
    overlayView.refreshCrosshairGuides(commandPressed: false)
    XCTAssertTrue(overlayView.testHorizontalCrosshairLayer.isHidden)
    overlayView.refreshCrosshairGuides(commandPressed: true)
    XCTAssertFalse(overlayView.testHorizontalCrosshairLayer.isHidden)
    XCTAssertFalse(overlayView.testVerticalCrosshairLayer.isHidden)
    XCTAssertNotNil(overlayView.testHorizontalCrosshairLayer.path)
    overlayView.refreshCrosshairGuides(commandPressed: false)
    XCTAssertTrue(overlayView.testVerticalCrosshairLayer.isHidden)
  }

  func testWindowAndDisplayModesHideCrosshairGuides() {
    UserDefaults.standard.set("always", forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    overlayView.setSelectionEnabled(true)
    overlayView.setInteractionMode(.manualRegion, resetSelection: false)
    overlayView.refreshCrosshairGuides(commandPressed: false)
    XCTAssertFalse(overlayView.testHorizontalCrosshairLayer.isHidden)
    overlayView.setInteractionMode(.applicationWindow, resetSelection: false)
    overlayView.refreshCrosshairGuides(commandPressed: false)
    XCTAssertTrue(overlayView.testHorizontalCrosshairLayer.isHidden)
    overlayView.setInteractionMode(.fullDisplay, resetSelection: false)
    overlayView.refreshCrosshairGuides(commandPressed: false)
    XCTAssertTrue(overlayView.testVerticalCrosshairLayer.isHidden)
  }
}
