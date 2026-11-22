import AppKit
import XCTest
@testable import Snapzy

/// Паритет Quick Access и pin с CleanShot X, волна 059
@MainActor
final class QuickAccessParity059Tests: XCTestCase {
  func testМенюRetinaСнимкаПолучаетЛокализованнуюПодписьБезПадения() {
    XCTAssertFalse(L10n.QuickAccessMenu.scaleRetinaTo1x.isEmpty)
  }

  func testПодписьCloseAfterDraggingМеняетсяВместеСНастройкой() {
    XCTAssertEqual(
      QuickAccessSettingsHints.closeAfterDragging(true),
      "Hold ⌥ (option) to keep the item on Overlay after dragging."
    )
    XCTAssertEqual(
      QuickAccessSettingsHints.closeAfterDragging(false),
      "Hold ⌥ (option) to close the item from Overlay after dragging."
    )
  }

  func testПодсказкаSaveЗависитОтРежима() {
    XCTAssertEqual(
      QuickAccessSettingsHints.saveButton(behavior: "exportLocation"),
      "Press with ⌥ (option) to choose the destination."
    )
    XCTAssertEqual(
      QuickAccessSettingsHints.saveButton(behavior: "chooseDestination"),
      "Press with ⌥ (option) to use 'Export Location' without asking."
    )
    XCTAssertEqual(L10n.PreferencesQuickAccess.saveButtonAskForDestination, "Ask for destination")
  }

  func testШкалаOverlaySizeИмеетПятьПоложенийСЕдиницейПосередине() {
    let positions = QuickAccessOverlaySizeScale.positions
    XCTAssertEqual(positions.count, 5)
    XCTAssertEqual(positions[2], 1.0)
    XCTAssertEqual(QuickAccessOverlaySizeScale.clamp(0.2), 0.5)
    XCTAssertEqual(QuickAccessOverlaySizeScale.clamp(1.1), 1.0)
    XCTAssertEqual(QuickAccessOverlaySizeScale.clamp(9), 1.5)
  }

