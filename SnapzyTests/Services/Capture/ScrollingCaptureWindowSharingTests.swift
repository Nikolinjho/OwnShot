//
//  ScrollingCaptureWindowSharingTests.swift
//  SnapzyTests
//
//  Unit tests for scrolling capture session chrome and toast capture visibility.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class ScrollingCaptureWindowSharingTests: XCTestCase {

  func testПанелиУправленияВышеИнтерактивнойОбласти() throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let overlay = RecordingRegionOverlayWindow(screen: screen, highlightRect: sampleAnchorRect)
    let model = ScrollingCaptureSessionModel(selectedRect: sampleAnchorRect)
    let hud = ScrollingCaptureHUDWindow(anchorRect: sampleAnchorRect, model: model,
      onStart: {}, onDone: {}, onCancel: {}, onToggleAutoScroll: {})
    let preview = ScrollingCapturePreviewWindow(anchorRect: sampleAnchorRect, model: model)
    let toolbar = RecordingToolbarWindow(anchorRect: sampleAnchorRect)
    defer { [overlay, hud, preview, toolbar].forEach { $0.close() } }
    overlay.setInteractionEnabled(true)
    toolbar.showPreRecordToolbar()

    XCTAssertFalse(overlay.ignoresMouseEvents)
    for panel in [hud, preview, toolbar] {
      XCTAssertGreaterThan(panel.level.rawValue, overlay.level.rawValue,
        "Область перехватывает клики, если панель не расположена строго выше неё")
    }
  }

  func testПревьюПринимаетКолесоДляПросмотраДлинногоСнимка() {
    let model = ScrollingCaptureSessionModel(selectedRect: sampleAnchorRect)
    let window = ScrollingCapturePreviewWindow(anchorRect: sampleAnchorRect, model: model)
    defer { window.close() }
    XCTAssertFalse(window.ignoresMouseEvents)
    XCTAssertFalse(window.canBecomeKey)
  }

  func testПанелиПомещаютсяНаЭкранеВСветлойИТёмнойТемах() throws {
    let visible = try XCTUnwrap(NSScreen.main).visibleFrame
    let anchor = CGRect(x: visible.midX - 150, y: visible.midY - 100, width: 300, height: 200)

    for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let model = ScrollingCaptureSessionModel(selectedRect: anchor)
      model.previewImage = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
        width: 220, height: 600, logicalYOffset: 0))
      let hud = ScrollingCaptureHUDWindow(anchorRect: anchor, model: model,
        onStart: {}, onDone: {}, onCancel: {}, onToggleAutoScroll: {})
      let preview = ScrollingCapturePreviewWindow(anchorRect: anchor, model: model)
      defer { [hud, preview].forEach { $0.close() } }

      for (window, name) in [(hud as NSPanel, "hud"), (preview as NSPanel, "preview")] {
        window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
        XCTAssertTrue(visible.contains(window.frame))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "scrolling-capture-\(name)-\(theme)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
  }

  func testДлинноеПревьюПозволяетДойтиДоПоследнейСтроки() throws {
    let model = ScrollingCaptureSessionModel(selectedRect: sampleAnchorRect)
    model.previewImage = try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 220, height: 1400, logicalYOffset: 0))
    let window = ScrollingCapturePreviewWindow(anchorRect: sampleAnchorRect, model: model)
    defer { window.close() }
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()
    func scrollView(in view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.compactMap { scrollView(in: $0) }.first
    }
    let scroll = try XCTUnwrap(scrollView(in: content))
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
    let lastOffset = document.frame.height - scroll.contentView.bounds.height
    scroll.contentView.scroll(to: CGPoint(x: 0, y: lastOffset))
    XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1)
  }

  func testPreviewWindow_isVisibleToRecordersAndRegisteredAsChrome() {
    let model = ScrollingCaptureSessionModel(selectedRect: sampleAnchorRect)
    let window = ScrollingCapturePreviewWindow(anchorRect: sampleAnchorRect, model: model)
    defer { window.close() }

    XCTAssertEqual(window.sharingType, NSWindow.SharingType.readOnly)
    XCTAssertTrue(
      CaptureChromeWindowRegistry.shared.windowIDs(roles: [.captureOverlay])
        .contains(CGWindowID(window.windowNumber))
    )
  }

  func testHUDWindow_isVisibleToRecordersAndRegisteredAsChrome() {
    let model = ScrollingCaptureSessionModel(selectedRect: sampleAnchorRect)
    let window = ScrollingCaptureHUDWindow(
      anchorRect: sampleAnchorRect,
      model: model,
      onStart: {},
      onDone: {},
      onCancel: {},
      onToggleAutoScroll: {}
    )
    defer { window.close() }

    XCTAssertEqual(window.sharingType, NSWindow.SharingType.readOnly)
    XCTAssertTrue(
      CaptureChromeWindowRegistry.shared.windowIDs(roles: [.captureOverlay])
        .contains(CGWindowID(window.windowNumber))
    )
  }

  func testAreaSelectionWindow_isVisibleToRecordersAndRegisteredAsChrome() throws {
    let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
    let window = AreaSelectionWindow(screen: screen, pooled: true)
    defer { window.close() }

    XCTAssertEqual(window.sharingType, NSWindow.SharingType.readOnly)
    XCTAssertTrue(
      CaptureChromeWindowRegistry.shared.windowIDs(roles: [.captureOverlay])
        .contains(CGWindowID(window.windowNumber))
    )
  }

  func testToastPanel_isExcludedFromScreenCapture() {
    // The scrolling capture hint is a toast, and it was stitched into the top
    // of a captured page.
    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.screenshotIncludeOwnApp, PreferencesKeys.recordingIncludeOwnApp]
    let originals = keys.map { defaults.object(forKey: $0) }
    defer { zip(keys, originals).forEach { defaults.set($1, forKey: $0) } }
    keys.forEach { defaults.set(false, forKey: $0) }

    let panel = AppToastManager.makeToastPanel(contentRect: sampleAnchorRect)
    defer { panel.close() }

    XCTAssertEqual(panel.sharingType, NSWindow.SharingType.none)
    XCTAssertTrue(
      CaptureChromeWindowRegistry.shared.screenshotExcludedWindowIDs()
        .contains(CGWindowID(panel.windowNumber))
    )
  }

  private var sampleAnchorRect: CGRect {
    CGRect(x: 120, y: 120, width: 360, height: 480)
  }
}

