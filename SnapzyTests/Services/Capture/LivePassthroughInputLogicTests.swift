//
//  LivePassthroughInputLogicTests.swift
//  SnapzyTests
//
//  Unit tests for LivePassthroughInputLogic: coordinate flip, hover coalescing
//  gate, and dim-visibility driver of the live-capture passthrough input path.
//

import CoreGraphics
@testable import Snapzy
import XCTest

final class LivePassthroughInputLogicTests: XCTestCase {
  func testПрицелОграничиваетсяКраямиОсновногоДисплея() {
    let frames = [CGRect(x: 0, y: 0, width: 800, height: 600)]
    let cases: [(CGPoint, CGPoint)] = [
      (CGPoint(x: -40, y: -30), CGPoint(x: 0, y: CGFloat(600).nextDown)),
      (CGPoint(x: 840, y: 650), CGPoint(x: CGFloat(800).nextDown, y: 0)),
      (CGPoint(x: 200, y: 150), CGPoint(x: 200, y: 450)),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(LivePassthroughInputLogic.appKitScreenPoint(
        fromQuartzGlobalPoint: input, mainScreenHeight: 600, screenFrames: frames
      ), expected)
    }
  }

  func testПрицелСохраняетОтрицательныйXНаЛевомДисплееИНеПопадаетВРазрыв() {
    let frames = [
      CGRect(x: 0, y: 0, width: 800, height: 600),
      CGRect(x: -640, y: 100, width: 640, height: 480),
    ]
    XCTAssertEqual(LivePassthroughInputLogic.appKitScreenPoint(
      fromQuartzGlobalPoint: CGPoint(x: -200, y: 200), mainScreenHeight: 600, screenFrames: frames
    ), CGPoint(x: -200, y: 400))
    XCTAssertEqual(LivePassthroughInputLogic.appKitScreenPoint(
      fromQuartzGlobalPoint: CGPoint(x: -900, y: 200), mainScreenHeight: 600, screenFrames: frames
    ), CGPoint(x: -640, y: 400))
    XCTAssertEqual(LivePassthroughInputLogic.appKitScreenPoint(
      fromQuartzGlobalPoint: CGPoint(x: -100, y: 550), mainScreenHeight: 600, screenFrames: frames
    ), CGPoint(x: -100, y: 100))
  }

  // MARK: - Coordinate Flip

  func testAppKitScreenPoint_flipsAgainstMainScreenHeight() {
    let result = LivePassthroughInputLogic.appKitScreenPoint(
      fromQuartzGlobalPoint: CGPoint(x: 100, y: 50),
      mainScreenHeight: 1000
    )
    XCTAssertEqual(result, CGPoint(x: 100, y: 950))
  }

  func testAppKitScreenPoint_preservesXAndHandlesEdges() {
    let topLeft = LivePassthroughInputLogic.appKitScreenPoint(
      fromQuartzGlobalPoint: .zero,
      mainScreenHeight: 1440
    )
    XCTAssertEqual(topLeft, CGPoint(x: 0, y: 1440))

    let negativeX = LivePassthroughInputLogic.appKitScreenPoint(
      fromQuartzGlobalPoint: CGPoint(x: -512, y: 1440),
      mainScreenHeight: 1440
    )
    XCTAssertEqual(negativeX, CGPoint(x: -512, y: 0))
  }

  // MARK: - Hover Coalescing Gate

  func testShouldProcessHover_firstPoint_processes() {
    XCTAssertTrue(
      LivePassthroughInputLogic.shouldProcessHover(
        newPoint: CGPoint(x: 10, y: 10),
        lastProcessedPoint: nil,
        containingDisplayChanged: false
      )
    )
  }

  func testShouldProcessHover_subPixelMovement_skips() {
    XCTAssertFalse(
      LivePassthroughInputLogic.shouldProcessHover(
        newPoint: CGPoint(x: 10.4, y: 10.9),
        lastProcessedPoint: CGPoint(x: 10, y: 10),
        containingDisplayChanged: false
      )
    )
  }