  func testНесохранённаяЗаписьЗакрываетсяТолькоСПодтверждением() {
    XCTAssertTrue(QuickAccessCompletionPolicy.shouldConfirmClose(isVideo: true, isTempFile: true))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldConfirmClose(isVideo: true, isTempFile: false))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldConfirmClose(isVideo: false, isTempFile: true))
  }

  func testPinНеПрячетИсходнуюКарточку() {
    XCTAssertFalse(QuickAccessCompletionPolicy.hidesCardWhenOpening(pin: true, hideCardWhenWindowOpen: true))
    XCTAssertTrue(QuickAccessCompletionPolicy.hidesCardWhenOpening(pin: false, hideCardWhenWindowOpen: true))
    XCTAssertFalse(QuickAccessCompletionPolicy.hidesCardWhenOpening(pin: false, hideCardWhenWindowOpen: false))
  }

  func testУгловыеКнопкиКарточки22ptИЗалитыеГлифы() {
    // Видимый круг 22 pt (44 px @2x): evidence/audit-020/reference-quick-hover.png, R20 spec-066
    XCTAssertEqual(QuickAccessLayout.cornerButtonSize, 22)
    XCTAssertEqual(
      QuickAccessCardChrome.cornerSymbol(for: .pinToScreen, isVideo: false, isPinned: false, uploadedToCloud: false),
      "pin.fill"
    )
    XCTAssertEqual(
      QuickAccessCardChrome.cornerSymbol(for: .delete, isVideo: false, isPinned: false, uploadedToCloud: false),
      "trash.fill"
    )
    XCTAssertEqual(
      QuickAccessCardChrome.cornerSymbol(for: .uploadToCloud, isVideo: false, isPinned: false, uploadedToCloud: false),
      "icloud.and.arrow.up.fill"
    )
    XCTAssertEqual(
      QuickAccessCardChrome.cornerSymbol(for: .edit, isVideo: true, isPinned: false, uploadedToCloud: false),
      "scissors"
    )
    XCTAssertLessThan(QuickAccessLayout.hoverDimOpacity, 0.8)
    XCTAssertGreaterThan(QuickAccessLayout.hoverBlurRadius, 0)
  }

  func testЗначкиКарточекЗагружаютсяИзКаталога() {
    for name in ["popupClose", "popupTrash", "popupPin", "popupAnnotate", "popupTrim", "popupUpload"] {
      XCTAssertNotNil(OwnShotIcons.nsImage(name), name)
    }
  }

  func testИнфоПлашкаЗаписи() {
    let mov = URL(fileURLWithPath: "/tmp/rec.mov")
    let gif = URL(fileURLWithPath: "/tmp/rec.GIF")
    XCTAssertEqual(QuickAccessCardChrome.infoBadges(isVideo: true, url: mov, hasSound: true), [.video, .sound])
    XCTAssertEqual(QuickAccessCardChrome.infoBadges(isVideo: true, url: mov, hasSound: false), [.video])
    XCTAssertEqual(QuickAccessCardChrome.infoBadges(isVideo: true, url: gif, hasSound: true), [.gif])
    XCTAssertEqual(QuickAccessCardChrome.infoBadges(isVideo: false, url: mov, hasSound: true), [])
    XCTAssertTrue(QuickAccessCardChrome.showsQuickLookButton(isVideo: true, url: mov))
    XCTAssertFalse(QuickAccessCardChrome.showsQuickLookButton(isVideo: true, url: gif))
    XCTAssertFalse(QuickAccessCardChrome.showsQuickLookButton(isVideo: false, url: mov))
  }

  func testШахматкаЧередуетКлеткиИЗависитОтТемы() {
    XCTAssertFalse(QuickAccessCheckerboardPalette.isAlternate(row: 0, column: 0))
    XCTAssertTrue(QuickAccessCheckerboardPalette.isAlternate(row: 0, column: 1))
    XCTAssertTrue(QuickAccessCheckerboardPalette.isAlternate(row: 1, column: 0))
    XCTAssertNotEqual(
      QuickAccessCheckerboardPalette.colors(isDark: true).base,
      QuickAccessCheckerboardPalette.colors(isDark: false).base
    )
  }

  func testУровеньОкнаКарточекКакУЭталона() {
    XCTAssertEqual(QuickAccessLayout.panelWindowLevel, 2147483628)
    XCTAssertGreaterThan(QuickAccessLayout.alertWindowLevel, QuickAccessLayout.panelWindowLevel)
  }

  func testХромPinКнопки24ptСОтступом9pt() {
    XCTAssertEqual(QuickAccessPinChromeMetrics.buttonSize, 24)
    XCTAssertEqual(QuickAccessPinChromeMetrics.controlInset, 9)
    XCTAssertEqual(QuickAccessPinChromeMetrics.dragGlyphSize, CGSize(width: 39, height: 11))
  }

  func testPinПоявляетсяИРисуетсяКакУЭталона() {
    // Live 062: пин 900×560 на экране 1728×1117 (строка меню 33, Dock 67) – в (414, 212) сверху.
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let visible = CGRect(x: 0, y: 67, width: 1728, height: 1017)
    let frame = QuickAccessPinWindowSizing.initialFrame(
      size: CGSize(width: 900, height: 560), screenFrame: screen, visibleFrame: visible
    )
    XCTAssertEqual(frame.minX, 414, accuracy: 0.001)
    XCTAssertEqual(screen.maxY - frame.maxY, 212, accuracy: 0.001)
    // Большой пин не уходит под строку меню.
    let tall = QuickAccessPinWindowSizing.initialFrame(
      size: CGSize(width: 900, height: 1000), screenFrame: screen, visibleFrame: visible
    )
    XCTAssertLessThanOrEqual(tall.maxY, visible.maxY)
    XCTAssertEqual(QuickAccessPinWindow.pinnedWindowLevel.rawValue, 103)
    XCTAssertEqual(QuickAccessPinChromeMetrics.cornerRadius, 18)
  }

  func testZoomPinМеняетОкноКакУЭталона() {
    // Эталон: окно 400×200 pt, Zoom 50% даёт 200×100, Zoom 200% даёт 800×400
    let base = CGSize(width: 400, height: 200)
    XCTAssertEqual(QuickAccessPinZoomMode.defaultMode, .windowFollowsImage)
    XCTAssertEqual(
      QuickAccessPinWindowState.windowFollowsImageDisplaySize(baseSize: base, zoomFactor: 0.5),
      CGSize(width: 200, height: 100)
    )
    XCTAssertEqual(
      QuickAccessPinWindowState.windowFollowsImageDisplaySize(baseSize: base, zoomFactor: 2),
      CGSize(width: 800, height: 400)
    )
  }

  func testResizeКраемPinСохраняетZoom() {
    XCTAssertEqual(
      QuickAccessPinWindowState.baseSize(forUserResize: CGSize(width: 600, height: 300), zoomMode: .windowFollowsImage, zoomFactor: 2),
      CGSize(width: 300, height: 150)
    )
    XCTAssertEqual(
      QuickAccessPinWindowState.baseSize(forUserResize: CGSize(width: 600, height: 300), zoomMode: .fixedViewport, zoomFactor: 2),
      CGSize(width: 600, height: 300)
    )
    let image = NSImage(size: CGSize(width: 800, height: 400))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/resize.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 400, height: 200),
      zoomMode: .windowFollowsImage
    )
    state.setZoomPercent(200)
    state.applyUserResize(CGSize(width: 1000, height: 500))
    XCTAssertEqual(state.zoomPercent, 200)
    XCTAssertEqual(state.displaySize, CGSize(width: 1000, height: 500))
  }

  func testПоследнееДействиеAfterCaptureНеСнимается() {
    let suiteName = "AfterCaptureAtLeastOne-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let manager = PreferencesManager(defaults: defaults)
    // По умолчанию у записи включены Quick Access, Copy и Save
    XCTAssertFalse(manager.wouldLeaveNoActions(disabling: .save, for: .recording))
    manager.setAction(.save, for: .recording, enabled: false)
    manager.setAction(.copyFile, for: .recording, enabled: false)
    XCTAssertTrue(manager.wouldLeaveNoActions(disabling: .showQuickAccess, for: .recording))
    // Annotate и Pin у записи не считаются: их нет в матрице
    manager.setAction(.openAnnotate, for: .recording, enabled: true)
    XCTAssertTrue(manager.wouldLeaveNoActions(disabling: .showQuickAccess, for: .recording))
    XCTAssertEqual(
      L10n.AfterCapture.atLeastOneActionTitle,
      "At least one action needs to be enabled"
    )
  }
}