final class ScrollingCaptureAutoScrollPolicyTests: XCTestCase {

  func testНаправлениеАвтоскроллаОпределяетсяИзображениемПослеNaturalScrolling() throws {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try XCTUnwrap(TestImageFactory.texturedScrollingFrame(
      width: 320, height: 400, logicalYOffset: 0)))
    let update = try XCTUnwrap(stitcher.append(
      XCTUnwrap(TestImageFactory.texturedScrollingFrame(width: 320, height: 400, logicalYOffset: 80)),
      maxOutputHeight: 10000, expectedSignedDeltaPixels: 80))
    XCTAssertEqual(update.mergeDirection, .appendFromBottom)
    XCTAssertLessThan(ScrollingCaptureAutoScrollPolicy.wheelDeltaY(for: update.mergeDirection), 0,
      "Положительная дельта natural scrolling не должна разворачивать синтетическое колесо")
  }

  func testАвтоскроллВверхПродолжаетВизуальноеНаправление() {
    XCTAssertGreaterThan(ScrollingCaptureAutoScrollPolicy.wheelDeltaY(for: .appendFromTop), 0)
  }

  func testЗапускИзHUDВыбираетТочкуВнутриОбласти() {
    XCTAssertEqual(ScrollingCaptureAutoScrollPolicy.initialScrollTargetPoint(
      mouseLocation: CGPoint(x: 10, y: 10), selectedRect: sampleAnchorRect),
      CGPoint(x: 300, y: 360))
  }

  func testСинтетическоеКолесоПослеNaturalScrollingНеСчитаетсяСменойРучногоНаправления() {
    XCTAssertTrue(ScrollingCaptureAutoScrollPolicy.acceptsScrollDirection(
      -1, lockedManualDirection: 1, isAutoDriving: true))
    XCTAssertFalse(ScrollingCaptureAutoScrollPolicy.acceptsScrollDirection(
      -1, lockedManualDirection: 1, isAutoDriving: false))
    XCTAssertTrue(ScrollingCaptureAutoScrollPolicy.acceptsScrollDirection(
      1, lockedManualDirection: 1, isAutoDriving: false))
  }

  func testCanToggleAutoScrollOnlyAfterFirstFrameLocks() {
    assertCanToggleAutoScroll(
      phase: .ready,
      acceptedFrameCount: 0,
      isAutoScrolling: false,
      expected: false
    )
    assertCanToggleAutoScroll(
      phase: .capturing,
      acceptedFrameCount: 0,
      isAutoScrolling: false,
      expected: false
    )
    assertCanToggleAutoScroll(
      phase: .capturing,
      acceptedFrameCount: 1,
      isAutoScrolling: false,
      expected: true
    )
    assertCanToggleAutoScroll(
      phase: .capturing,
      acceptedFrameCount: 0,
      isAutoScrolling: true,
      expected: true
    )
    assertCanToggleAutoScroll(
      phase: .finalizing,
      acceptedFrameCount: 1,
      isAutoScrolling: true,
      expected: false
    )
    assertCanToggleAutoScroll(
      phase: .saving,
      acceptedFrameCount: 1,
      isAutoScrolling: true,
      expected: false
    )
  }

  func testPlaceMouseInsideSelectionGuidance_usesWarningTone() {
    let guidance = ScrollingCaptureSelectionGuidanceKind.placeMouseInsideSelection.guidance

    XCTAssertFalse(guidance.title.isEmpty)
    XCTAssertFalse(guidance.detail?.isEmpty ?? true)
    if case .warning = guidance.tone {
      return
    }
    XCTFail("Expected warning guidance tone")
  }

  func testHUDWindowContentSize_usesMinimumForCompactContent() {
    XCTAssertEqual(
      ScrollingCaptureHUDWindow.resolvedContentSize(for: CGSize(width: 120.1, height: 32.4)),
      CGSize(width: 180, height: 34)
    )
  }

  func testHUDWindowContentSize_expandsToFitAutoScrollControls() {
    XCTAssertEqual(
      ScrollingCaptureHUDWindow.resolvedContentSize(for: CGSize(width: 431.2, height: 45.1)),
      CGSize(width: 432, height: 46)
    )
  }

  func testAutoScrollPolicy_usesCurrentPointerAsScrollTarget() {
    let mouseLocation = CGPoint(x: 180, y: 220)

    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.scrollTargetPoint(
        mouseLocation: mouseLocation,
        selectedRect: sampleAnchorRect
      ),
      mouseLocation
    )
  }

  func testAutoScrollPolicy_clampsHoverPaddingInsideCapturedPane() {
    let mouseLocation = CGPoint(x: sampleAnchorRect.minX - 10, y: sampleAnchorRect.midY)

    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.scrollTargetPoint(
        mouseLocation: mouseLocation,
        selectedRect: sampleAnchorRect
      ),
      CGPoint(x: sampleAnchorRect.minX + 1, y: sampleAnchorRect.midY)
    )
  }

  func testAutoScrollPolicy_rejectsPointerOutsideHoverPadding() {
    let mouseLocation = CGPoint(x: sampleAnchorRect.minX - 40, y: sampleAnchorRect.midY)

    XCTAssertNil(
      ScrollingCaptureAutoScrollPolicy.scrollTargetPoint(
        mouseLocation: mouseLocation,
        selectedRect: sampleAnchorRect
      )
    )
  }

  func testAutoScrollPolicy_finishesOnHeightLimit() {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stitchAction(
        for: stitchUpdate(outcome: .reachedHeightLimit)
      ),
      .finishCapture
    )
  }

  func testAutoScrollPolicy_retriesBeforeTreatingNoMovementAsEnd() {
    // A page that pauses to load, or swallows a step while a sticky element
    // settles, must not be mistaken for the end of the page.
    XCTAssertGreaterThanOrEqual(ScrollingCaptureAutoScrollPolicy.noMovementFinishThreshold, 5)
    for count in 1..<ScrollingCaptureAutoScrollPolicy.noMovementFinishThreshold {
      XCTAssertEqual(
        ScrollingCaptureAutoScrollPolicy.stitchAction(
          for: stitchUpdate(outcome: .ignoredNoMovement, likelyReachedBoundary: true),
          consecutiveNoMovementCount: count
        ),
        .retryStep,
        "quiet step \(count) should scroll again"
      )
    }
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stitchAction(
        for: stitchUpdate(outcome: .ignoredNoMovement, likelyReachedBoundary: true),
        consecutiveNoMovementCount: ScrollingCaptureAutoScrollPolicy.noMovementFinishThreshold
      ),
      .finishCapture
    )
  }

  func testAutoScrollPolicy_stopsAfterRepeatedAlignmentFailures() {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stitchAction(
        for: stitchUpdate(outcome: .ignoredAlignmentFailed, matchFailureCount: 2)
      ),
      .retryCommit
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stitchAction(
        for: stitchUpdate(outcome: .ignoredAlignmentFailed, matchFailureCount: 3)
      ),
      .stopScrolling
    )
  }

  func testAutoScrollPolicy_stepDistanceStaysInsideOverlapSafeBounds() {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stepDistancePoints(regionHeight: 800),
      96,
      accuracy: 0.001
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stepDistancePoints(regionHeight: 100),
      16,
      accuracy: 0.001
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stepDistancePoints(regionHeight: 200),
      24,
      accuracy: 0.001
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.stepDistancePoints(regionHeight: 40),
      14,
      accuracy: 0.001
    )
  }

  func testAutoScrollPolicy_smallSelectionStillPostsMoreThanOneTick() {
    // A single 8 pt tick is 8 px on a 1x display, which the stitcher never
    // aligned, so every other step failed and Auto Scroll stopped.
    for regionHeight: CGFloat in [80, 100, 140] {
      for isRetry in [false, true] {
        let plan = ScrollingCaptureAutoScrollPolicy.stepPlan(regionHeight: regionHeight, isRetry: isRetry)
        XCTAssertGreaterThanOrEqual(
          plan.postedDistancePoints,
          ScrollingCaptureAutoScrollPolicy.minStepPoints,
          "region \(regionHeight) pt, retry \(isRetry)"
        )
      }
    }
  }

  func testAutoScrollPolicy_tickCountMatchesWheelDelta() {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.tickCount(forStepDistancePoints: 36),
      4
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.tickCount(forStepDistancePoints: 90),
      11
    )
  }

  func testAutoScrollPolicy_undersizedAppendTriggersSmallerFollowUpStep() {
    XCTAssertTrue(
      ScrollingCaptureAutoScrollPolicy.shouldTakeSmallerFollowUpStep(
        acceptedDeltaPixels: 24,
        expectedSignedDeltaPixels: -120
      )
    )
    XCTAssertFalse(
      ScrollingCaptureAutoScrollPolicy.shouldTakeSmallerFollowUpStep(
        acceptedDeltaPixels: 80,
        expectedSignedDeltaPixels: -120
      )
    )
  }

  func testAutoScrollPolicy_retryStepPlanUsesSmallerBurstAndLongerSettle() {
    let normal = ScrollingCaptureAutoScrollPolicy.stepPlan(regionHeight: 800, isRetry: false)
    let retry = ScrollingCaptureAutoScrollPolicy.stepPlan(regionHeight: 800, isRetry: true)

    XCTAssertGreaterThan(normal.tickCount, retry.tickCount)
    XCTAssertEqual(normal.settleNanoseconds, ScrollingCaptureAutoScrollPolicy.settleNanoseconds)
    XCTAssertEqual(retry.settleNanoseconds, ScrollingCaptureAutoScrollPolicy.retrySettleNanoseconds)
    XCTAssertEqual(
      normal.postedDistancePoints,
      CGFloat(normal.tickCount) * CGFloat(abs(ScrollingCaptureAutoScrollPolicy.wheelDeltaY))
    )
  }

  func testAutoScrollPolicy_makesUsefulProgressWithoutLongBurstsOrLostOverlap() {
    for height: CGFloat in [120, 240, 600, 800, 1000, 2000] {
      let plan = ScrollingCaptureAutoScrollPolicy.stepPlan(regionHeight: height, isRetry: false)
      let duration = Double(plan.tickCount) * Double(plan.tickIntervalNanoseconds) / 1_000_000_000

      XCTAssertGreaterThan(plan.postedDistancePoints, 0)
      XCTAssertLessThanOrEqual(plan.postedDistancePoints, height * 0.26)
      XCTAssertLessThanOrEqual(duration, 0.5, "Input must stay responsive to Stop and pointer exit")
      XCTAssertGreaterThanOrEqual(Double(plan.postedDistancePoints) / duration, 400)
    }

    // Steps are deliberately short — a little scroll, a pause, then another —
    // because a page asked for most of a viewport at once hands back frames
    // drawn mid-scroll that no offset lines up. A tall selection therefore
    // steps at the cap rather than in proportion to its height.
    let tallSelection = ScrollingCaptureAutoScrollPolicy.stepPlan(regionHeight: 1000, isRetry: false)
    XCTAssertGreaterThanOrEqual(
      tallSelection.postedDistancePoints,
      ScrollingCaptureAutoScrollPolicy.minStepPoints,
      "Tall selections should not stitch after every tiny scroll"
    )
    XCTAssertLessThanOrEqual(
      tallSelection.postedDistancePoints,
      ScrollingCaptureAutoScrollPolicy.maxStepPoints
    )
  }

  func testAutoScrollPolicy_expectedDeltaPrefersObservedScroll() {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.expectedSignedDeltaPixels(
        postedDistancePoints: 120,
        observedDistancePoints: -80,
        scaleFactor: 2
      ),
      -160
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.expectedSignedDeltaPixels(
        postedDistancePoints: 120,
        observedDistancePoints: 0,
        scaleFactor: 2
      ),
      -240
    )
  }

  func testAutoScrollPolicy_missingStitchUpdateRetriesThenStopsWithoutSaving() {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.actionForMissingStitchUpdate(consecutiveFailureCount: 1),
      .retryCommit
    )
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.actionForMissingStitchUpdate(
        consecutiveFailureCount: ScrollingCaptureAutoScrollPolicy.alignmentFailureStopThreshold
      ),
      .stopScrolling
    )
  }

  func testAutoScrollPolicy_rejectsFrameCapturedBeforeLastSyntheticEvent() {
    XCTAssertFalse(
      ScrollingCaptureAutoScrollPolicy.isCommitFrameEligible(
        capturedAt: 10.0,
        lastSyntheticEventAt: 10.5
      )
    )
    XCTAssertTrue(
      ScrollingCaptureAutoScrollPolicy.isCommitFrameEligible(
        capturedAt: 10.6,
        lastSyntheticEventAt: 10.5
      )
    )
  }

  private var sampleAnchorRect: CGRect {
    CGRect(x: 120, y: 120, width: 360, height: 480)
  }

  private func assertCanToggleAutoScroll(
    phase: ScrollingCapturePhase,
    acceptedFrameCount: Int,
    isAutoScrolling: Bool,
    expected: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      ScrollingCaptureAutoScrollPolicy.canToggle(
        phase: phase,
        acceptedFrameCount: acceptedFrameCount,
        isAutoScrolling: isAutoScrolling
      ),
      expected,
      "phase=\(phase), acceptedFrameCount=\(acceptedFrameCount), isAutoScrolling=\(isAutoScrolling)",
      file: file,
      line: line
    )
  }

  private func stitchUpdate(
    outcome: ScrollingCaptureStitchOutcome,
    matchFailureCount: Int = 0,
    likelyReachedBoundary: Bool = false
  ) -> ScrollingCaptureStitchUpdate {
    ScrollingCaptureStitchUpdate(
      outcome: outcome,
      mergedImage: nil,
      acceptedFrameCount: 1,
      outputHeight: 480,
      matchFailureCount: matchFailureCount,
      mergeDirection: .appendFromBottom,
      likelyReachedBoundary: likelyReachedBoundary,
      safety: .confirmed,
      alignmentDebug: nil
    )
  }
}
