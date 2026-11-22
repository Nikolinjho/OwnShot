//
//  AnnotateTextSnappingTests.swift
//  SnapzyTests
//
//  Pure snap-math tests with a hand-built AnnotateTextLineProfile (no Vision
//  needed): single-line snapping, drag-direction normalization, multi-line
//  text-selection semantics, column-break truncation, freehand fallbacks, and
//  the segment -> annotation conversion.
//

import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Snapzy

final class AnnotateTextSnappingTests: XCTestCase {
  // Three 20pt lines of one text block, 10pt apart, spanning x 100...500
  // (bottom-left image points, top line first).
  private static let wordEdges: [CGFloat] = [100, 180, 200, 300, 320, 500]

  private static func line(
    minY: CGFloat,
    minX: CGFloat = 100,
    maxX: CGFloat = 500,
    height: CGFloat = 20
  ) -> AnnotateTextLine {
    AnnotateTextLine(
      bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: height),
      wordEdges: wordEdges.map { min(max($0, minX), maxX) }
    )
  }

  private let profile = AnnotateTextLineProfile(lines: [
    AnnotateTextSnappingTests.line(minY: 400), // midY 410
    AnnotateTextSnappingTests.line(minY: 370), // midY 380
    AnnotateTextSnappingTests.line(minY: 340)  // midY 350
  ])
  private let tolerance: CGFloat = 4

  private func resolve(
    from start: CGPoint,
    to current: CGPoint,
    path: [CGPoint]? = nil,
    profile: AnnotateTextLineProfile? = nil
  ) -> [AnnotateTextSnapSegment] {
    AnnotateTextSnapping.resolve(
      start: start,
      current: current,
      path: path ?? [start, current],
      profile: profile ?? self.profile,
      pointerTolerance: tolerance
    )
  }

  // MARK: - Single line

  func testSnapsToTheLineUnderTheDragAndToWordEdges() {
    let segments = resolve(from: CGPoint(x: 185, y: 380), to: CGPoint(x: 295, y: 378))

    // x snapped 185 -> 180 and 295 -> 300; bar centered on the line's midY at
    // 1.5x the line height, with 0.4x line height padding on both sides
    // (поля плашки эталона, ANN-796).
    XCTAssertEqual(segments.map(\.rect), [CGRect(x: 172, y: 365, width: 136, height: 30)])
  }

  func testShakyDragStillSnapsToASingleStraightBar() {
    let shakyPath = [
      CGPoint(x: 185, y: 380), CGPoint(x: 210, y: 386), CGPoint(x: 240, y: 374),
      CGPoint(x: 265, y: 384), CGPoint(x: 295, y: 378)
    ]
    let segments = resolve(from: CGPoint(x: 185, y: 380), to: CGPoint(x: 295, y: 378), path: shakyPath)

    XCTAssertEqual(segments.map(\.rect), [CGRect(x: 172, y: 365, width: 136, height: 30)])
  }

  func testRightToLeftDragProducesTheSameBar() {
    let segments = resolve(from: CGPoint(x: 295, y: 378), to: CGPoint(x: 185, y: 380))

    XCTAssertEqual(segments.map(\.rect), [CGRect(x: 172, y: 365, width: 136, height: 30)])
  }

  func testEndFarFromAnyWordEdgeStaysWhereThePointerIs() {
    // 260 is >15pt from every word edge, so it is only clamped to the line.
    let segments = resolve(from: CGPoint(x: 185, y: 380), to: CGPoint(x: 260, y: 380))

    XCTAssertEqual(segments.map(\.rect), [CGRect(x: 172, y: 365, width: 96, height: 30)])
  }

  func testDragBeyondTheLineEndFollowsTheStrokeWithinALimit() {
    // Правый край идёт по концу штриха, но не дальше двух высот строки за её концом.
    let segments = resolve(from: CGPoint(x: 60, y: 380), to: CGPoint(x: 900, y: 380))

    XCTAssertEqual(segments.map(\.rect), [CGRect(x: 92, y: 365, width: 456, height: 30)])
  }

  func testSmallLineBarFollowsTheStrokeEndLikeTheReference() {
    // Мелкая строка эталона (b5-highlighter-snap): глифы 61–309, штрих до 330,
    // плашка 55–336 – левое поле 6 pt, правый край = конец штриха + 6 pt.
    let smallLine = AnnotateTextLine(
      bounds: CGRect(x: 61, y: 320, width: 248, height: 15),
      wordEdges: [61, 309]
    )
    let segments = AnnotateTextSnapping.resolve(
      start: CGPoint(x: 66, y: 327),
      current: CGPoint(x: 330, y: 327),
      path: [CGPoint(x: 66, y: 327), CGPoint(x: 330, y: 327)],
      profile: AnnotateTextLineProfile(lines: [smallLine]),
      pointerTolerance: tolerance
    )

    let rect = segments.first?.rect
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(rect?.minX ?? 0, 55, accuracy: 0.5)
    XCTAssertEqual(rect?.maxX ?? 0, 336, accuracy: 0.5)
    XCTAssertEqual(rect?.height ?? 0, 22.5, accuracy: 0.01)
  }

  // MARK: - Multi-line

  func testDownwardMultiLineDragUsesTextSelectionSemantics() {
    let segments = resolve(
      from: CGPoint(x: 185, y: 410),
      to: CGPoint(x: 295, y: 350),
      path: [CGPoint(x: 185, y: 410), CGPoint(x: 240, y: 380), CGPoint(x: 295, y: 350)]
    )

    XCTAssertEqual(segments.map(\.rect), [
      CGRect(x: 172, y: 395, width: 336, height: 30), // anchor -> line end
      CGRect(x: 92, y: 365, width: 416, height: 30), // full line
      CGRect(x: 92, y: 335, width: 216, height: 30)  // line start -> pointer
    ])
  }

  func testUpwardMultiLineDragMirrorsTheSelection() {
    let segments = resolve(
      from: CGPoint(x: 185, y: 350),
      to: CGPoint(x: 295, y: 410),
      path: [CGPoint(x: 185, y: 350), CGPoint(x: 240, y: 380), CGPoint(x: 295, y: 410)]
    )

    XCTAssertEqual(segments.map(\.rect), [
      CGRect(x: 292, y: 395, width: 216, height: 30),
      CGRect(x: 92, y: 365, width: 416, height: 30),
      CGRect(x: 92, y: 335, width: 96, height: 30)
    ])
  }

  func testMultiLineDragUsesOneUniformBarHeight() {
    // Vision line boxes grow with descenders; a sweep must not look ragged.
    let unevenProfile = AnnotateTextLineProfile(lines: [
      Self.line(minY: 400),                        // h 20, midY 410
      Self.line(minY: 366, height: 26),            // h 26, midY 379
      Self.line(minY: 336)                         // h 20, midY 346
    ])

    let segments = resolve(
      from: CGPoint(x: 185, y: 410),
      to: CGPoint(x: 295, y: 346),
      path: [CGPoint(x: 185, y: 410), CGPoint(x: 240, y: 379), CGPoint(x: 295, y: 346)],
      profile: unevenProfile
    )

    XCTAssertEqual(segments.map(\.rect.height), [30, 30, 30])
    XCTAssertEqual(segments.map(\.rect), [
      CGRect(x: 172, y: 395, width: 336, height: 30),
      CGRect(x: 92, y: 364, width: 416, height: 30),
      CGRect(x: 92, y: 331, width: 216, height: 30)
    ])
  }

  func testChainStopsAtAColumnBreak() {
    let disjointProfile = AnnotateTextLineProfile(lines: [
      Self.line(minY: 400),
      Self.line(minY: 370),
      Self.line(minY: 340, minX: 900, maxX: 1300) // different column
    ])

    let segments = resolve(
      from: CGPoint(x: 185, y: 410),
      to: CGPoint(x: 295, y: 350),
      path: [CGPoint(x: 185, y: 410), CGPoint(x: 240, y: 380), CGPoint(x: 295, y: 350)],
      profile: disjointProfile
    )

    // The unrelated column is dropped, so the second line becomes the tail.
    XCTAssertEqual(segments.map(\.rect), [
      CGRect(x: 172, y: 395, width: 336, height: 30),
      CGRect(x: 92, y: 365, width: 216, height: 30)
    ])
  }

  // MARK: - Freehand fallbacks

  func testEmptyProfileProducesNoSegments() {
    let segments = resolve(
      from: CGPoint(x: 185, y: 380),
      to: CGPoint(x: 295, y: 380),
      profile: .empty
    )

    XCTAssertTrue(segments.isEmpty)
  }

  func testDragAwayFromAnyTextProducesNoSegments() {
    XCTAssertTrue(resolve(from: CGPoint(x: 185, y: 200), to: CGPoint(x: 295, y: 200)).isEmpty)
  }

  func testTooShortDragProducesNoSegments() {
    XCTAssertTrue(resolve(from: CGPoint(x: 185, y: 380), to: CGPoint(x: 190, y: 380)).isEmpty)
  }

  func testVerticalDragProducesNoSegments() {
    XCTAssertTrue(resolve(from: CGPoint(x: 185, y: 410), to: CGPoint(x: 187, y: 350)).isEmpty)
  }

  func testScribbleThatLeavesTheTextBandStaysFreehand() {
    let scribble = [
      CGPoint(x: 185, y: 380), CGPoint(x: 200, y: 300), CGPoint(x: 220, y: 300),
      CGPoint(x: 240, y: 300), CGPoint(x: 295, y: 380)
    ]

    XCTAssertTrue(resolve(from: CGPoint(x: 185, y: 380), to: CGPoint(x: 295, y: 380), path: scribble).isEmpty)
  }

  // MARK: - Segment geometry

  func testSegmentPaintsARoundedRectangleWithTheReferenceRadius() {
    let rect = CGRect(x: 172, y: 365, width: 136, height: 30)
    let segment = AnnotateTextSnapSegment(rect: rect)

    // Радиус углов 0,15 высоты (≈6 pt у плашки эталона 41 pt), штрих маркера
    // (3 × strokeWidth) равен двум радиусам.
    XCTAssertEqual(segment.cornerRadius, 4.5, accuracy: 0.0001)
    XCTAssertEqual(segment.strokeWidth * 3, 9, accuracy: 0.0001)

    let path = CGMutablePath()
    path.addLines(between: segment.highlightPoints)
    let painted = path.copy(
      strokingWithWidth: AnnotationRenderer.highlightLineWidth(forStrokeWidth: segment.strokeWidth),
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 10
    )

    // Вся площадь плашки закрашена, без щелей между строками змейки.
    for x in stride(from: rect.minX + 1.5, through: rect.maxX - 1.5, by: 2) {
      for y in stride(from: rect.minY + 1.5, through: rect.maxY - 1.5, by: 1) {
        XCTAssertTrue(painted.contains(CGPoint(x: x, y: y)), "Щель в плашке в точке (\(x), \(y))")
      }
    }
    // Края прямые: середины сторон доходят до края прямоугольника.
    XCTAssertTrue(painted.contains(CGPoint(x: rect.midX, y: rect.minY + 0.2)))
    XCTAssertTrue(painted.contains(CGPoint(x: rect.minX + 0.2, y: rect.midY)))
    // Углы скруглены: самый угол не закрашен, за пределы прямоугольника ничего не выходит.
    XCTAssertFalse(painted.contains(CGPoint(x: rect.minX + 0.4, y: rect.minY + 0.4)))
    XCTAssertFalse(painted.contains(CGPoint(x: rect.maxX - 0.4, y: rect.maxY - 0.4)))
    XCTAssertFalse(painted.contains(CGPoint(x: rect.midX, y: rect.maxY + 0.5)))
    XCTAssertEqual(painted.boundingBoxOfPath.minX, rect.minX, accuracy: 0.01)
    XCTAssertEqual(painted.boundingBoxOfPath.maxY, rect.maxY, accuracy: 0.01)
  }

  func testSegmentsBecomeOrdinaryHighlightAnnotations() {
    let segments = [
      AnnotateTextSnapSegment(rect: CGRect(x: 172, y: 365, width: 136, height: 30)),
      AnnotateTextSnapSegment(rect: CGRect(x: 92, y: 335, width: 216, height: 30))
    ]

    let items = AnnotationFactory.createTextSnappedHighlights(
      segments: segments,
      context: AnnotationFactory.CreationContext(
        properties: AnnotationProperties(strokeColor: .yellow, strokeWidth: 3),
        arrowStyle: .straight,
        blurType: .pixelated,
        counterValue: 0,
        watermarkText: "Snapzy",
        activeAnnotationBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
      )
    )

    XCTAssertEqual(items.count, 2)
    for (item, segment) in zip(items, segments) {
      guard case .highlight(let points) = item.type else {
        return XCTFail("Expected a highlight annotation")
      }
      XCTAssertEqual(points, segment.highlightPoints)
      XCTAssertEqual(item.properties.strokeWidth, segment.strokeWidth, accuracy: 0.0001)
      XCTAssertEqual(item.properties.strokeColor, .yellow)
    }
  }

  // MARK: - Vision conversion

  func testVisionBoxKeepsBottomLeftOriginInImagePoints() {
    let rect = AnnotateTextSnapDetector.imagePointRect(
      fromVisionBoundingBox: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.1),
      imagePointSize: CGSize(width: 400, height: 200)
    )

    // Vision and the annotation canvas both measure Y from the bottom.
    XCTAssertEqual(rect, CGRect(x: 100, y: 40, width: 200, height: 20))
  }

  /// End-to-end guard for the coordinate convention: Vision reports normalized
  /// boxes from the bottom, and so does the annotation canvas, so text drawn
  /// near the top of the image must come back with a high Y.
  func testDetectorReportsTextNearTheImageTopWithAHighY() throws {
    try skipIfRunningInCI()
    let size = CGSize(width: 600, height: 300)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    // AppKit's image context is bottom-left origin, so this sits near the top.
    ("Highlight this sentence" as NSString).draw(
      at: NSPoint(x: 40, y: 230),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 34),
        .foregroundColor: NSColor.black
      ]
    )
    image.unlockFocus()

    let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let profile = AnnotateTextSnapDetector.detectLines(in: cgImage, imagePointSize: size)

    let line = try XCTUnwrap(profile.lines.first, "Vision found no text in the rendered sample")
    XCTAssertGreaterThan(line.bounds.midY, size.height / 2)
    XCTAssertLessThan(line.bounds.minX, size.width / 2)
    XCTAssertGreaterThan(line.wordEdges.count, 2, "Expected per-word edges for snapping")
  }

  // MARK: - Preference

  @MainActor
  func testQuickPropertiesExposeTheToggleOnlyForHighlighterDefaults() throws {
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 400, height: 300))

    state.activateTool(.highlighter)
    XCTAssertTrue(state.quickPropertiesSupportsHighlighterTextSnapping)

    // Other tools never show it.
    state.activateTool(.rectangle)
    XCTAssertFalse(state.quickPropertiesSupportsHighlighterTextSnapping)

    // A committed highlight's geometry is fixed, so the selected-item context
    // (where every control edits that item) hides the creation-time toggle.
    let highlight = AnnotationItem(
      type: .highlight([CGPoint(x: 10, y: 20), CGPoint(x: 90, y: 20)]),
      bounds: CGRect(x: 10, y: 19, width: 80, height: 2),
      properties: AnnotationProperties()
    )
    state.annotations.append(highlight)
    state.activateTool(.highlighter)
    state.selectedAnnotationId = highlight.id
    state.setSelectedAnnotationIds([highlight.id])
    XCTAssertFalse(state.quickPropertiesSupportsHighlighterTextSnapping)

    state.deselectAnnotation()
    XCTAssertTrue(state.quickPropertiesSupportsHighlighterTextSnapping)
  }

  @MainActor
  func testQuickPropertiesToggleDrivesTheSnappingPreference() {
    let state = makeAnnotateState()
    let binding = state.quickHighlighterTextSnappingBinding

    XCTAssertTrue(binding.wrappedValue)

    binding.wrappedValue = false
    XCTAssertFalse(state.isHighlighterTextSnappingEnabled)

    state.isHighlighterTextSnappingEnabled = true
    XCTAssertTrue(binding.wrappedValue)
  }

  @MainActor
  func testTextSnappingPreferenceDefaultsOnAndPersists() {
    let defaults = UserDefaultsFactory.make()
    let state = AnnotateState(defaults: defaults)
    Self.retainedAnnotateStates.append(state)

    XCTAssertTrue(state.isHighlighterTextSnappingEnabled)

    state.isHighlighterTextSnappingEnabled = false
    XCTAssertEqual(
      defaults.object(forKey: PreferencesKeys.annotateHighlighterTextSnappingEnabled) as? Bool,
      false
    )
    // A fresh state over the same defaults reads the persisted value back.
    // Retain it like every other AnnotateState: deinitializing this MainActor
    // ObservableObject can crash the test runner (see retainedAnnotateStates).
    let fresh = AnnotateState(defaults: defaults)
    Self.retainedAnnotateStates.append(fresh)
    XCTAssertFalse(fresh.isHighlighterTextSnappingEnabled)
  }

  // Keep AnnotateState alive for the test process; XCTest scope cleanup can
  // crash while deinitializing this MainActor app-level ObservableObject.
  @MainActor private static var retainedAnnotateStates: [AnnotateState] = []

  @MainActor
  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeImage(width: Int, height: Int) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }
}