  func testShouldProcessHover_onePixelOrMore_processes() {
    XCTAssertTrue(
      LivePassthroughInputLogic.shouldProcessHover(
        newPoint: CGPoint(x: 11, y: 10),
        lastProcessedPoint: CGPoint(x: 10, y: 10),
        containingDisplayChanged: false
      )
    )
    XCTAssertTrue(
      LivePassthroughInputLogic.shouldProcessHover(
        newPoint: CGPoint(x: 10, y: 8.5),
        lastProcessedPoint: CGPoint(x: 10, y: 10),
        containingDisplayChanged: false
      )
    )
  }

  func testShouldProcessHover_displayChange_processesDespiteSubPixelMove() {
    // Crossing a display edge by <1px must not leave the crosshair on the wrong display.
    XCTAssertTrue(
      LivePassthroughInputLogic.shouldProcessHover(
        newPoint: CGPoint(x: 10.2, y: 10.1),
        lastProcessedPoint: CGPoint(x: 10, y: 10),
        containingDisplayChanged: true
      )
    )
  }

  // MARK: - Dim Driver

  func testShowsDim_manualRegion_preDrag_overlayPrefOn_shown() {
    XCTAssertTrue(
      LivePassthroughInputLogic.showsDim(
        interactionMode: .manualRegion,
        hasRevealedDim: false,
        isDragging: false,
        showsDimFromStart: true
      )
    )
  }

  func testShowsDim_manualRegion_preDrag_overlayPrefOff_hidden() {
    XCTAssertFalse(
      LivePassthroughInputLogic.showsDim(
        interactionMode: .manualRegion,
        hasRevealedDim: false,
        isDragging: false,
        showsDimFromStart: false
      )
    )
  }

  func testShowsDim_manualRegion_draggingOrRevealed_shown() {
    XCTAssertTrue(
      LivePassthroughInputLogic.showsDim(
        interactionMode: .manualRegion,
        hasRevealedDim: false,
        isDragging: true,
        showsDimFromStart: false
      )
    )
    XCTAssertTrue(
      LivePassthroughInputLogic.showsDim(
        interactionMode: .manualRegion,
        hasRevealedDim: true,
        isDragging: false,
        showsDimFromStart: false
      )
    )
  }

  func testShowsDim_applicationWindow_alwaysShown() {
    XCTAssertTrue(
      LivePassthroughInputLogic.showsDim(
        interactionMode: .applicationWindow,
        hasRevealedDim: false,
        isDragging: false,
        showsDimFromStart: false
      )
    )
    XCTAssertTrue(
      LivePassthroughInputLogic.showsDim(
        interactionMode: .applicationWindow,
        hasRevealedDim: false,
        isDragging: false,
        showsDimFromStart: true
      )
    )
  }

  // MARK: - Cursor Hide/Show Balance

  func testТестовыйХостНеСкрываетКурсорЧерезЭффектПоУмолчанию() {
    var hider = LivePassthroughCursorHider()
    // Несуществующий дисплей делает red безопасным для рабочего стола.
    hider.hide(displayIDs: [999_999_999])
    XCTAssertFalse(hider.isHidden, "XCTest не должен владеть настоящим скрытием курсора")
  }

  private final class CursorEffectRecorder {
    var hidden: [CGDirectDisplayID] = []
    var shown: [CGDirectDisplayID] = []
  }

  private func makeRecorder() -> (
    recorder: CursorEffectRecorder,
    hider: (CGDirectDisplayID) -> Void,
    shower: (CGDirectDisplayID) -> Void
  ) {
    let recorder = CursorEffectRecorder()
    return (
      recorder,
      { recorder.hidden.append($0) },
      { recorder.shown.append($0) }
    )
  }

