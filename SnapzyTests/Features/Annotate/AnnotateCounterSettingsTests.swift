//
//  AnnotateCounterSettingsTests.swift
//  SnapzyTests
//
//  Меню Counter: Starting number, форматы, Size и сохранение формата в .ownshot
//  (ANN-119, ANN-120, ANN-121, ANN-123).
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateCounterSettingsTests: XCTestCase {
  private static var retainedAnnotateStates: [AnnotateState] = []
  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Counter_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    tempDirectory = nil
    super.tearDown()
  }

  private func makeState() -> AnnotateState {
    let defaults = UserDefaults(suiteName: "counter-settings.\(UUID().uuidString)")!
    let state = AnnotateState(defaults: defaults)
    Self.retainedAnnotateStates.append(state)
    return state
  }

  /// Создание счётчика так же, как его создаёт холст: снимок undo, затем добавление.
  @discardableResult
  private func placeCounter(_ state: AnnotateState, at point: CGPoint = CGPoint(x: 50, y: 50)) throws -> AnnotationItem {
    let item = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .counter, from: point, to: point, path: [], state: state
    ))
    state.saveState()
    state.annotations.append(item)
    return item
  }

  private func value(_ item: AnnotationItem) -> Int? {
    if case .counter(let value) = item.type { return value }
    return nil
  }

  // MARK: - Starting number (ANN-119)

  func testStartingNumber_defaultsToOneAndClampsToRange() {
    let state = makeState()
    XCTAssertEqual(state.counterStartingNumber, 1)
    XCTAssertEqual(state.nextCounterValue(), 1)

    state.setCounterStartingNumber(-5)
    XCTAssertEqual(state.counterStartingNumber, 0)
    state.setCounterStartingNumber(12_000)
    XCTAssertEqual(state.counterStartingNumber, 9999)
  }

  func testStartingNumber_setsNextCounterAndSequenceContinues() throws {
    let state = makeState()
    try placeCounter(state)
    try placeCounter(state)

    state.setCounterStartingNumber(10)
    let first = try placeCounter(state)
    let second = try placeCounter(state)

    XCTAssertEqual(value(first), 10)
    XCTAssertEqual(value(second), 11)
    XCTAssertEqual(state.annotations.compactMap(value), [1, 2, 10, 11])
  }

  func testStartingNumber_belowExistingCountersRestartsSequence() throws {
    let state = makeState()
    state.setCounterStartingNumber(5)
    try placeCounter(state)
    try placeCounter(state)

    state.setCounterStartingNumber(1)
    XCTAssertEqual(value(try placeCounter(state)), 1)
    XCTAssertEqual(value(try placeCounter(state)), 2)
  }

  func testStartingNumber_zeroIsAllowed() throws {
    let state = makeState()
    state.setCounterStartingNumber(0)
    XCTAssertEqual(value(try placeCounter(state)), 0)
    XCTAssertEqual(value(try placeCounter(state)), 1)
  }

  // MARK: - Последовательность после удаления и undo (ANN-121)

  func testSequence_deleteLastAndUndoReturnNumberBack() throws {
    let state = makeState()
    state.setCounterStartingNumber(3)
    try placeCounter(state)
    let middle = try placeCounter(state)
    let last = try placeCounter(state)
    XCTAssertEqual(state.nextCounterValue(), 6)

    // Удаление из середины перенумеровывает оставшиеся: 3, 4, следующий 5 (как у эталона).
    state.setSelectedAnnotationIds([middle.id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(state.annotations.compactMap(value), [3, 4])
    XCTAssertEqual(state.nextCounterValue(), 5)

    // Удаление последнего освобождает его номер.
    state.setSelectedAnnotationIds([last.id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(state.nextCounterValue(), 4)

    // Undo удалений возвращает счётчики и прежнюю нумерацию.
    state.undo()
    state.undo()
    XCTAssertEqual(state.nextCounterValue(), 6)

    // Undo создания всех трёх возвращает Starting number.
    state.undo()
    state.undo()
    state.undo()
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertEqual(state.nextCounterValue(), 3)
  }

  // MARK: - Форматы (ANN-120)

  func testFormat_menuTitlesMatchCleanShot() {
    XCTAssertEqual(CounterNumberFormat.allCases.map(\.menuTitle), [
      "1, 2, 3, 4 ...", "A, B, C, D ...", "I, II, III, IV ...", "a, b, c, d ...",
    ])
  }

  func testFormat_labels() {
    XCTAssertEqual((1...4).map { CounterNumberFormat.decimal.label(for: $0) }, ["1", "2", "3", "4"])
    XCTAssertEqual((1...4).map { CounterNumberFormat.upperAlpha.label(for: $0) }, ["A", "B", "C", "D"])
    XCTAssertEqual((1...4).map { CounterNumberFormat.upperRoman.label(for: $0) }, ["I", "II", "III", "IV"])
    XCTAssertEqual((1...4).map { CounterNumberFormat.lowerAlpha.label(for: $0) }, ["a", "b", "c", "d"])
    XCTAssertEqual(CounterNumberFormat.upperAlpha.label(for: 26), "Z")
    XCTAssertEqual(CounterNumberFormat.upperAlpha.label(for: 27), "AA")
    XCTAssertEqual(CounterNumberFormat.lowerAlpha.label(for: 703), "aaa")
    XCTAssertEqual(CounterNumberFormat.upperRoman.label(for: 1994), "MCMXCIV")
    // Значения, которые формат не выражает, остаются арабскими.
    XCTAssertEqual(CounterNumberFormat.upperAlpha.label(for: 0), "0")
    XCTAssertEqual(CounterNumberFormat.upperRoman.label(for: 0), "0")
    XCTAssertEqual(CounterNumberFormat.upperRoman.label(for: 5000), "5000")
  }

  func testFormat_toolDefaultAppliesToNewCounters() throws {
    let state = makeState()
    state.selectedTool = .counter
    state.setActiveCounterFormat(.upperRoman)

    XCTAssertEqual(state.activeCounterFormat, .upperRoman)
    XCTAssertEqual(try placeCounter(state).properties.counterFormat, .upperRoman)
  }

  func testСменаФорматаБезВыделенияОбновляетВсеПоставленныеСчётчикиИНовые() throws {
    let state = makeState()
    state.selectedTool = .counter
    try placeCounter(state)
    try placeCounter(state, at: CGPoint(x: 120, y: 50))
    let originalIDs = state.annotations.map(\.id)
    let originalBounds = state.annotations.map(\.bounds)
    let cases: [(CounterNumberFormat, [String])] = [
      (.upperAlpha, ["A", "B"]),
      (.upperRoman, ["I", "II"]),
      (.lowerAlpha, ["a", "b"]),
      (.decimal, ["1", "2"]),
    ]
    for (format, labels) in cases {
      state.setActiveCounterFormat(format)
      XCTAssertEqual(state.annotations.map(\.properties.counterFormat), [format, format])
      XCTAssertEqual(state.annotations.compactMap { item in
        value(item).map { item.properties.counterFormat.label(for: $0) }
      }, labels)
      XCTAssertEqual(state.annotations.map(\.id), originalIDs)
      XCTAssertEqual(state.annotations.map(\.bounds), originalBounds)
      XCTAssertEqual(state.annotations.compactMap(value), [1, 2])
    }
    state.setActiveCounterFormat(.upperAlpha)
    let next = try placeCounter(state)
    XCTAssertEqual(next.properties.counterFormat.label(for: try XCTUnwrap(value(next))), "C")
  }

  func testСменаФорматаВсехСчётчиковОтменяетсяОднимШагомИПовторВосстанавливается() throws {
    let state = makeState()
    state.selectedTool = .counter
    try placeCounter(state)
    try placeCounter(state)
    state.setCounterStartingNumber(7)
    try placeCounter(state)

    state.setActiveCounterFormat(.upperRoman)
    state.setActiveCounterFormat(.upperRoman)
    state.undo()
    XCTAssertEqual(state.annotations.map(\.properties.counterFormat), [.decimal, .decimal, .decimal])
    XCTAssertEqual(state.annotations.compactMap(value), [1, 2, 7])
    state.redo()
    XCTAssertEqual(state.annotations.map(\.properties.counterFormat), [.upperRoman, .upperRoman, .upperRoman])
    XCTAssertEqual(state.annotations.compactMap(value), [1, 2, 7])
  }

  func testСменаФорматаПриВыделенномПоследнемСчётчикеОбновляетИПредыдущие() throws {
    let state = makeState()
    state.selectedTool = .counter
    try placeCounter(state)
    let last = try placeCounter(state)
    let rectangle = AnnotationItem(
      type: .rectangle, bounds: CGRect(x: 10, y: 10, width: 40, height: 30),
      properties: AnnotationProperties()
    )
    state.annotations.append(rectangle)
    state.setSelectedAnnotationIds([last.id])

    state.setActiveCounterFormat(.lowerAlpha)

    XCTAssertEqual(state.annotations.prefix(2).map(\.properties.counterFormat), [.lowerAlpha, .lowerAlpha])
    XCTAssertEqual(state.annotations.last, rectangle)
    state.deselectAnnotation()
    XCTAssertEqual(try placeCounter(state).properties.counterFormat, .lowerAlpha)
  }

  func testFormat_selectedCountersChangeWithSingleUndoStep() throws {
    let state = makeState()
    let first = try placeCounter(state)
    let second = try placeCounter(state, at: CGPoint(x: 120, y: 50))
    state.setSelectedAnnotationIds([first.id, second.id])

    state.setActiveCounterFormat(.lowerAlpha)
    XCTAssertEqual(state.annotations.map(\.properties.counterFormat), [.lowerAlpha, .lowerAlpha])
    // Формат нумерации общий для поставленных счётчиков и новых.
    state.deselectAnnotation()
    XCTAssertEqual(state.activeCounterFormat, .lowerAlpha)

    state.undo()
    XCTAssertEqual(state.annotations.map(\.properties.counterFormat), [.decimal, .decimal])
  }

  // MARK: - Size (ANN-123)

  func testSize_pointsMapToCounterDiameter() {
    XCTAssertEqual(AnnotateCounterSettings.sizePoints, [11, 14, 20, 24, 31, 45])
    for points in AnnotateCounterSettings.sizePoints {
      let control = AnnotateCounterSettings.controlValue(forSize: points)
      XCTAssertEqual(AnnotationProperties.counterDiameter(for: control), CGFloat(points) * 2, accuracy: 0.001)
      XCTAssertEqual(AnnotateCounterSettings.size(forControlValue: control), points)
    }
    // Размер по умолчанию (24 px) в список не попадает – ни один пункт не отмечен.
    XCTAssertNil(AnnotateCounterSettings.size(forControlValue: 3))
  }

  func testSize_appliesToToolDefaultsAndSelectedCounter() throws {
    let state = makeState()
    state.selectedTool = .counter
    state.setCounterSize(31)
    XCTAssertEqual(state.activeCounterSize, 31)
    let counter = try placeCounter(state)
    XCTAssertEqual(counter.bounds.width, 62, accuracy: 0.001)

    state.setSelectedAnnotationIds([counter.id])
    state.setCounterSize(14)
    XCTAssertEqual(state.activeCounterSize, 14)
    XCTAssertEqual(try XCTUnwrap(state.annotations.first).bounds.width, 28, accuracy: 0.001)
  }

  // MARK: - Round-trip .ownshot

  func testProject_roundTripsCounterFormat() throws {
    let url = tempDirectory.appendingPathComponent("counter.ownshot")
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: 40, height: 20))
    let image = NSImage(cgImage: cgImage, size: CGSize(width: 40, height: 20))
    let imageData = try XCTUnwrap(AnnotateExporter.imageData(from: image, for: "png"))
    let formats = CounterNumberFormat.allCases
    let annotations = formats.enumerated().map { index, format in
      AnnotationItem(
        type: .counter(index + 7),
        bounds: CGRect(x: CGFloat(index) * 10, y: 0, width: 28, height: 28),
        properties: AnnotationProperties(strokeWidth: AnnotateCounterSettings.controlValue(forSize: 14), counterFormat: format)
      )
    }
    let sessionData = AnnotationSessionData(
      originalImageData: imageData,
      annotations: annotations,
      canvasEffects: AnnotationCanvasEffects(),
      selectedCanvasPresetId: nil,
      isSelectedCanvasPresetDirty: false,
      cropRect: nil,
      isCutoutApplied: false,
      cutoutImageData: nil,
      embeddedImageAssetsData: [:],
      sourceLogicalSize: CGSize(width: 40, height: 20)
    )

    try OwnShotProjectStore.write(sessionData, preview: image, to: url)
    let loaded = try OwnShotProjectStore.read(from: url)

    XCTAssertEqual(loaded.annotations.map(\.properties.counterFormat), formats)
    XCTAssertEqual(loaded.annotations.compactMap(value), [7, 8, 9, 10])
    XCTAssertEqual(
      loaded.annotations.compactMap { AnnotateCounterSettings.size(forControlValue: $0.properties.strokeWidth) },
      [14, 14, 14, 14]
    )
  }

  func testPersistedProperties_missingCounterFormatFallsBackToDecimal() throws {
    let persisted = PersistedAnnotationProperties(properties: AnnotationProperties(counterFormat: .upperAlpha))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(persisted)) as? [String: Any]
    )
    XCTAssertEqual(object["counterFormat"] as? String, "upperAlpha")

    object.removeValue(forKey: "counterFormat")
    let legacy = try JSONDecoder().decode(
      PersistedAnnotationProperties.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    XCTAssertNil(legacy.counterFormat)
    XCTAssertEqual(legacy.annotationProperties.counterFormat, .decimal)
  }
}
