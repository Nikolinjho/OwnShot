//
//  AnnotateTextFrameGeometryTests.swift
//  SnapzyTests
//
//  Рамка текста по эталону: новая рамка по клику (ANN-043), ручки ширины
//  и кегля (ANN-801), двойной клик в правке (ANN-104).
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateTextFrameGeometryTests: XCTestCase {
  // AnnotateState держим до конца процесса: его деинициализация в XCTest падает.
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeText(_ text: String, bounds: CGRect, fontSize: CGFloat = 30) -> AnnotationItem {
    AnnotationItem(type: .text(text), bounds: bounds, properties: AnnotationProperties(fontSize: fontSize))
  }

  // MARK: - ANN-043

  func testNewTextFrameIsHundredPointsWideAndCenteredVerticallyOnClick() {
    let bounds = AnnotateTextFrameGeometry.newTextBounds(at: CGPoint(x: 200, y: 300), height: 50)

    XCTAssertEqual(bounds.width, 100)
    XCTAssertEqual(bounds.midY, 300)
    XCTAssertEqual(bounds.minX, 190)
  }

  func testNewTextFrameStaysInsideCanvasNearEdges() {
    let area = CGRect(x: 0, y: 0, width: 400, height: 300)
    let bounds = AnnotateTextFrameGeometry.newTextBounds(at: CGPoint(x: 4, y: 295), height: 50, within: area)

    XCTAssertEqual(bounds.minX, 0)
    XCTAssertEqual(bounds.maxY, 300)
  }

  func testAutomaticWidthKeepsNewTextFrameAtLeastHundredPoints() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 600, height: 300))
    let annotation = makeText("", bounds: CGRect(x: 20, y: 100, width: 100, height: 40), fontSize: 18)
    state.annotations = [annotation]
    state.useAutomaticTextWidth(for: annotation.id)

    state.updateAnnotationText(id: annotation.id, text: "Ab")

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.bounds.width, 100, accuracy: 0.5)
  }

  // MARK: - ANN-801

  func testTextHandlesAreSideCirclesAndBottomRightScaleSquare() {
    let bounds = CGRect(x: 10, y: 20, width: 100, height: 40)
    let centers = AnnotateTextFrameGeometry.handleCenters(for: bounds)

    XCTAssertEqual(centers.map(\.0), [.leftWidth, .rightWidth, .scale])
    XCTAssertEqual(centers[0].1, CGPoint(x: 10, y: 40))
    XCTAssertEqual(centers[1].1, CGPoint(x: 110, y: 40))
    // Ось Y вверх: правый нижний угол – minY.
    XCTAssertEqual(centers[2].1, CGPoint(x: 110, y: 20))
  }

  func testSideHandleNarrowsFrameWrapsTextAndKeepsTopAndFont() throws {
    let font = AnnotateTextLayout.font(size: 30)
    let original = AnnotateTextLayout.bounds(text: "Resize me", font: font, origin: CGPoint(x: 50, y: 100))
    let item = makeText("Resize me", bounds: original)

    let narrowed = try XCTUnwrap(AnnotateTextFrameGeometry.resizedTextItem(
      item,
      original: original,
      handle: .rightWidth,
      pointer: CGPoint(x: original.minX + 80, y: original.midY)
    ))

    XCTAssertEqual(narrowed.bounds.minX, original.minX, accuracy: 0.01)
    XCTAssertEqual(narrowed.bounds.width, 80, accuracy: 0.01)
    XCTAssertEqual(narrowed.bounds.maxY, original.maxY, accuracy: 0.01)
    XCTAssertGreaterThan(narrowed.bounds.height, original.height, "Перенос строк должен увеличить высоту рамки")
    XCTAssertEqual(narrowed.properties.fontSize, 30)
  }

  func testLeftHandleKeepsRightEdge() throws {
    let original = CGRect(x: 50, y: 100, width: 200, height: 40)
    let item = makeText("Hi", bounds: original)

    let resized = try XCTUnwrap(AnnotateTextFrameGeometry.resizedTextItem(
      item,
      original: original,
      handle: .leftWidth,
      pointer: CGPoint(x: 120, y: 120)
    ))

    XCTAssertEqual(resized.bounds.maxX, original.maxX, accuracy: 0.01)
    XCTAssertEqual(resized.bounds.width, 130, accuracy: 0.01)
  }

  func testCornerHandleScalesFontProportionally() throws {
    let original = CGRect(x: 0, y: 100, width: 200, height: 50)
    let item = makeText("Resize me", bounds: original, fontSize: 30)

    let scaled = try XCTUnwrap(AnnotateTextFrameGeometry.resizedTextItem(
      item,
      original: original,
      handle: .scale,
      pointer: CGPoint(x: 300, y: 75)
    ))

    XCTAssertEqual(scaled.properties.fontSize, 45, accuracy: 0.01)
    XCTAssertEqual(scaled.bounds.width, 300, accuracy: 0.01)
    XCTAssertEqual(scaled.bounds.minX, 0, accuracy: 0.01)
    XCTAssertEqual(scaled.bounds.maxY, original.maxY, accuracy: 0.01)
  }

  func testCornerHandleClampsFontToMenuRange() {
    let original = CGRect(x: 0, y: 100, width: 200, height: 50)
    let tiny = AnnotateTextFrameGeometry.scaleFactor(original: original, pointer: CGPoint(x: -500, y: 400), fontSize: 30)
    let huge = AnnotateTextFrameGeometry.scaleFactor(original: original, pointer: CGPoint(x: 9000, y: -9000), fontSize: 30)

    XCTAssertEqual(tiny * 30, AnnotationProperties.fontSizeRange.lowerBound, accuracy: 0.01)
    XCTAssertEqual(huge * 30, AnnotationProperties.fontSizeRange.upperBound, accuracy: 0.01)
  }

  func testCanvasMapsOnlyTextHandlesToTextFrameHandles() {
    let text = makeText("A", bounds: CGRect(x: 0, y: 0, width: 100, height: 40))
    let rectangle = AnnotationItem(type: .rectangle, bounds: CGRect(x: 0, y: 0, width: 100, height: 40), properties: AnnotationProperties())

    XCTAssertEqual(DrawingCanvasNSView.textFrameHandle(for: .left, item: text), .leftWidth)
    XCTAssertEqual(DrawingCanvasNSView.textFrameHandle(for: .right, item: text), .rightWidth)
    XCTAssertEqual(DrawingCanvasNSView.textFrameHandle(for: .bottomRight, item: text), .scale)
    XCTAssertNil(DrawingCanvasNSView.textFrameHandle(for: .textCalloutTail, item: text))
    XCTAssertNil(DrawingCanvasNSView.textFrameHandle(for: .bottomRight, item: rectangle))
  }

  func testCommitTextHandleResizeIsOneUndoStepAndStopsAutoWidth() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 600, height: 300))
    let original = CGRect(x: 20, y: 100, width: 200, height: 40)
    let annotation = makeText("Resize me", bounds: original, fontSize: 30)
    state.annotations = [annotation]
    state.useAutomaticTextWidth(for: annotation.id)
    let resized = try XCTUnwrap(AnnotateTextFrameGeometry.resizedTextItem(
      annotation,
      original: original,
      handle: .scale,
      pointer: CGPoint(x: 320, y: 80)
    ))

    // Холст записывает шаг undo в начале жеста, затем фиксирует итог.
    state.saveState()
    state.commitTextHandleResize(id: annotation.id, resized: resized)

    let committed = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(committed.properties.fontSize, resized.properties.fontSize)
    XCTAssertEqual(committed.bounds, resized.bounds)

    // Ширину задал пользователь – ввод больше не растягивает рамку.
    state.updateAnnotationText(id: annotation.id, text: "Resize me with a much longer sentence")
    XCTAssertEqual(try XCTUnwrap(state.annotations.first).bounds.width, resized.bounds.width, accuracy: 0.5)

    state.undo()
    let restored = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(restored.properties.fontSize, 30)
    XCTAssertEqual(restored.bounds, original)
  }

  // MARK: - ANN-104

  func testSecondClickOfOpeningDoubleClickKeepsCaretAtEnd() {
    XCTAssertTrue(AnnotateTextFrameGeometry.keepsCaretAtEnd(clickCount: 2, hasReceivedMouseDown: false))
    XCTAssertFalse(AnnotateTextFrameGeometry.keepsCaretAtEnd(clickCount: 2, hasReceivedMouseDown: true))
    XCTAssertFalse(AnnotateTextFrameGeometry.keepsCaretAtEnd(clickCount: 1, hasReceivedMouseDown: false))
  }

  func testTextToolPressOnSelectedTextEditsOnClick() {
    let text = makeText("Y", bounds: CGRect(x: 0, y: 0, width: 100, height: 40))
    let intent = DrawingCanvasNSView.drawingToolPressIntent(
      tool: .text,
      edgeHit: text,
      selectedIds: [text.id],
      optionHeld: false
    )

    XCTAssertEqual(intent.textEditOnClickId, text.id)
  }
}
