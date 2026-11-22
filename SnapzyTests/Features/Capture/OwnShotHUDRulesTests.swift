import AppKit
import XCTest
@testable import Snapzy

/// Правила HUD захвата и записи из spec-066 (R07, R28–R31, R33). Числа – байты PNG кадров
/// spec-039-live/all-in-one-overlay-initial.png и spec-063-live/ref-record-options-panel.png.
final class OwnShotHUDRulesTests: XCTestCase {
  private func hex(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.sRGB)!
    return String(
      format: "#%02X%02X%02X",
      Int((rgb.redComponent * 255).rounded()),
      Int((rgb.greenComponent * 255).rounded()),
      Int((rgb.blueComponent * 255).rounded())
    )
  }

  func testПанелиHUDНепрозрачныеСДвойнойКромкой() {
    // AIO: x546–547 #191919, x548–549 #353434, дальше заливка #2A2929.
    XCTAssertEqual(hex(OwnShotHUDStyle.fill(.allInOne)), "#2A2929")
    XCTAssertEqual(hex(OwnShotHUDStyle.innerEdge(.allInOne)), "#353434")
    XCTAssertEqual(hex(OwnShotHUDStyle.outerEdge(.allInOne)), "#191919")
    // Запись: y180–185 #282726 → #333231 → #181717.
    XCTAssertEqual(hex(OwnShotHUDStyle.fill(.recording)), "#282726")
    XCTAssertEqual(hex(OwnShotHUDStyle.innerEdge(.recording)), "#333231")
    XCTAssertEqual(hex(OwnShotHUDStyle.outerEdge(.recording)), "#181717")
    XCTAssertEqual(OwnShotHUDStyle.fill(.allInOne).alphaComponent, 1)
    XCTAssertEqual(OwnShotHUDStyle.fill(.recording).alphaComponent, 1)
    XCTAssertEqual(OwnShotHUDStyle.edgeWidth, 1)
  }

  func testЗазорМеждуПанелями10() {
    // AIO x1466..1485 и запись y186..205: 20 px = 10 pt.
    XCTAssertEqual(OwnShotHUDStyle.panelSpacing, 10)
  }

  func testУтопленныеПоляИЯчейка() {
    // Поле AIO (1530,1718) #222121, выбранная ячейка записи (330,130) #201F1E.
    XCTAssertEqual(hex(OwnShotHUDStyle.recessed(.allInOne)), "#222121")
    XCTAssertEqual(hex(OwnShotHUDStyle.recessed(.recording)), "#201F1E")
    XCTAssertEqual(hex(RecordingToolbarView.toggleBackground(isOn: true)), "#201F1E")
    XCTAssertEqual(RecordingToolbarView.toggleBackground(isOn: false).alphaComponent, 0)
  }

  func testЧетыреУровняПереднегоПлана() {
    // Highlight Clicks вкл. #FFFFFF, «400» и «Record GIF» #DEDEDE, «⌥↩» и подписи режимов
    // #AAA9A9, микрофон выкл. и кроп #949393.
    XCTAssertEqual(hex(OwnShotHUDStyle.primaryForeground), "#FFFFFF")
    XCTAssertEqual(hex(OwnShotHUDStyle.valueForeground), "#DEDEDE")
    XCTAssertEqual(hex(OwnShotHUDStyle.secondaryForeground), "#AAA9A9")
    XCTAssertEqual(hex(OwnShotHUDStyle.inactiveForeground), "#949393")
    XCTAssertEqual(hex(RecordingToolbarView.toggleForeground(isOn: true)), "#FFFFFF")
    XCTAssertEqual(hex(RecordingToolbarView.toggleForeground(isOn: false)), "#949393")
  }

  @MainActor
  func testВыделениеВПоляхHUD_СистемныйЦветТёмнойТемы() {
    // R33: не константа #976D6D, а selectedTextBackgroundColor для darkAqua.
    let dark = NSAppearance(named: .darkAqua)
    var expected = NSColor.clear
    dark?.performAsCurrentDrawingAppearance {
      expected = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB)!
    }
    XCTAssertEqual(hex(OwnShotCaptureSizeFieldFocus.selectionColor), hex(expected))
    XCTAssertNotEqual(hex(OwnShotCaptureSizeFieldFocus.selectionColor), "#976D6D")
  }

  func testПрицелЧёрныйСоСветлымОреолом() {
    // R26: линия #000 1 pt, ореол белый ≈18 % по 2 pt с каждой стороны.
    XCTAssertEqual(OwnShotCrosshairStyle.lineColor, .black)
    XCTAssertEqual(OwnShotCrosshairStyle.lineWidth, 1)
    XCTAssertEqual(OwnShotCrosshairStyle.haloWidth, 2)
    XCTAssertEqual(OwnShotCrosshairStyle.haloColor.alphaComponent, 0.18, accuracy: 0.001)
  }
}

/// Прицел, направляющие и затемнение живого оверлея захвата (R24, R26).
final class OwnShotCaptureOverlayRulesTests: AreaSelectionOverlayTestCase {
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

  func testЗатемнениеЧёрный50() {
    XCTAssertEqual(overlayView.testDimColor.alphaComponent, 0.5, accuracy: 0.001)
  }

  func testКурсорВыделенияВсегдаТёмный() {
    // Светлого креста у эталона нет ни в тёмной, ни в светлой теме.
    UserDefaults.standard.set("always", forKey: OwnShotScreenshotPreferenceKeys.crosshairMode)
    overlayView.setInteractionMode(.manualRegion, resetSelection: false)
    XCTAssertTrue(overlayView.testActiveCursor === NSCursor.vectorScreenshotCrosshairHighContrast)
  }

  func testНаправляющиеЧёрныеСОреолом() {
    let halo = overlayView.testHorizontalCrosshairLayer
    let core = overlayView.testHorizontalCrosshairCoreLayer
    XCTAssertEqual(halo.lineWidth, 5)
    XCTAssertEqual(NSColor(cgColor: halo.strokeColor!)?.alphaComponent ?? 0, 0.18, accuracy: 0.001)
    XCTAssertEqual(core.lineWidth, 1)
    let coreColor = NSColor(cgColor: core.strokeColor!)?.usingColorSpace(.sRGB)
    XCTAssertEqual(coreColor?.redComponent ?? 1, 0, accuracy: 0.001)
    XCTAssertEqual(coreColor?.alphaComponent ?? 0, 1, accuracy: 0.001)
    XCTAssertTrue(core.superlayer === halo, "Линия видна и скрыта вместе с ореолом")
  }
}
