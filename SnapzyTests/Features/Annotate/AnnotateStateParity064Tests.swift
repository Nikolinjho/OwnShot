//
//  AnnotateStateParity064Tests.swift
//  SnapzyTests
//
//  Паритет Crop, эффектов и счётчика со CleanShot X 5.0.1 после живой сверки 063
//  (ANN-792, ANN-232, ANN-617, ANN-109, ANN-780, ANN-121).
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateStateParity064Tests: XCTestCase {
  // AnnotateState живёт до конца процесса: деинициализация в XCTest падает.
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeState(
    width: Int = 800, height: Int = 450, pointScale: CGFloat = 1,
    gray: UInt8 = 110, defaults: UserDefaults = UserDefaultsFactory.make()
  ) throws -> AnnotateState {
    let state = AnnotateState(defaults: defaults)
    Self.retainedAnnotateStates.append(state)
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height, red: gray, green: gray, blue: gray))
    state.loadImage(NSImage(
      cgImage: cgImage,
      size: NSSize(width: CGFloat(width) / pointScale, height: CGFloat(height) / pointScale)
    ))
    return state
  }

  /// Снимок с шумом: у каждого пикселя свой цвет, пикселизация по случайной точке это видит.
  private func makeNoisyImage(width: Int, height: Int, alpha: UInt8 = 255) throws -> CGImage {
    var bytes = [UInt8](repeating: alpha, count: width * height * 4)
    var value: UInt32 = 12345
    for index in 0..<(width * height) {
      for channel in 0..<3 {
        value = value &* 1_103_515_245 &+ 12345
        bytes[index * 4 + channel] = alpha == 0 ? 0 : UInt8((value >> 16) & 0xFF)
      }
    }
    return try XCTUnwrap(CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent))
  }

  private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
    let offset = (y * width + x) * 4
    return Array(bytes[offset..<(offset + 4)])
  }

  private func export(_ state: AnnotateState) throws -> CGImage {
    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    return try XCTUnwrap(AnnotateExporter.bestCGImage(from: rendered))
  }

  private func counterValues(_ state: AnnotateState) -> [Int] {
    state.annotations.compactMap { annotation in
      if case .counter(let value) = annotation.type { return value }
      return nil
    }
  }

  // MARK: - ANN-792 заливка расширения Crop цветом фона

  func testВходВCropРаспознаётЦветФонаПоКраюСнимка() throws {
    let state = try makeState()
    state.markAsSaved()
    state.beginCropInteraction()
    let color = try XCTUnwrap(state.cropFillColor?.usingColorSpace(.sRGB))
    XCTAssertEqual(color.redComponent * 255, 110, accuracy: 0.5)
    XCTAssertEqual(color.greenComponent * 255, 110, accuracy: 0.5)
    XCTAssertEqual(color.blueComponent * 255, 110, accuracy: 0.5)
    // Распознанный цвет – не правка пользователя.
    XCTAssertFalse(state.hasUnsavedChanges)
  }

  func testЭкспортРасширенногоCropЗалитЦветомФона() throws {
    let state = try makeState(width: 400, height: 300)
    state.beginCropInteraction()
    // Рамка вытянута за левый и верхний край на 30 px.
    state.updateCropRect(CGRect(x: -30, y: 0, width: 430, height: 330))
    state.confirmCropInteraction()
    let image = try export(state)
    XCTAssertEqual(image.width, 430)
    XCTAssertEqual(image.height, 330)
    let bytes = rgba(image)
    XCTAssertEqual(pixel(bytes, x: 2, y: 2, width: image.width), [110, 110, 110, 255])
    XCTAssertEqual(pixel(bytes, x: 200, y: 200, width: image.width), [110, 110, 110, 255])
  }

  func testВыборПользователяНеЗаменяетсяРаспознаннымЦветом() throws {
    let state = try makeState()
    state.cropFillColor = CropFillColor.normalized(.red)
    state.cropFillColor = nil
    state.beginCropInteraction()
    XCTAssertNil(state.cropFillColor)

    let other = try makeState()
    other.cropFillColor = CropFillColor.normalized(.blue)
    other.beginCropInteraction()
    let color = try XCTUnwrap(other.cropFillColor?.usingColorSpace(.sRGB))
    XCTAssertEqual(color.blueComponent, 1, accuracy: 0.01)
  }

  func testПёстрыйИлиПрозрачныйКрайНеДаётЦвета() throws {
    XCTAssertNil(CropBackgroundColorDetector.dominantEdgeColor(of: try makeNoisyImage(width: 64, height: 48)))
    XCTAssertNil(CropBackgroundColorDetector.dominantEdgeColor(of: try makeNoisyImage(width: 64, height: 48, alpha: 0)))
    let solid = try XCTUnwrap(TestImageFactory.solidColor(width: 20, height: 10, red: 250, green: 250, blue: 250))
    let color = try XCTUnwrap(CropBackgroundColorDetector.dominantEdgeColor(of: solid))
    XCTAssertEqual(color.redComponent * 255, 250, accuracy: 0.5)
  }

  // MARK: - ANN-232 ручки Crop держат минимум 12 px

  func testРучкиCropУпираютсяВМинимум12Пикселей() {
    let original = CGRect(x: 0, y: 0, width: 800, height: 450)
    let far = CGPoint(x: 2000, y: -2000)
    XCTAssertEqual(
      CropDragSelection.resizedRect(handle: .topLeft, original: original, to: far, minSize: 12),
      CGRect(x: 788, y: 0, width: 12, height: 12))
    XCTAssertEqual(
      CropDragSelection.resizedRect(handle: .left, original: original, to: far, minSize: 12),
      CGRect(x: 788, y: 0, width: 12, height: 450))
    XCTAssertEqual(
      CropDragSelection.resizedRect(handle: .top, original: original, to: far, minSize: 12),
      CGRect(x: 0, y: 0, width: 800, height: 12))
    XCTAssertEqual(
      CropDragSelection.resizedRect(handle: .bottomRight, original: original, to: CGPoint(x: -500, y: 900), minSize: 12),
      CGRect(x: 0, y: 438, width: 12, height: 12))
    // Обычное перетаскивание без упора.
    XCTAssertEqual(
      CropDragSelection.resizedRect(handle: .right, original: original, to: CGPoint(x: 900, y: 10), minSize: 12),
      CGRect(x: 0, y: 0, width: 900, height: 450))
  }

  func testМинимумРучекRetinaСнимка6Точек() throws {
    let state = try makeState(width: 200, height: 160, pointScale: 2)
    let rect = CropDragSelection.resizedRect(
      handle: .bottomLeft, original: CGRect(x: 0, y: 0, width: 100, height: 80),
      to: CGPoint(x: 500, y: 500), minSize: state.minimumCropSize)
    XCTAssertEqual(rect.size, CGSize(width: 6, height: 6))
    state.beginCropInteraction()
    state.updateCropRect(rect)
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 12, height: 12))
  }

  // MARK: - ANN-617 экспорт совпадает с подписью Image size

  func testЭкспортОбрезкиОкругляетсяКакПодпись() throws {
    let state = try makeState(width: 600, height: 400)
    state.cropRect = CGRect(x: 0, y: 0, width: 600, height: CGFloat(600) * 3 / 7)
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 600, height: 257))
    var image = try export(state)
    XCTAssertEqual(CGSize(width: image.width, height: image.height), state.cropPixelSize)

    state.cropRect = CGRect(x: 0, y: 0, width: 400, height: CGFloat(400) * 5 / 7)
    XCTAssertEqual(state.cropPixelSize, CGSize(width: 400, height: 286))
    image = try export(state)
    XCTAssertEqual(CGSize(width: image.width, height: image.height), state.cropPixelSize)

    XCTAssertEqual(AnnotateExporter.exportPixelLength(257.14, scale: 1), 257)
    XCTAssertEqual(AnnotateExporter.exportPixelLength(142.86, scale: 2), 286)
    XCTAssertEqual(AnnotateExporter.exportPixelLength(0.2, scale: 1), 1)
  }

  // MARK: - ANN-109 Blur (smooth) начинает с силы 10

  func testНоваяМаскаBlurSmoothНачинаетССилы10() throws {
    let defaults = UserDefaultsFactory.make()
    let state = try makeState(defaults: defaults)
    state.activateTool(.blur)
    XCTAssertEqual(state.activeBlurType, .pixelated)
    state.setActiveBlurType(.gaussian)
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "10")
    let item = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .blur, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 120, y: 80), path: [], state: state))
    XCTAssertEqual(AnnotationProperties.secureBlurStrength(for: item.properties.strokeWidth), 10, accuracy: 0.01)

    // Сила, выбранная слайдером, сохраняется в параметрах инструмента и переживает перезапуск.
    state.quickStrokeWidthBinding.wrappedValue = AnnotationProperties.secureBlurControlValue(for: 30)
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "30")
    let relaunched = try makeState(defaults: defaults)
    relaunched.activateTool(.blur)
    XCTAssertEqual(relaunched.activeBlurType, .gaussian)
    XCTAssertEqual(relaunched.quickStrokeWidthDisplayText, "30")
  }

  func testBlurSmoothБезСохранённойТолщиныДаёт10() throws {
    // Сохранён только стиль Blur (smooth), толщина инструмента не сохранялась.
    let defaults = UserDefaultsFactory.make()
    defaults.set(Data(#"{"blurType":"gaussian"}"#.utf8), forKey: PreferencesKeys.annotateParameterDefaults)
    let state = try makeState(defaults: defaults)
    state.activateTool(.blur)
    XCTAssertEqual(state.activeBlurType, .gaussian)
    XCTAssertEqual(state.quickStrokeWidthDisplayText, "10")
  }

  func testВыделеннаяМаскаПриСменеНаSmoothПолучаетСилу10() throws {
    let state = try makeState()
    let mask = AnnotationItem(type: .blur(.pixelated), bounds: CGRect(x: 10, y: 10, width: 100, height: 60),
      properties: AnnotationProperties(strokeWidth: 1))
    state.annotations = [mask]
    state.setSelectedAnnotationIds([mask.id])
    state.setActiveBlurType(.gaussian)
    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.type, .blur(.gaussian))
    XCTAssertEqual(AnnotationProperties.secureBlurStrength(for: updated.properties.strokeWidth), 10, accuracy: 0.01)
  }

  // MARK: - ANN-780 случайная пикселизация

  func testДваЭкспортаPixelateРазличаютсяТолькоВнутриМаски() throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedAnnotateStates.append(state)
    let source = try makeNoisyImage(width: 200, height: 150)
    state.loadImage(NSImage(cgImage: source, size: NSSize(width: 200, height: 150)))
    let maskBounds = CGRect(x: 40, y: 40, width: 100, height: 60)
    state.annotations = [AnnotationItem(type: .blur(.pixelated), bounds: maskBounds,
      properties: AnnotationProperties(strokeWidth: 3))]
    let first = rgba(try export(state))
    let second = rgba(try export(state))
    XCTAssertEqual(first.count, second.count)
    var insideDiffers = false
    for y in 0..<150 {
      for x in 0..<200 {
        let a = pixel(first, x: x, y: y, width: 200), b = pixel(second, x: x, y: y, width: 200)
        // Строки буфера идут сверху, маска задана снизу.
        let inside = maskBounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(150 - y) - 0.5))
        if inside {
          if a != b { insideDiffers = true }
        } else {
          XCTAssertEqual(a, b, "Вне маски пиксель \(x),\(y) не должен меняться")
        }
      }
    }
    XCTAssertTrue(insideDiffers, "Два экспорта одной маски Pixelate должны различаться, как у эталона")
  }

  func testКэшХолстаPixelateСтабиленМеждуПерерисовками() throws {
    let source = try makeNoisyImage(width: 200, height: 150)
    let image = NSImage(cgImage: source, size: NSSize(width: 200, height: 150))
    let id = UUID()
    let bounds = CGRect(x: 40, y: 40, width: 100, height: 60)
    let first = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: id, bounds: bounds, sourceImage: image,
      blurType: .pixelated, effectValue: 12, quality: .export))
    let second = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: id, bounds: bounds, sourceImage: image,
      blurType: .pixelated, effectValue: 12, quality: .export))
    XCTAssertEqual(rgba(first), rgba(second))
    let other = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: UUID(), bounds: bounds, sourceImage: image,
      blurType: .pixelated, effectValue: 12, quality: .export))
    XCTAssertNotEqual(rgba(first), rgba(other))
  }

  // MARK: - ANN-121 первый счётчик свежего документа

  private func event(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
    )!
  }

  private func makeCanvas(_ state: AnnotateState) -> DrawingCanvasNSView {
    let canvas = DrawingCanvasNSView(state: state)
    canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 450)
    canvas.displayScale = 1
    canvas.canvasBounds = CGRect(x: 0, y: 0, width: 800, height: 450)
    return canvas
  }

  private func click(_ canvas: DrawingCanvasNSView, at point: CGPoint, clickCount: Int = 1) {
    canvas.mouseDown(with: event(.leftMouseDown, at: point, clickCount: clickCount))
    canvas.mouseUp(with: event(.leftMouseUp, at: point, clickCount: clickCount))
  }

  func testПервыйКликCounterВСвежемРедактореДаёт1() throws {
    let state = try makeState()
    state.activateTool(.counter)
    let canvas = makeCanvas(state)
    click(canvas, at: CGPoint(x: 60, y: 60))
    XCTAssertEqual(counterValues(state), [1])
    click(canvas, at: CGPoint(x: 160, y: 60))
    click(canvas, at: CGPoint(x: 260, y: 60))
    XCTAssertEqual(counterValues(state), [1, 2, 3])
  }

  func testДвойнойКликНаМестеСчётчикаНеСоздаётВторой() throws {
    let state = try makeState()
    state.activateTool(.counter)
    let canvas = makeCanvas(state)
    click(canvas, at: CGPoint(x: 60, y: 60))
    click(canvas, at: CGPoint(x: 60, y: 60), clickCount: 2)
    XCTAssertEqual(counterValues(state), [1])
  }

  func testStartingNumber1ИзМенюДаётПервый1() throws {
    let state = try makeState()
    state.activateTool(.counter)
    for value in [0, 1, 5, 0, 9999, 7, 1] { state.setCounterStartingNumber(value) }
    let canvas = makeCanvas(state)
    click(canvas, at: CGPoint(x: 60, y: 60))
    XCTAssertEqual(counterValues(state), [1])
  }
}
