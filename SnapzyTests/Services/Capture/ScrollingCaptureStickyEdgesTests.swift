//
//  ScrollingCaptureStickyEdgesTests.swift
//  SnapzyTests
//
//  Unit tests for fixed header/footer detection in scrolling capture.
//

import CoreGraphics
import XCTest
@testable import Snapzy

final class ScrollingCaptureStickyEdgesTests: XCTestCase {

  private let width = 240
  private let height = 400

  // MARK: - Detector

  func testAccumulator_findsFullWidthHeaderAndFooter() throws {
    var votes = ScrollingCaptureStickyEdgeAccumulator()
    for index in 0..<4 {
      votes.add(
        ScrollingCaptureStickyEdgeDetector.chromeRows(
          previous: try lumaPlane(offset: index * 40, header: 50, footer: 30),
          current: try lumaPlane(offset: (index + 1) * 40, header: 50, footer: 30)
        )
      )
    }

    let edges = votes.edges(frameHeight: height)

    XCTAssertGreaterThanOrEqual(edges.top, 50)
    XCTAssertLessThanOrEqual(edges.top, 50 + ScrollingCaptureStickyEdgeAccumulator.bandMargin)
    XCTAssertGreaterThanOrEqual(edges.bottom, 30)
    XCTAssertLessThanOrEqual(edges.bottom, 30 + ScrollingCaptureStickyEdgeAccumulator.bandMargin)
  }

  func testAccumulator_findsPartialWidthFooterChrome() throws {
    var votes = ScrollingCaptureStickyEdgeAccumulator()
    for index in 0..<4 {
      votes.add(
        ScrollingCaptureStickyEdgeDetector.chromeRows(
          previous: try lumaPlane(offset: index * 40, header: 0, footer: 40, footerChromeWidth: width / 2),
          current: try lumaPlane(offset: (index + 1) * 40, header: 0, footer: 40, footerChromeWidth: width / 2)
        )
      )
    }

    let edges = votes.edges(frameHeight: height)

    XCTAssertEqual(edges.top, 0)
    XCTAssertGreaterThanOrEqual(edges.bottom, 40)
  }

  func testAccumulator_needsRepeatedVotes() throws {
    var votes = ScrollingCaptureStickyEdgeAccumulator()
    votes.add(
      ScrollingCaptureStickyEdgeDetector.chromeRows(
        previous: try lumaPlane(offset: 0, header: 50, footer: 30),
        current: try lumaPlane(offset: 40, header: 50, footer: 30)
      )
    )

    XCTAssertEqual(votes.edges(frameHeight: height), .none)
  }

  func testDetect_scrollingContentHasNoChrome() throws {
    let edges = ScrollingCaptureStickyEdgeDetector.detect(
      previous: try lumaPlane(offset: 0, header: 0, footer: 0),
      current: try lumaPlane(offset: 40, header: 0, footer: 0)
    )

    XCTAssertEqual(edges, .none)
  }

  // MARK: - Stitcher

  func testStitch_keepsHeaderOnceAtTopAndFooterOnceAtEnd() throws {
    let merged = try stitch(header: 50, footer: 30, footerChromeWidth: nil, step: 40, steps: 8)
    let reference = try XCTUnwrap(
      TestImageFactory.chromeScrollingFrame(
        width: width,
        height: height + 40 * 8,
        logicalYOffset: 0,
        headerHeight: 50,
        footerHeight: 30
      )
    )

    XCTAssertEqual(merged.height, reference.height)
    XCTAssertEqual(
      TestImageFactory.rgbaRows(of: merged, rowCount: merged.height),
      TestImageFactory.rgbaRows(of: reference, rowCount: reference.height)
    )
  }

  func testStitch_floatingBannerIsNotRepeated() throws {
    let merged = try stitch(header: 0, footer: 40, footerChromeWidth: width / 2, step: 40, steps: 8)
    let reference = try XCTUnwrap(
      TestImageFactory.chromeScrollingFrame(
        width: width,
        height: height + 40 * 8,
        logicalYOffset: 0,
        headerHeight: 0,
        footerHeight: 40,
        footerChromeWidth: width / 2
      )
    )

    XCTAssertEqual(merged.height, reference.height)
    XCTAssertEqual(
      TestImageFactory.rgbaRows(of: merged, rowCount: merged.height),
      TestImageFactory.rgbaRows(of: reference, rowCount: reference.height)
    )
  }