  func testCursorHider_hide_callsEffectPerDisplayAndRecords() {
    let (recorder, hide, _) = makeRecorder()
    var hider = LivePassthroughCursorHider()

    hider.hide(displayIDs: [1, 2], hider: hide)

    XCTAssertEqual(hider.hiddenDisplayIDs, [1, 2])
    XCTAssertEqual(Set(recorder.hidden), [1, 2])
    XCTAssertTrue(hider.isHidden)
  }

  func testCursorHider_hide_isIdempotentPerDisplay() {
    let (recorder, hide, _) = makeRecorder()
    var hider = LivePassthroughCursorHider()

    hider.hide(displayIDs: [1, 2], hider: hide)
    // Mid-session display attach re-hides the whole set plus the new display.
    hider.hide(displayIDs: [1, 2, 3], hider: hide)

    XCTAssertEqual(hider.hiddenDisplayIDs, [1, 2, 3])
    XCTAssertEqual(recorder.hidden.sorted(), [1, 2, 3], "already-hidden displays must not be hidden twice")
  }

  func testCursorHider_showAll_showsExactlyWhatWasHidden_onceEach() {
    let (recorder, hide, show) = makeRecorder()
    var hider = LivePassthroughCursorHider()

    hider.hide(displayIDs: [1, 2, 3], hider: hide)
    hider.showAll(shower: show)

    XCTAssertEqual(Set(recorder.shown), [1, 2, 3])
    XCTAssertTrue(hider.hiddenDisplayIDs.isEmpty)
    XCTAssertFalse(hider.isHidden)

    // A second teardown pass (idempotent funnel) must not show again.
    hider.showAll(shower: show)
    XCTAssertEqual(recorder.shown.count, 3)
  }

  func testCursorHider_hideShowHide_balancesAcrossSessions() {
    let (recorder, hide, show) = makeRecorder()
    var hider = LivePassthroughCursorHider()

    hider.hide(displayIDs: [1], hider: hide)
    hider.showAll(shower: show)
    hider.hide(displayIDs: [1], hider: hide)
    hider.showAll(shower: show)

    XCTAssertEqual(recorder.hidden, [1, 1])
    XCTAssertEqual(recorder.shown, [1, 1])
  }

  func testCursorHider_showAll_withoutHide_isNoOp() {
    let (recorder, _, show) = makeRecorder()
    var hider = LivePassthroughCursorHider()

    hider.showAll(shower: show)

    XCTAssertTrue(recorder.shown.isEmpty)
  }

  // MARK: - Cursor Restore (teardown warp)

  private enum RestoreEffect: Equatable {
    case setSuppressionInterval(CFTimeInterval)
    case warp(CGPoint)
    case reassociate
  }

  /// Teardown warps the cursor to the last tap-observed location. macOS suppresses
  /// hardware mouse events for 0.25s after a warp by default — the cursor froze and
  /// then jumped as the backlog landed. The restorer must zero the suppression
  /// interval BEFORE the warp lands, then re-associate.
  func testCursorRestore_zeroesSuppressionIntervalBeforeWarp_thenReassociates() {
    var effects: [RestoreEffect] = []
    let restorer = LivePassthroughCursorRestorer(
      setSuppressionInterval: { effects.append(.setSuppressionInterval($0)) },
      warp: { effects.append(.warp($0)) },
      reassociate: { effects.append(.reassociate) }
    )
    let target = CGPoint(x: 200, y: 200)

    restorer.restore(to: target)

    XCTAssertEqual(
      effects,
      [
        .setSuppressionInterval(0),
        .warp(target),
        .reassociate,
      ],
      "suppression must be zeroed before the warp, with re-association last"
    )
  }

  /// A zero suppression interval is the whole point of the restore — any other value
  /// keeps the post-warp freeze alive.
  func testCursorRestore_suppressionInterval_isZero() {
    var intervals: [CFTimeInterval] = []
    let restorer = LivePassthroughCursorRestorer(
      setSuppressionInterval: { intervals.append($0) },
      warp: { _ in },
      reassociate: {}
    )

    restorer.restore(to: .zero)

    XCTAssertEqual(intervals, [0])
  }
}
