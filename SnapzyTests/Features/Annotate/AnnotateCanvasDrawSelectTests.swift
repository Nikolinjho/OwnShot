//
//  AnnotateCanvasDrawSelectTests.swift
//  SnapzyTests
//
//  Паритет холста с CleanShot X 5.0.1 (spec-063, canvas-draw-select): шаги
//  Increase/Decrease Tool Size по пресетам, точка Draw по клику, Shift-прямая
//  и сглаживание Draw, захват незалитых фигур за контур, отсутствие
//  автовыделения после рисования.
//

import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Snapzy

final class AnnotateCanvasDrawSelectTests: XCTestCase {
  // AnnotateState живёт до конца процесса: деинициализация MainActor-объекта
  // при очистке XCTest может падать (как в AnnotateRenderSnapshotTests).
  @MainActor private static var retainedStates: [AnnotateState] = []

  @MainActor
  private func makeState() throws -> AnnotateState {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 200, height: 120))
    state.sourceImage = NSImage(cgImage: image, size: NSSize(width: 200, height: 120))
    Self.retainedStates.append(state)
    return state
  }

  // MARK: - Increase/Decrease Tool Size (ANN-351/352)

  func testToolSizeStepsWalkTheThicknessMenuPresets() {
    var width: CGFloat = 1
    var upward: [CGFloat] = []
    for _ in 0 ..< 6 {
      width = AnnotateState.steppedStrokeWidth(from: width, increasing: true)
      upward.append(width)
    }
    XCTAssertEqual(upward, [3, 7, 10, 15, 25, 25], "Вверх по пресетам с потолком 25")

    var downward: [CGFloat] = []
    for _ in 0 ..< 6 {
      width = AnnotateState.steppedStrokeWidth(from: width, increasing: false)
      downward.append(width)
    }
    XCTAssertEqual(downward, [15, 10, 7, 3, 1, 1], "Вниз по пресетам до 1")
  }

  func testToolSizeStepFromBetweenPresetsGoesToTheNextPresetInThatDirection() {
    XCTAssertEqual(AnnotateState.steppedStrokeWidth(from: 5, increasing: true), 7)
    XCTAssertEqual(AnnotateState.steppedStrokeWidth(from: 5, increasing: false), 3)
    XCTAssertEqual(AnnotateState.steppedStrokeWidth(from: 12, increasing: true), 15)
    XCTAssertEqual(AnnotateState.steppedStrokeWidth(from: 12, increasing: false), 10)
    XCTAssertEqual(AnnotateState.steppedStrokeWidth(from: 20, increasing: true), 25)
  }

  @MainActor
  func testToolSizeShortcutWithoutSelectionLeavesToolThicknessAlone() throws {
    let state = try makeState()
    state.selectedTool = .rectangle
    let before = state.annotationCreationProperties(for: .rectangle).strokeWidth

    state.adjustQuickStrokeWidth(by: 1)
    state.adjustQuickStrokeWidth(by: -1)

    XCTAssertEqual(state.annotationCreationProperties(for: .rectangle).strokeWidth, before)
  }

  @MainActor
  func testToolSizeShortcutStepsTheSelectedObjectByPresets() throws {
    let state = try makeState()
    let item = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 20, y: 20, width: 60, height: 40),
      properties: AnnotationProperties(strokeWidth: 3)
    )
    state.annotations = [item]
    state.selectedTool = .selection
    state.setSelectedAnnotationIds([item.id])

    state.adjustQuickStrokeWidth(by: 1)
    XCTAssertEqual(state.annotations.first?.properties.strokeWidth, 7)
    state.adjustQuickStrokeWidth(by: 1)
    XCTAssertEqual(state.annotations.first?.properties.strokeWidth, 10)
    state.adjustQuickStrokeWidth(by: -1)
    state.adjustQuickStrokeWidth(by: -1)
    XCTAssertEqual(state.annotations.first?.properties.strokeWidth, 3)
    state.adjustQuickStrokeWidth(by: -1)
    state.adjustQuickStrokeWidth(by: -1)
    XCTAssertEqual(state.annotations.first?.properties.strokeWidth, 1, "Ниже 1 не опускается")
  }

  func testThicknessRangeReachesTheLargestMenuPreset() {
    // Draw эталона на 25 рисует штрих 25 pt (ANN-127).
    XCTAssertEqual(AnnotationProperties.controlValueRange.upperBound, 25)
    XCTAssertEqual(AnnotationProperties.strokeWidthPresets.last, 25)
    XCTAssertEqual(AnnotationProperties.clampedControlValue(25), 25)
  }

  // MARK: - Draw: точка по клику (ANN-126)

  func testSinglePointDrawStrokeRendersARoundDotOfStrokeWidth() throws {
    let size = 40
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let center = CGPoint(x: 20, y: 20)
    let item = AnnotationItem(
      type: .path([center]),
      bounds: CGRect(x: 19.5, y: 19.5, width: 1, height: 1),
      properties: AnnotationProperties(strokeColor: .black, strokeWidth: 10)
    )
    AnnotationRenderer(context: context, drawsObjectShadow: false).draw(item)
    let image = try XCTUnwrap(context.makeImage())

    func alpha(_ x: Int, _ y: Int) throws -> UInt8 {
      let data = try XCTUnwrap(image.dataProvider?.data as Data?)
      // Строки CGImage идут сверху; точка симметрична, поэтому y не переворачиваем.
      return data[y * image.bytesPerRow + x * 4 + 3]
    }

    XCTAssertEqual(try alpha(20, 20), 255, "Центр точки закрашен")
    XCTAssertEqual(try alpha(16, 20), 255, "Радиус 5 pt: точка в 4 pt от центра закрашена")
    XCTAssertEqual(try alpha(20, 16), 255)
    XCTAssertEqual(try alpha(27, 20), 0, "За диаметром 10 pt пусто")
    XCTAssertEqual(try alpha(24, 24), 0, "Точка круглая: угол описанного квадрата пуст")
  }

  // MARK: - Draw: Shift и сглаживание (ANN-128, ANN-779)

  func testShiftDrawSnapsSmallAnglesToAHorizontalLine() {
    let start = CGPoint(x: 10, y: 10)
    // ~29° у эталона ещё горизонталь.
    let path = AnnotationFactory.straightDrawPath(from: start, to: CGPoint(x: 110, y: 65))
    XCTAssertEqual(path.count, 2)
    XCTAssertEqual(path.last?.y ?? 0, 10, accuracy: 0.0001)
    XCTAssertEqual(path.last?.x ?? 0, 110, accuracy: 0.0001)

    let leftward = AnnotationFactory.straightDrawPath(from: start, to: CGPoint(x: -90, y: 0))
    XCTAssertEqual(leftward.last?.y ?? 0, 10, accuracy: 0.0001)
    XCTAssertEqual(leftward.last?.x ?? 0, -90, accuracy: 0.0001)
  }

  func testShiftDrawSnapsSteeperAnglesToFortyFiveOrNinetyDegrees() {
    let start = CGPoint(x: 0, y: 0)
    let diagonal = AnnotationFactory.straightDrawPath(from: start, to: CGPoint(x: 100, y: 90))
    let end = diagonal.last ?? .zero
    XCTAssertEqual(end.x, end.y, accuracy: 0.0001, "Ближайшее направление – 45°")

    let vertical = AnnotationFactory.straightDrawPath(from: start, to: CGPoint(x: 10, y: -100))
    XCTAssertEqual(vertical.last?.x ?? 1, 0, accuracy: 0.0001)
    XCTAssertEqual(vertical.last?.y ?? 0, -100, accuracy: 0.0001)
  }

  func testSmoothDrawingTurnsSharpCornersIntoCurves() {
    // Ломаная из трёх отрезков с прямыми углами, сэмплированная как ввод мыши.
    var raw: [CGPoint] = []
    for x in stride(from: 0, through: 100, by: 2) { raw.append(CGPoint(x: CGFloat(x), y: 0)) }
    for y in stride(from: 2, through: 100, by: 2) { raw.append(CGPoint(x: 100, y: CGFloat(y))) }
    for x in stride(from: 102, through: 200, by: 2) { raw.append(CGPoint(x: CGFloat(x), y: 100)) }

    let smoothed = AnnotationFactory.smoothedDrawPath(raw)

    XCTAssertEqual(smoothed.first, raw.first)
    XCTAssertEqual(smoothed.last, raw.last)
    // Острый угол (100, 0) срезан дугой: ближайшая точка кривой далеко от вершины.
    let nearestToCorner = smoothed.map { hypot($0.x - 100, $0.y) }.min() ?? 0
    XCTAssertGreaterThan(nearestToCorner, 10)
    // Поворот между соседними отрезками сглаженного пути везде плавный.
    var maxTurn: CGFloat = 0
    for index in 1 ..< (smoothed.count - 1) {
      let a = smoothed[index - 1], b = smoothed[index], c = smoothed[index + 1]
      let first = atan2(b.y - a.y, b.x - a.x)
      let second = atan2(c.y - b.y, c.x - b.x)
      var turn = abs(second - first)
      if turn > .pi { turn = 2 * .pi - turn }
      maxTurn = max(maxTurn, turn)
    }
    XCTAssertLessThan(maxTurn, 30 * .pi / 180, "Нет изломов круче 30° между соседними отрезками")
  }

  // MARK: - Move по незалитым фигурам (ANN-014)

  func testMoveGrabsUnfilledShapesOnlyByTheirOutline() {
    let bounds = CGRect(x: 100, y: 100, width: 200, height: 100)
    let properties = AnnotationProperties(strokeWidth: 3)
    let rectangle = AnnotationItem(type: .rectangle, bounds: bounds, properties: properties)
    let ellipse = AnnotationItem(type: .oval, bounds: bounds, properties: properties)
    let filled = AnnotationItem(type: .filledRectangle, bounds: bounds, properties: properties)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)

    XCTAssertFalse(rectangle.moveHitContains(center), "Пустая середина Rectangle не берётся")
    XCTAssertFalse(ellipse.moveHitContains(center), "Пустая середина Ellipse не берётся")
    XCTAssertTrue(filled.moveHitContains(center), "Filled Rectangle берётся за всю площадь")
    XCTAssertTrue(rectangle.moveHitContains(CGPoint(x: bounds.minX, y: bounds.midY)))
    XCTAssertTrue(ellipse.moveHitContains(CGPoint(x: bounds.minX, y: bounds.midY)))
  }

  // MARK: - Автовыделение после рисования (ANN-018/023/028/033/038/048/063)

  @MainActor
  func testDrawingToolsDoNotSelectTheCreatedObject() {
    for tool in [AnnotationToolType.rectangle, .filledRectangle, .oval, .line, .arrow, .blur, .pencil, .highlighter] {
      XCTAssertFalse(DrawingCanvasNSView.selectsCreatedAnnotation(tool: tool), "\(tool) не выделяется после рисования")
    }
    XCTAssertTrue(DrawingCanvasNSView.selectsCreatedAnnotation(tool: .counter), "Counter сохраняет выделение (выносная стрелка)")
  }
}