  func testПоздноРаспознаннаяНижняяПанельНеДублируетСтроки() throws {
    let frameHeight = 1_200
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: try stripedFooterFrame(height: frameHeight, offset: 0))

    for offset in stride(from: 40, through: 240, by: 40) {
      let frame = try stripedFooterFrame(height: frameHeight, offset: offset)
      let update = try XCTUnwrap(stitcher.append(frame, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 40))
      guard case .appended(deltaY: 40) = update.outcome else {
        return XCTFail("Ожидалась склейка с шагом 40: " + String(describing: update.outcome))
      }
      XCTAssertEqual(update.outputHeight, frameHeight + offset)
    }

    let reference = try stripedFooterFrame(height: 1_440, offset: 0)
    let result = try XCTUnwrap(stitcher.mergedImage())
    XCTAssertTrue(
      TestImageFactory.rgbaRows(of: result, rowCount: result.height)
        == TestImageFactory.rgbaRows(of: reference, rowCount: reference.height),
      "Закреплённая панель должна появляться только в конце"
    )
  }

  func testУточнениеНижнейПанелиНеМеняетСнимокПослеЛимита() throws {
    let stitcher = ScrollingCaptureStitcher()
    let frameHeight = 1_200
    let limit = 1_260
    _ = stitcher.start(with: try stripedFooterFrame(height: frameHeight, offset: 0))

    for offset in [40, 80] {
      let frame = try stripedFooterFrame(height: frameHeight, offset: offset)
      _ = stitcher.append(frame, maxOutputHeight: limit, expectedSignedDeltaPixels: 40)
    }
    let atLimit = try XCTUnwrap(stitcher.mergedImage())
    XCTAssertEqual(atLimit.height, limit)

    let next = try stripedFooterFrame(height: frameHeight, offset: 120)
    let update = try XCTUnwrap(stitcher.append(next, maxOutputHeight: limit, expectedSignedDeltaPixels: 40))
    guard case .reachedHeightLimit = update.outcome else { return XCTFail("Ожидался достигнутый лимит") }
    let result = try XCTUnwrap(update.mergedImage)
    XCTAssertEqual(result.height, limit)
    XCTAssertTrue(
      TestImageFactory.rgbaRows(of: result, rowCount: limit) == TestImageFactory.rgbaRows(of: atLimit, rowCount: limit),
      "После достижения лимита пиксели снимка должны сохраниться"
    )
  }

  // MARK: - Helpers

  private struct StitchFailure: Error {}

  private func stripedFooterFrame(height: Int, offset: Int) throws -> CGImage {
    try XCTUnwrap(TestImageFactory.chromeScrollingFrame(
      width: 200, height: height, logicalYOffset: offset, headerHeight: 0, footerHeight: 250, footerRepeatsRows: true
    ))
  }

  private func stitch(
    header: Int,
    footer: Int,
    footerChromeWidth: Int?,
    step: Int,
    steps: Int
  ) throws -> CGImage {
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(
      with: try frame(offset: 0, header: header, footer: footer, footerChromeWidth: footerChromeWidth)
    )

    for index in 1...steps {
      let update = try XCTUnwrap(
        stitcher.append(
          try frame(offset: index * step, header: header, footer: footer, footerChromeWidth: footerChromeWidth),
          maxOutputHeight: 10_000,
          expectedSignedDeltaPixels: step
        )
      )
      guard case .appended(let deltaY) = update.outcome else {
        XCTFail("Step \(index) did not append: \(update.outcome)")
        throw StitchFailure()
      }
      XCTAssertEqual(deltaY, step)
    }

    return try XCTUnwrap(stitcher.mergedImage())
  }

  private func frame(offset: Int, header: Int, footer: Int, footerChromeWidth: Int? = nil) throws -> CGImage {
    try XCTUnwrap(
      TestImageFactory.chromeScrollingFrame(
        width: width,
        height: height,
        logicalYOffset: offset,
        headerHeight: header,
        footerHeight: footer,
        footerChromeWidth: footerChromeWidth
      )
    )
  }

  private func lumaPlane(
    offset: Int,
    header: Int,
    footer: Int,
    footerChromeWidth: Int? = nil
  ) throws -> ScrollingCaptureLumaPlane {
    try XCTUnwrap(
      ScrollingCaptureLumaPlane(
        cgImage: try frame(offset: offset, header: header, footer: footer, footerChromeWidth: footerChromeWidth)
      )
    )
  }
}