@MainActor
final class QuickAccessScaleRetina059Tests: XCTestCase {
  func testПунктScaleRetinaТолькоУRetinaСнимка() {
    let plain = QuickAccessCardMenuLayout.groups(isVideo: false, includesCloud: false).flatMap { $0 }
    XCTAssertFalse(plain.contains(.scaleRetina))
    let retina = QuickAccessCardMenuLayout.groups(isVideo: false, includesCloud: false, isRetina: true).flatMap { $0 }
    let resizeIndex = try? XCTUnwrap(retina.firstIndex(of: .resize))
    XCTAssertEqual(retina.firstIndex(of: .scaleRetina), resizeIndex.map { $0 + 1 })
    let video = QuickAccessCardMenuLayout.groups(isVideo: true, includesCloud: false, isRetina: true).flatMap { $0 }
    XCTAssertFalse(video.contains(.scaleRetina))
  }

  func testМножительRetinaПоDPI() {
    XCTAssertEqual(QuickAccessImageFileTransform.retinaScale(dpi: 144), 2)
    XCTAssertNil(QuickAccessImageFileTransform.retinaScale(dpi: 72))
    XCTAssertNil(QuickAccessImageFileTransform.retinaScale(dpi: nil))
  }

  func testScaleRetinaУменьшаетКартинкуВдвое() throws {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try XCTUnwrap(context.makeImage())
    let output = try QuickAccessImageFileTransform.scaleRetinaTo1x(2).apply(to: image)
    XCTAssertEqual(output.width, 20)
    XCTAssertEqual(output.height, 10)
  }
}

@MainActor
final class QuickAccessGestures059Tests: XCTestCase {
  func testСвайпВнизРаспознаётсяСУчётомНаправленияПрокрутки() {
    // Естественная прокрутка: пальцы вниз дают положительный deltaY
    XCTAssertEqual(QuickAccessTrackpadSwipeHelpers.downwardDelta(
      scrollingDeltaX: 0, scrollingDeltaY: 10, hasPreciseScrollingDeltas: true, isDirectionInverted: true
    ), 10)
    XCTAssertEqual(QuickAccessTrackpadSwipeHelpers.downwardDelta(
      scrollingDeltaX: 0, scrollingDeltaY: 10, hasPreciseScrollingDeltas: true, isDirectionInverted: false
    ), -10)
    // Горизонтальный жест не считается
    XCTAssertNil(QuickAccessTrackpadSwipeHelpers.downwardDelta(
      scrollingDeltaX: 10, scrollingDeltaY: 5, hasPreciseScrollingDeltas: true, isDirectionInverted: true
    ))
    XCTAssertNil(QuickAccessTrackpadSwipeHelpers.downwardDelta(
      scrollingDeltaX: 0, scrollingDeltaY: 10, hasPreciseScrollingDeltas: false, isDirectionInverted: true
    ))
  }

  func testПроверкаАктивногоЭкранаПропускаетDragИАнимацию() {
    XCTAssertTrue(QuickAccessActiveScreenPolicy.shouldCheck(followsActiveScreen: true, isTransitioning: false, mouseButtonsPressed: 0))
    XCTAssertFalse(QuickAccessActiveScreenPolicy.shouldCheck(followsActiveScreen: false, isTransitioning: false, mouseButtonsPressed: 0))
    XCTAssertFalse(QuickAccessActiveScreenPolicy.shouldCheck(followsActiveScreen: true, isTransitioning: true, mouseButtonsPressed: 0))
    XCTAssertFalse(QuickAccessActiveScreenPolicy.shouldCheck(followsActiveScreen: true, isTransitioning: false, mouseButtonsPressed: 1))
  }

  func testПолоскаВозвратаСтоитПодСтеком() {
    let visible = CGRect(x: 0, y: 40, width: 1000, height: 800)
    let right = QuickAccessHiddenStackStripLayout.frame(visibleFrame: visible, isLeftSide: false, scale: 1)
    let left = QuickAccessHiddenStackStripLayout.frame(visibleFrame: visible, isLeftSide: true, scale: 1)
    XCTAssertEqual(right.minY, 40)
    XCTAssertEqual(right.midX, 1000 - QuickAccessLayout.containerPadding - 105, accuracy: 0.5)
    XCTAssertEqual(left.midX, QuickAccessLayout.containerPadding + 105, accuracy: 0.5)
    XCTAssertEqual(QuickAccessHiddenStackStripLayout.arrowSize, CGSize(width: 36, height: 10))
  }
}
