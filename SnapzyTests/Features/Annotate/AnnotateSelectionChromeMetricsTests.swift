//
//  AnnotateSelectionChromeMetricsTests.swift
//  SnapzyTests
//

import CoreGraphics
import XCTest
@testable import Snapzy

// Ручка выделения эталона – 16 pt: ядро 12 pt и белая кайма 2 pt
// (spec-066 R22, evidence/spec-063-live/ref-rect-selected-3eq.png). Раньше тесты фиксировали 8 pt.
final class AnnotateSelectionChromeMetricsTests: XCTestCase {
  func testUnitFitAtUnitZoomPreservesExistingChromeMeasurements() {
    let metrics = AnnotateSelectionChromeMetrics(fitScale: 1, zoomScale: 1)

    XCTAssertEqual(
      metrics.imageLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize),
      16,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      metrics.canvasLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize),
      16,
      accuracy: 0.0001
    )
  }

  func testTallCaptureAtFitKeepsVisibleAndHitHandlesAtSixteenScreenPoints() {
    let fitScale: CGFloat = 0.05
    let metrics = AnnotateSelectionChromeMetrics(fitScale: fitScale, zoomScale: 1)

    XCTAssertEqual(
      metrics.imageLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize),
      320,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      metrics.canvasLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize),
      16,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      metrics.imageLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize) * fitScale,
      16,
      accuracy: 0.0001
    )
  }

  func testTallCaptureAtMaximumZoomKeepsSelectionChromeInScreenSpace() {
    let fitScale: CGFloat = 0.05
    let zoomScale: CGFloat = 16
    let metrics = AnnotateSelectionChromeMetrics(fitScale: fitScale, zoomScale: zoomScale)

    XCTAssertEqual(
      metrics.imageLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize),
      20,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      metrics.canvasLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      metrics.imageLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize) * fitScale * zoomScale,
      16,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      metrics.canvasLength(forScreenPoints: AnnotateSelectionChromeMetrics.handleSize) * zoomScale,
      16,
      accuracy: 0.0001
    )
  }

  func testInvalidScalesRemainFinite() {
    let metrics = AnnotateSelectionChromeMetrics(fitScale: 0, zoomScale: 0)

    XCTAssertTrue(metrics.imageLength(forScreenPoints: 1).isFinite)
    XCTAssertTrue(metrics.canvasLength(forScreenPoints: 1).isFinite)
  }
}
