//
//  AnnotateStateZoomCropCounterPasteTests.swift
//  SnapzyTests
//
//  Паритет состояния редактора со CleanShot X 5.0.1 (spec-063): ступени масштаба,
//  стартовое окно огромного снимка, подпись и минимум Crop, выход из Crop после Resize,
//  перенумерация Counter, Copy Object и вставка, затемнение Spotlight
//  (ANN-299, ANN-302, ANN-617, ANN-232, ANN-258, ANN-121, ANN-349, ANN-346, ANN-347, ANN-053).
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateStateZoomCropCounterPasteTests: XCTestCase {
  // AnnotateState живёт до конца процесса: деинициализация в XCTest падает.
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeState(width: Int = 800, height: Int = 450, pointScale: CGFloat = 1) throws -> AnnotateState {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedAnnotateStates.append(state)
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    state.loadImage(NSImage(
      cgImage: cgImage,
      size: NSSize(width: CGFloat(width) / pointScale, height: CGFloat(height) / pointScale)
    ))
    return state
  }

  private func makeImage(width: Int, height: Int) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height, red: 10))
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }

  /// Метрики окна 990×500 со снимком 800×450: Fit = 56,25%, как в живом замере.
  private func applyMetrics(_ state: AnnotateState, fitScale: CGFloat = 0.5625) {
    state.updateViewportMetrics(
      containerSize: CGSize(width: 990, height: 420),
      baseCanvasSize: CGSize(width: 800 * fitScale, height: 450 * fitScale),
      fitScale: fitScale
    )
  }

  /// Счётчик так же, как его ставит холст: точка undo, затем добавление.
  @discardableResult
  private func placeCounter(_ state: AnnotateState, at point: CGPoint = CGPoint(x: 50, y: 50)) throws -> AnnotationItem {
    let item = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .counter, from: point, to: point, path: [], state: state
    ))
    state.saveState()
    state.annotations.append(item)
    return item
  }

  private func counterValues(_ state: AnnotateState) -> [Int] {
    state.annotations.compactMap { annotation in
      if case .counter(let value) = annotation.type { return value }
      return nil
    }
  }

  // MARK: - ANN-299 масштаб

  func testZoomIn_удваиваетПоказанныйПроцентДо3200() throws {
    let state = try makeState()
    applyMetrics(state)
    state.zoomLevel = state.zoomLevel(forDisplayedPercent: 100)

    var steps: [Int] = []
    for _ in 0 ..< 6 {
      state.zoomIn()
      steps.append(state.currentDisplayedZoomPercent)
    }
    XCTAssertEqual(steps, [200, 400, 800, 1600, 3200, 3200])
  }

  func testZoomOut_делитПополамДо25ЗатемДо10() throws {
    let state = try makeState()
    applyMetrics(state)
    state.zoomLevel = state.zoomLevel(forDisplayedPercent: 3200)

    var steps: [Int] = []
    for _ in 0 ..< 10 {
      state.zoomOut()
      steps.append(state.currentDisplayedZoomPercent)
    }
    XCTAssertEqual(steps, [1600, 800, 400, 200, 100, 50, 25, 10, 10, 10])
  }

  func testПункт400ДаётРовно400() throws {
    let state = try makeState()
    applyMetrics(state)
    state.zoomLevel = state.zoomLevel(forDisplayedPercent: 400)
    XCTAssertEqual(state.currentDisplayedZoomPercent, 400)
    XCTAssertEqual(state.effectiveMaximumZoomLevel * state.fitScale, 32, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveMinimumZoomLevel * state.fitScale, 0.1, accuracy: 0.0001)
  }

  func testВписанныйОгромныйСнимокНиже10ПроцентовОстаётсяДоступен() throws {
    let state = try makeState()
    // 10000×10000 в окне 990×972 вписывается примерно в 9%.
    applyMetrics(state, fitScale: 0.088)
    state.zoomLevel = 1
    XCTAssertEqual(state.clampedZoom(1), 1, accuracy: 0.0001)
    XCTAssertEqual(state.currentDisplayedZoomPercent, 9)

    state.zoomOut()
    XCTAssertEqual(state.currentDisplayedZoomPercent, 9, "⌘− не увеличивает вписанный снимок")
    state.zoomIn()
    XCTAssertEqual(state.currentDisplayedZoomPercent, 10)
    state.zoomIn()
    XCTAssertEqual(state.currentDisplayedZoomPercent, 25)
  }

  func testСтупениМасштаба() {
    XCTAssertEqual(AnnotateState.nextZoomStepPercent(after: 100), 200)
    XCTAssertEqual(AnnotateState.nextZoomStepPercent(after: 74), 100)
    XCTAssertEqual(AnnotateState.nextZoomStepPercent(after: 3200), 3200)
    XCTAssertEqual(AnnotateState.previousZoomStepPercent(before: 25), 10)
    XCTAssertEqual(AnnotateState.previousZoomStepPercent(before: 74), 50)
    XCTAssertEqual(AnnotateState.previousZoomStepPercent(before: 10), 10)
  }

  // MARK: - ANN-302 стартовое окно огромного снимка

  func testОгромныйСнимокРаститОкноПоВысотеИОткрываетсяВписанным() {
    let visible = CGSize(width: 1728, height: 1080)
    XCTAssertEqual(
      AnnotateWindowController.initialWindowSize(visibleSize: visible, imageSize: CGSize(width: 10_000, height: 10_000)),
      CGSize(width: 990, height: 972)
    )
    XCTAssertTrue(AnnotateWindowController.opensOversizedImageFitted(
      imageSize: CGSize(width: 10_000, height: 10_000), visibleSize: visible
    ))
    // Маленькие снимки (1×1, 16×16, 800×450) – прежнее окно 990×500 и 100%.
    for size in [CGSize(width: 1, height: 1), CGSize(width: 16, height: 16), CGSize(width: 800, height: 450)] {
      XCTAssertEqual(AnnotateWindowController.initialWindowSize(visibleSize: visible, imageSize: size),
        CGSize(width: 990, height: 500))
      XCTAssertFalse(AnnotateWindowController.opensOversizedImageFitted(imageSize: size, visibleSize: visible))
    }
  }

  // MARK: - ANN-617 подпись Image size

  func testCropPixelSizeОкругляетДоБлижайшего() throws {
    let state = try makeState(width: 600, height: 400)
    // 7:3 на 600×400 → 600×257,14 → 257.
    state.cropRect = CGRect(x: 0, y: 0, width: 600, height: CGFloat(600) * 3 / 7)
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 600, height: 257))
    // 400 × 5/7 = 285,71 → 286.
    state.cropRect = CGRect(x: 0, y: 0, width: 400, height: CGFloat(400) * 5 / 7)
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 400, height: 286))
  }

  // MARK: - ANN-232 минимум рамки Crop

  func testМинимумРамкиCrop12Пикселей() throws {
    let state = try makeState()
    state.beginCropInteraction()
    state.updateCropRect(CGRect(x: 100, y: 100, width: 3, height: 3))
    XCTAssertEqual(state.cropRect?.size, CGSize(width: 12, height: 12))
    state.updateCropRect(CGRect(x: 0, y: 0, width: 800, height: 1))
    XCTAssertEqual(state.cropRect?.size, CGSize(width: 800, height: 12))
    XCTAssertEqual(CropEdgeSnapping.minimumCropPixelSize, 12)
  }

  func testМинимумРамкиCropВПикселяхRetinaСнимка() throws {
    // 200×160 px при 100×80 pt: 12 px – это 6 pt.
    let state = try makeState(width: 200, height: 160, pointScale: 2)
    XCTAssertEqual(state.minimumCropSize, 6, accuracy: 0.0001)
  }

  // MARK: - ANN-258 Resize выходит из Crop

  func testResizeВыходитИзCropВОбычныйРедактор() throws {
    let state = try makeState()
    state.beginCropInteraction()
    XCTAssertTrue(state.isCropActive)
    state.resizeImage(pixelWidth: 400, pixelHeight: 225, flattenAnnotations: false)
    XCTAssertFalse(state.isCropActive)
    XCTAssertNotEqual(state.selectedTool, .crop)
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 400, height: 225))

    state.undo()
    XCTAssertEqual(state.sourceImage?.size, NSSize(width: 800, height: 450))
  }

  // MARK: - ANN-121, ANN-349 нумерация Counter

  func testПервыйСчётчикСвежегоДокумента1() throws {
    let state = try makeState()
    XCTAssertEqual(state.counterStartingNumber, 1)
    XCTAssertEqual(counterValues(state), [])
    let first = try placeCounter(state)
    guard case .counter(1) = first.type else { return XCTFail("Первый счётчик должен быть 1") }
  }

  func testУдалениеПеренумеровываетИUndoRedoКакУЭталона() throws {
    let state = try makeState()
    try placeCounter(state, at: CGPoint(x: 50, y: 50))
    let middle = try placeCounter(state, at: CGPoint(x: 150, y: 50))
    try placeCounter(state, at: CGPoint(x: 250, y: 50))
    XCTAssertEqual(counterValues(state), [1, 2, 3])

    state.setSelectedAnnotationIds([middle.id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(counterValues(state), [1, 2])

    try placeCounter(state, at: CGPoint(x: 350, y: 50))
    XCTAssertEqual(counterValues(state), [1, 2, 3])

    // Undo убирает новый, второй undo возвращает удалённый и нумерацию 1, 2, 3.
    state.undo()
    XCTAssertEqual(counterValues(state), [1, 2])
    state.undo()
    XCTAssertEqual(counterValues(state), [1, 2, 3])
    XCTAssertTrue(state.annotations.contains { $0.id == middle.id })

    state.redo()
    XCTAssertEqual(counterValues(state), [1, 2])
    state.redo()
    XCTAssertEqual(counterValues(state), [1, 2, 3])
  }

  func testУдалениеПервогоСчётчикаНачинаетСStartingNumber() throws {
    let state = try makeState()
    state.setCounterStartingNumber(5)
    let first = try placeCounter(state)
    try placeCounter(state)
    try placeCounter(state)
    XCTAssertEqual(counterValues(state), [5, 6, 7])

    state.setSelectedAnnotationIds([first.id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(counterValues(state), [5, 6])
    XCTAssertEqual(state.nextCounterValue(), 7)
  }

  func testПеренумерацияИдётПоПорядкуСозданияАНеСлоёв() throws {
    let state = try makeState()
    let first = try placeCounter(state)
    let second = try placeCounter(state)
    let third = try placeCounter(state)
    // Первый счётчик поднят наверх: в массиве он последний.
    state.annotations = [second, third, first]

    state.setSelectedAnnotationIds([second.id])
    state.deleteSelectedAnnotation()
    let byId = Dictionary(uniqueKeysWithValues: state.annotations.map { ($0.id, $0.type) })
    XCTAssertEqual(byId[first.id], .counter(1))
    XCTAssertEqual(byId[third.id], .counter(2))
  }

  func testСчётчикиДоСменыStartingNumberНеПеренумеровываются() throws {
    let state = try makeState()
    try placeCounter(state)
    try placeCounter(state)
    state.setCounterStartingNumber(10)
    let ten = try placeCounter(state)
    try placeCounter(state)
    XCTAssertEqual(counterValues(state), [1, 2, 10, 11])

    state.setSelectedAnnotationIds([ten.id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(counterValues(state), [1, 2, 10])
  }

  func testОткрытыйПроектСНомерами7_8_9ПеренумеровываетсяОт7() throws {
    let state = try makeState()
    let items = (7 ... 9).map { value in
      AnnotationItem(type: .counter(value), bounds: CGRect(x: value * 30, y: 10, width: 24, height: 24),
        properties: AnnotationProperties())
    }
    state.annotations = items
    state.setSelectedAnnotationIds([items[1].id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(counterValues(state), [7, 8])
  }

  func testУдалениеНеСчётчикаНомераНеТрогает() throws {
    let state = try makeState()
    state.annotations = [
      AnnotationItem(type: .counter(1), bounds: CGRect(x: 10, y: 10, width: 24, height: 24), properties: AnnotationProperties()),
      AnnotationItem(type: .counter(5), bounds: CGRect(x: 60, y: 10, width: 24, height: 24), properties: AnnotationProperties()),
    ]
    let rect = AnnotationItem(type: .rectangle, bounds: CGRect(x: 100, y: 100, width: 40, height: 40),
      properties: AnnotationProperties())
    state.annotations.append(rect)
    state.setSelectedAnnotationIds([rect.id])
    state.deleteSelectedAnnotation()
    XCTAssertEqual(counterValues(state), [1, 5])
  }

  // MARK: - ANN-346, ANN-347 Copy Object и вставка

  func testCopyObjectКладётСвойТипВБуферБезКартинки() throws {
    let state = try makeState()
    let counter = try placeCounter(state)
    state.setSelectedAnnotationIds([counter.id])
    XCTAssertTrue(state.copySelectedAnnotations())

    let types = state.annotationPasteboard.types ?? []
    XCTAssertEqual(types, [AnnotateState.annotationPasteboardType])
    XCTAssertEqual(AnnotateState.annotationPasteboardType.rawValue, "com.ownshot.annotate")
    XCTAssertNotNil(state.annotationPasteboard.data(forType: AnnotateState.annotationPasteboardType))
  }

  func testВставкаСчётчикаВЦентрХолстаСоСледующимНомером() throws {
    let state = try makeState()
    try placeCounter(state, at: CGPoint(x: 50, y: 50))
    try placeCounter(state, at: CGPoint(x: 150, y: 50))
    let third = try placeCounter(state, at: CGPoint(x: 250, y: 50))
    state.setSelectedAnnotationIds([third.id])
    XCTAssertTrue(state.copySelectedAnnotations())

    XCTAssertTrue(state.pasteAnnotationsFromClipboard())
    let pasted = try XCTUnwrap(state.annotations.last)
    XCTAssertNotEqual(pasted.id, third.id)
    XCTAssertEqual(pasted.type, .counter(4))
    XCTAssertEqual(state.selectedAnnotationIds, [pasted.id])
    let canvas = state.activeAnnotationBounds
    XCTAssertEqual(pasted.selectionBounds.midX, canvas.midX, accuracy: 0.5)
    XCTAssertEqual(pasted.selectionBounds.midY, canvas.midY, accuracy: 0.5)

    // Одна точка undo на вставку.
    state.undo()
    XCTAssertEqual(counterValues(state), [1, 2, 3])
  }

  func testВставкаМеждуОкнамиЧерезСистемныйБуфер() throws {
    let source = try makeState()
    let rect = AnnotationItem(type: .rectangle, bounds: CGRect(x: 10, y: 10, width: 40, height: 30),
      properties: AnnotationProperties())
    source.annotations = [rect]
    source.setSelectedAnnotationIds([rect.id])
    XCTAssertTrue(source.copySelectedAnnotations())

    let target = try makeState(width: 400, height: 300)
    target.annotationPasteboard = source.annotationPasteboard
    XCTAssertTrue(target.pasteAnnotationsFromClipboard())
    let pasted = try XCTUnwrap(target.annotations.last)
    XCTAssertEqual(pasted.type, .rectangle)
    XCTAssertEqual(pasted.bounds.size, CGSize(width: 40, height: 30))
    XCTAssertNotEqual(pasted.id, rect.id)
  }

  func testКартинкаВБуфереПослеCopyObjectНеПерехватываетсяВнутреннимБуфером() throws {
    let state = try makeState()
    let rect = AnnotationItem(type: .rectangle, bounds: CGRect(x: 10, y: 10, width: 40, height: 30),
      properties: AnnotationProperties())
    state.annotations = [rect]
    state.setSelectedAnnotationIds([rect.id])
    XCTAssertTrue(state.copySelectedAnnotations())

    // Пользователь скопировал PNG в другом приложении: первый ⌘V должен вставить картинку.
    let pasteboard = state.annotationPasteboard
    pasteboard.clearContents()
    pasteboard.setData(try XCTUnwrap(makeImage(width: 4, height: 4).tiffRepresentation), forType: .tiff)
    XCTAssertFalse(state.pasteAnnotationsFromClipboard())
    XCTAssertEqual(state.annotations.count, 1)
  }

  func testВставленнаяКартинкаВстаётПодСнимок() throws {
    let state = try makeState(width: 200, height: 100)
    XCTAssertTrue(state.pasteImage(try makeImage(width: 60, height: 40)))
    XCTAssertTrue(state.isCombineMode)
    XCTAssertEqual(state.combineDirection, .vertical)
    // Столбец идёт снизу вверх: вставленная картинка первая, то есть под исходным снимком.
    XCTAssertEqual(state.sourceImage?.size, NSSize(width: 60, height: 40))
  }

  // MARK: - ANN-053 Spotlight

  func testЗатемнениеSpotlightПоУмолчанию45Процентов() throws {
    let state = try makeState()
    XCTAssertEqual(AnnotateState.defaultSpotlightOpacity, 0.45, accuracy: 0.0001)
    let item = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .spotlight, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), path: [], state: state
    ))
    XCTAssertEqual(item.properties.spotlightOpacity, 0.45, accuracy: 0.0001)
  }
}
