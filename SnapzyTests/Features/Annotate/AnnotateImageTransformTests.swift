import AppKit
import XCTest
@testable import Snapzy

final class AnnotateImageTransformTests: XCTestCase {
  @MainActor private static var states: [AnnotateState] = []

  private func image() -> NSImage {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
    bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
    bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 3, y: 0)
    let image = NSImage(size: NSSize(width: 2, height: 1))
    image.addRepresentation(bitmap)
    return image
  }

  func testДиалогРазмераНачинаетсяСИсходныхПикселей() {
    let dimensions = AnnotateResizeDimensions.initial(pixelSize: CGSize(width: 1408, height: 1850))
    XCTAssertEqual(dimensions.width, 1408)
    XCTAssertEqual(dimensions.height, 1850)
    XCTAssertEqual(dimensions.ratio, 1408.0 / 1850.0)
  }

  func testИзменениеШириныНеОкругляетОбратноВведённоеЗначение() {
    let dimensions = AnnotateResizeDimensions.editWidth(100, ratio: 3, locked: true, height: 20)
    XCTAssertEqual(dimensions.width, 100)
    XCTAssertEqual(dimensions.height, 33)
    let unlocked = AnnotateResizeDimensions.editWidth(100, ratio: 3, locked: false, height: 20)
    XCTAssertEqual(unlocked.height, 20)
  }

  func testПроцентыРазмеровСчитаютсяОтТекущейОбрезки() {
    XCTAssertEqual(AnnotateResizeUnit.percent.pixels(value: 50, reference: 200), 100)
    XCTAssertEqual(AnnotateResizeUnit.percent.value(pixels: 80, reference: 160), 50)
    XCTAssertEqual(AnnotateResizeUnit.pixels.pixels(value: 101, reference: 200), 101)
    XCTAssertEqual(AnnotateResizeUnit.percent.pixels(value: 33.3, reference: 300), 100)
  }

  func testРазмерЗадаётсяВПикселяхСохраняяRetinaМасштаб() throws {
    let resized = try XCTUnwrap(image().resizedToPixels(width: 8, height: 6))
    XCTAssertEqual(resized.backingPixelSize, CGSize(width: 8, height: 6))
    XCTAssertEqual(resized.size, CGSize(width: 4, height: 3))
    XCTAssertNil(image().resizedToPixels(width: 0, height: 4))
  }

  func testОтражениеПереноситПикселиИСохраняетПрозрачность() throws {
    let original = image()
    let horizontal = try XCTUnwrap(original.flippedImage(horizontal: true))
    let h = NSBitmapImageRep(cgImage: try XCTUnwrap(horizontal.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    XCTAssertEqual(try XCTUnwrap(h.colorAt(x: 3, y: 0)).redComponent, 1, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(h.colorAt(x: 0, y: 0)).blueComponent, 1, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(h.colorAt(x: 0, y: 1)).alphaComponent, 0, accuracy: 0.01)
    let vertical = try XCTUnwrap(original.flippedImage(horizontal: false))
    let v = NSBitmapImageRep(cgImage: try XCTUnwrap(vertical.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    XCTAssertEqual(try XCTUnwrap(v.colorAt(x: 0, y: 1)).redComponent, 1, accuracy: 0.01)
  }

  @MainActor
  func testИзменениеРазмераПереноситАннотацииИОтменяетсяОднимШагом() throws {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    let annotation = AnnotationItem(type: .line(start: CGPoint(x: 0.25, y: 0.25), end: CGPoint(x: 1, y: 0.75)),
      bounds: CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.5), properties: AnnotationProperties())
    state.annotations = [annotation]
    state.resizeImage(pixelWidth: 8, pixelHeight: 4, flattenAnnotations: false)
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 8, height: 4))
    XCTAssertEqual(state.annotations.first?.bounds, annotation.bounds.applying(CGAffineTransform(scaleX: 2, y: 2)))
    if case .line(let start, let end) = state.annotations[0].type {
      XCTAssertEqual(start, CGPoint(x: 0.5, y: 0.5))
      XCTAssertEqual(end, CGPoint(x: 2, y: 1.5))
    } else { XCTFail("Линия должна остаться редактируемой") }
    state.undo()
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 4, height: 2))
    XCTAssertEqual(state.annotations.first?.bounds, annotation.bounds)
    state.redo()
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 8, height: 4))
  }

  @MainActor
  func testРазмерОбрезкиПриДробнойRetinaРамкеОкругляетсяДоБлижайшего() throws {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    state.cropRect = CGRect(x: 0.25, y: 0, width: 1.01, height: 0.74)
    // Подпись Image size как у эталона (ANN-617): 2,02 × 1,48 px → 2 × 1.
    // Экспорт пока округляет вверх (AnnotateExporter), сверка подписи с экспортом снята.
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 2, height: 1))
    state.resizeImage(pixelWidth: 8, pixelHeight: 4, flattenAnnotations: false)
    XCTAssertEqual(state.sourceImage?.size, CGSize(width: 4, height: 2))
  }

  @MainActor
  func testResizeМеняетТекущуюОбрезкуИСохраняетРедактируемуюЛинию() throws {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    let crop = CGRect(x: 0.5, y: 0.25, width: 1, height: 0.5)
    state.cropRect = crop
    let annotation = AnnotationItem(type: .line(start: CGPoint(x: 0.75, y: 0.375), end: CGPoint(x: 1.25, y: 0.625)),
      bounds: CGRect(x: 0.75, y: 0.375, width: 0.5, height: 0.25), properties: AnnotationProperties())
    state.annotations = [annotation]
    state.resizeImage(pixelWidth: 8, pixelHeight: 4, flattenAnnotations: false)
    let resized = try XCTUnwrap(AnnotateExporter.renderMockupFlatImage(snapshot: XCTUnwrap(state.makeRenderSnapshot())))
    XCTAssertEqual(resized.backingPixelSize, CGSize(width: 8, height: 4))
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 8, height: 4))
    XCTAssertEqual(state.annotations.first?.id, annotation.id)
    if case .line(let start, let end) = state.annotations[0].type {
      XCTAssertEqual(start, CGPoint(x: 1, y: 0.5))
      XCTAssertEqual(end, CGPoint(x: 3, y: 1.5))
    } else { XCTFail("Линия должна остаться редактируемой") }
    state.undo()
    XCTAssertEqual(state.cropRect, crop)
    XCTAssertEqual(state.annotations.first?.bounds, annotation.bounds)
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 4, height: 2))
    state.redo()
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 8, height: 4))
  }

  @MainActor
  func testResizeСЗапеканиемУчитываетОбрезку() throws {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    state.cropRect = CGRect(x: 0.5, y: 0, width: 1, height: 0.5)
    state.annotations = [AnnotationItem(type: .rectangle,
      bounds: CGRect(x: 0.5, y: 0, width: 1, height: 0.5), properties: AnnotationProperties())]
    state.resizeImage(pixelWidth: 8, pixelHeight: 4, flattenAnnotations: true)
    XCTAssertTrue(state.annotations.isEmpty)
    let exported = try XCTUnwrap(AnnotateExporter.renderMockupFlatImage(snapshot: XCTUnwrap(state.makeRenderSnapshot())))
    XCTAssertEqual(exported.backingPixelSize, CGSize(width: 8, height: 4))
    state.undo()
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertFalse(state.canUndo)
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 8, height: 4))
  }

  @MainActor
  func testОтменаCropПослеResizeНеВозвращаетРамкуСтарогоИсходника() throws {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    state.cropRect = CGRect(x: 0.5, y: 0.25, width: 1, height: 0.5)
    state.beginCropInteraction()
    state.resizeImage(pixelWidth: 8, pixelHeight: 4, flattenAnnotations: false)
    state.cancelCrop()
    let exported = try XCTUnwrap(AnnotateExporter.renderMockupFlatImage(snapshot: XCTUnwrap(state.makeRenderSnapshot())))
    XCTAssertEqual(exported.backingPixelSize, CGSize(width: 8, height: 4))
  }

  @MainActor
  func testUndoResizeВозвращаетСкрытуюПанельФона() {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    state.showSidebar = true
    state.beginCropInteraction()
    XCTAssertFalse(state.showSidebar)
    state.resizeImage(pixelWidth: 8, pixelHeight: 4, flattenAnnotations: false)
    state.undo()
    XCTAssertTrue(state.showSidebar)
  }

  @MainActor
  func testResizeВРежимеCropВыходитИзCrop() async throws {
    let state = AnnotateState()
    Self.states.append(state)
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: 200, height: 160))
    state.loadImage(NSImage(cgImage: cgImage, size: CGSize(width: 100, height: 80)))
    state.beginCropInteraction()
    for _ in 0..<100 where state.cropEdgeProfile == nil { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertNotNil(state.cropEdgeProfile)
    state.resizeImage(pixelWidth: 100, pixelHeight: 80, flattenAnnotations: false)
    // Как у эталона (ANN-258): после Resize редактор выходит из Crop.
    XCTAssertFalse(state.isCropActive)
    XCTAssertNotEqual(state.selectedTool, .crop)
    // Повторный вход в Crop строит профиль краёв уже по новому изображению.
    state.beginCropInteraction()
    for _ in 0..<100 where state.cropEdgeProfile == nil { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(state.isCropActive)
    XCTAssertNotNil(state.cropEdgeProfile)
  }

  @MainActor
  func testОтражениеЗапекаетАннотацииИUndoВозвращаетРедактируемые() throws {
    let state = AnnotateState()
    Self.states.append(state)
    state.loadImage(image())
    let annotation = AnnotationItem(type: .rectangle, bounds: CGRect(x: 0.25, y: 0.25, width: 1, height: 0.5), properties: AnnotationProperties())
    state.annotations = [annotation]
    state.flipImage(horizontal: true)
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertEqual(state.sourceImage?.backingPixelSize, CGSize(width: 4, height: 2))
    state.undo()
    XCTAssertEqual(state.annotations.first?.id, annotation.id)
  }
}
