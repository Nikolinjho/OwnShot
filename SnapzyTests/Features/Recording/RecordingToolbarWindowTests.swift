//
//  RecordingToolbarWindowTests.swift
//  SnapzyTests
//
//  Unit tests for recording hover bar drag-position clamping (issue #351).
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class RecordingToolbarWindowTests: XCTestCase {

  private let union = CGRect(x: 0, y: 0, width: 1000, height: 800)
  private let size = CGSize(width: 200, height: 50)

  func testReturnЗапускаетВидео() {
    XCTAssertEqual(RecordingPreRecordShortcut.outputMode(keyCode: 36, modifiers: [], isRepeat: false), .video)
  }

  func testEnterЦифровойКлавиатурыЗапускаетВидео() {
    XCTAssertEqual(RecordingPreRecordShortcut.outputMode(keyCode: 76, modifiers: [.numericPad], isRepeat: false), .video)
  }

  func testOptionReturnЗапускаетGIF() {
    XCTAssertEqual(RecordingPreRecordShortcut.outputMode(keyCode: 36, modifiers: [.option], isRepeat: false), .gif)
  }

  func testЧужиеСочетанияСReturnНеЗапускаютЗапись() {
    for modifiers: NSEvent.ModifierFlags in [.command, .control, .shift, [.command, .option]] {
      XCTAssertNil(RecordingPreRecordShortcut.outputMode(keyCode: 36, modifiers: modifiers, isRepeat: false))
    }
  }

  func testУдержаниеReturnНеЗапускаетПовторнуюЗапись() {
    XCTAssertNil(RecordingPreRecordShortcut.outputMode(keyCode: 36, modifiers: [], isRepeat: true))
  }

  func testОстальныеКлавишиНеЗапускаютЗапись() {
    for key: UInt16 in [49, 53, 0, 48] {
      XCTAssertNil(RecordingPreRecordShortcut.outputMode(keyCode: key, modifiers: [], isRepeat: false))
    }
  }

  func testНачальнаяОбластьДоступнаДоСозданияПанели() {
    let rect = CGRect(x: 30, y: 40, width: 300, height: 108.5)
    let state = RecordingToolbarState(selectionRect: rect)
    XCTAssertEqual(state.selectionRect, rect)
  }

  func testПанельСразуПоказываетРазмерОбластиИОбновляетЕго() throws {
    try skipIfRunningInCI("Требуется создание окна панели записи")
    let rect = CGRect(x: 100, y: 100, width: 300, height: 108.5)
    let window = RecordingToolbarWindow(anchorRect: rect)
    defer { window.close() }
    XCTAssertEqual(window.state.selectionRect, rect)
    let resized = CGRect(x: 120, y: 130, width: 640, height: 360)
    window.updateAnchorRect(resized)
    XCTAssertEqual(window.state.selectionRect, resized)
  }

  func testЗакрытаяПанельНеМеняетРазмерНовогоВыделения() async throws {
    try skipIfRunningInCI("Требуется окно Recorder")
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let rect = CGRect(x: screen.frame.midX - 180, y: screen.frame.midY - 110, width: 360, height: 220)
    let coordinator = RecordingCoordinator.shared
    let previousWindows = Set(NSApp.windows.map(\.windowNumber))
    coordinator.showToolbar(for: rect)
    defer { coordinator.cancel() }
    let oldToolbar = try XCTUnwrap(NSApp.windows.compactMap { $0 as? RecordingToolbarWindow }
      .first { $0.isVisible && !previousWindows.contains($0.windowNumber) })

    if let cancellation = coordinator.cancel() { await cancellation.value }
    coordinator.showToolbar(for: rect)
    let newToolbar = try XCTUnwrap(NSApp.windows.compactMap { $0 as? RecordingToolbarWindow }
      .first { $0 !== oldToolbar && $0.isVisible && !previousWindows.contains($0.windowNumber) })

    // SwiftUI может сообщить о потере фокуса старого поля после открытия новой панели.
    oldToolbar.state.onResizeSelection?(nil, 2_505, false)
    oldToolbar.state.onAspectRatioChanged?(16.0 / 9)
    XCTAssertEqual(newToolbar.state.selectionRect, rect)

    if let cancellation = coordinator.cancel() { await cancellation.value }
  }

  func testClampedOrigin_insideBounds_isUnchanged() {
    let origin = CGPoint(x: 100, y: 120)
    let result = RecordingToolbarWindow.clampedOrigin(origin, size: size, within: union)
    XCTAssertEqual(result, origin)
  }

  func testClampedOrigin_offRightAndTop_isPulledInsideSoWindowFits() {
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: 5000, y: 5000), size: size, within: union
    )
    XCTAssertEqual(result.x, union.maxX - size.width, accuracy: 0.001)  // 800
    XCTAssertEqual(result.y, union.maxY - size.height, accuracy: 0.001)  // 750
  }

  func testClampedOrigin_offLeftAndBottom_isPulledToMinCorner() {
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: -500, y: -500), size: size, within: union
    )
    XCTAssertEqual(result.x, union.minX, accuracy: 0.001)
    XCTAssertEqual(result.y, union.minY, accuracy: 0.001)
  }

  func testClampedOrigin_withOffsetUnion_respectsMinOrigin() {
    let offsetUnion = CGRect(x: -200, y: -100, width: 1200, height: 900)
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: -9999, y: -9999), size: size, within: offsetUnion
    )
    XCTAssertEqual(result.x, offsetUnion.minX, accuracy: 0.001)
    XCTAssertEqual(result.y, offsetUnion.minY, accuracy: 0.001)
  }

  func testClampedOrigin_nullUnion_returnsOriginUnchanged() {
    let origin = CGPoint(x: 42, y: 24)
    let result = RecordingToolbarWindow.clampedOrigin(origin, size: size, within: .null)
    XCTAssertEqual(result, origin)
  }

  func testClampedOrigin_windowLargerThanUnion_clampsToMinCorner() {
    // A window wider/taller than the visible area should pin to the min corner (never negative maxX/maxY).
    let big = CGSize(width: 2000, height: 2000)
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: 500, y: 500), size: big, within: union
    )
    XCTAssertEqual(result.x, union.minX, accuracy: 0.001)
    XCTAssertEqual(result.y, union.minY, accuracy: 0.001)
  }

  /// Regression: the status-bar transition happens while the pre-record toolbar is
  /// still on screen (`init` orders the window front). The already-visible early
  /// return in `applyRecordingBarVisibility` must not skip enabling background
  /// dragging, or the recording bar can never be dragged.
  func testShowRecordingStatusBar_alreadyVisibleWindow_enablesBackgroundDragging() throws {
    try skipIfRunningInCI("Requires onscreen window and recording manager")
    let window = RecordingToolbarWindow(anchorRect: CGRect(x: 100, y: 100, width: 400, height: 300))
    XCTAssertTrue(window.isVisible, "pre-record toolbar should be on screen after init")

    window.showRecordingStatusBar(recorder: ScreenRecordingManager.shared, visible: true)

    XCTAssertTrue(window.isMovableByWindowBackground)
    window.close()
  }

  func testShowRecordingStatusBar_reportsAnnotateButtonCenterInHostingWindow() throws {
    try skipIfRunningInCI("Requires onscreen window and recording manager")
    let window = RecordingToolbarWindow(anchorRect: CGRect(x: 100, y: 100, width: 400, height: 300))
    defer { window.close() }
    window.showRecordingStatusBar(recorder: ScreenRecordingManager.shared, visible: true)

    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

    XCTAssertGreaterThan(
      window.annotateButtonCenterXOffset,
      ToolbarConstants.horizontalPadding + ToolbarConstants.iconButtonSize,
      "The annotation anchor must be measured from the actual trigger, not the toolbar's left padding"
    )

    XCTAssertLessThan(
      window.annotateButtonCenterXOffset,
      window.contentView?.bounds.width ?? 0,
      "The annotation anchor must stay inside the hosting window"
    )
  }

  func testAnnotationPopover_centersOnReportedAnnotateButton() throws {
    try skipIfRunningInCI("Requires onscreen window and recording manager")
    let screenFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
    let window = RecordingToolbarWindow(
      anchorRect: CGRect(
        x: screenFrame.midX - 200,
        y: screenFrame.midY - 150,
        width: 400,
        height: 300
      )
    )
    defer { window.close() }
    window.showRecordingStatusBar(recorder: ScreenRecordingManager.shared, visible: true)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

    let popover = RecordingAnnotationToolbarWindow(annotationState: window.annotationState)
    defer { popover.close() }
    popover.anchorWindow = window
    popover.anchorButtonCenterXOffset = window.annotateButtonCenterXOffset
    popover.showPopover()

    let triggerCenterX = window.frame.minX + window.annotateButtonCenterXOffset
    XCTAssertEqual(
      popover.frame.midX,
      triggerCenterX,
      accuracy: 1,
      "The annotation popover arrow/body center must align with the pencil trigger"
    )
  }
}
