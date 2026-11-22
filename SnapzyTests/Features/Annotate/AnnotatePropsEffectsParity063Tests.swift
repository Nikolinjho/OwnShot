//
//  AnnotatePropsEffectsParity063Tests.swift
//  SnapzyTests
//
//  Поповер Image Size, Starting number, эффекты Redaction и фон холста
//  по замерам CleanShot X 5.0.1 (evidence/spec-063-live).
//

import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotatePropsEffectsParity063Tests: XCTestCase {

  // MARK: Image Size

  func testImageSizeПроцентыОтбрасываютДробьВОбеСтороны() {
    // ANN-262: 901×561, 33 % → 297×185, 50 % → 450×280, обратно 32 % и 49 %.
    let reference = (width: 901, height: 561)
    let at33 = AnnotateImageSizeInput.edit(value: 33, isWidth: true, unit: .percent, locked: true,
      ratio: 901.0 / 561.0, reference: reference, current: reference)
    XCTAssertEqual(at33.width, 297)
    XCTAssertEqual(at33.height, 185)
    let at50 = AnnotateImageSizeInput.edit(value: 50, isWidth: false, unit: .percent, locked: true,
      ratio: 901.0 / 561.0, reference: reference, current: reference)
    XCTAssertEqual(at50.width, 450)
    XCTAssertEqual(at50.height, 280)
    XCTAssertEqual(AnnotateImageSizeInput.percent(pixels: 297, reference: 901), 32)
    XCTAssertEqual(AnnotateImageSizeInput.percent(pixels: 185, reference: 561), 32)
    XCTAssertEqual(AnnotateImageSizeInput.percent(pixels: 450, reference: 901), 49)
    XCTAssertEqual(AnnotateImageSizeInput.percent(pixels: 280, reference: 561), 49)
    XCTAssertEqual(AnnotateImageSizeInput.percent(pixels: 901, reference: 901), 100)
    XCTAssertEqual(AnnotateImageSizeInput.text(pixels: 450, reference: 901, unit: .percent), "49")
    XCTAssertEqual(AnnotateImageSizeInput.text(pixels: 450, reference: 901, unit: .pixels), "450")
  }

  func testImageSizeБезЗамкаМеняетсяТолькоОдноПоле() {
    let reference = (width: 901, height: 561)
    let edited = AnnotateImageSizeInput.edit(value: 33, isWidth: true, unit: .percent, locked: false,
      ratio: 901.0 / 561.0, reference: reference, current: reference)
    XCTAssertEqual(edited.width, 297)
    XCTAssertEqual(edited.height, 561)
    XCTAssertEqual(AnnotateImageSizeInput.pixels(percent: 0, reference: 901), 1, "ноль поднимается до 1 px")
  }

  func testImageSizeБольшойПроцентПриЗакрытомЗамкеОграничиваетОбеСтороны() {
    let reference = (width: 901, height: 561)
    let edited = AnnotateImageSizeInput.edit(value: .max, isWidth: true, unit: .percent, locked: true,
      ratio: 901.0 / 561.0, reference: reference, current: reference)

    XCTAssertEqual(edited.width, 32769)
    XCTAssertEqual(edited.height, 32769)
  }

  func testImageSizeБольшойПроцентПриОткрытомЗамкеОграничиваетТолькоВыбраннуюСторону() {
    let reference = (width: 901, height: 561)
    let current = (width: 700, height: 400)
    let widthEdited = AnnotateImageSizeInput.edit(value: .max, isWidth: true, unit: .percent, locked: false,
      ratio: 901.0 / 561.0, reference: reference, current: current)
    let heightEdited = AnnotateImageSizeInput.edit(value: .max, isWidth: false, unit: .percent, locked: false,
      ratio: 901.0 / 561.0, reference: reference, current: current)

    XCTAssertEqual(widthEdited.width, 32769)
    XCTAssertEqual(widthEdited.height, current.height)
    XCTAssertEqual(heightEdited.width, current.width)
    XCTAssertEqual(heightEdited.height, 32769)
  }

  func testImageSizeПоляПропускаютТолькоЦифры() {
    // ANN-359: буквы у эталона не вводятся, значение остаётся.
    XCTAssertEqual(AnnotateImageSizeInput.digitsOnly("ффф"), "")
    XCTAssertEqual(AnnotateImageSizeInput.digitsOnly("60a0"), "600")
    XCTAssertEqual(AnnotateImageSizeInput.digitsOnly("-1.5"), "15")
    XCTAssertEqual(AnnotateImageSizeInput.digitsOnly("１２"), "", "полноширинные цифры не проходят")
  }

  // MARK: Starting number

  func testStartingNumberПропускаетТолькоЦифрыИПрижимаетК9999() {
    // ANN-502: «-1» → 1, «1.5» → 15, буквы не стирают значение, 100000 → 9999.
    XCTAssertEqual(AnnotateCounterSettings.sanitizedStartingNumberInput("-1"), "1")
    XCTAssertEqual(AnnotateCounterSettings.sanitizedStartingNumberInput("1.5"), "15")
    XCTAssertEqual(AnnotateCounterSettings.sanitizedStartingNumberInput("15abc"), "15")
    XCTAssertEqual(AnnotateCounterSettings.startingNumber(fromInput: "-1"), 1)
    XCTAssertEqual(AnnotateCounterSettings.startingNumber(fromInput: "1.5"), 15)
    XCTAssertNil(AnnotateCounterSettings.startingNumber(fromInput: "abc"), "буквы не обнуляют число")
    XCTAssertNil(AnnotateCounterSettings.startingNumber(fromInput: ""))
    XCTAssertEqual(AnnotateCounterSettings.startingNumber(fromInput: "0"), 0)
    XCTAssertEqual(AnnotateCounterSettings.startingNumber(fromInput: "100000"), 9999)
    XCTAssertEqual(AnnotateCounterSettings.startingNumber(fromInput: "99999999999999999999999"), 9999)
  }

  // MARK: Фон

  func testRatioAutoДобавляетРавныеПоляСоВсехСторон() {
    // ANN-287, ANN-793: 800×450 и Padding 300 → 1400×1050, Padding 300 + Inset 100 → 1600×1250.
    let shot = CGSize(width: 800, height: 450)
    XCTAssertEqual(AspectRatioOption.auto.canvasSize(for: shot, padding: 300, alignmentSpace: 0),
      CGSize(width: 1400, height: 1050))
    let card = CGSize(width: 1000, height: 650)
    XCTAssertEqual(AspectRatioOption.auto.canvasSize(for: card, padding: 300, alignmentSpace: 0),
      CGSize(width: 1600, height: 1250))
    XCTAssertEqual(AspectRatioOption.auto.canvasSize(for: card, padding: 0, alignmentSpace: 0), card)
    // Остальные пропорции не меняются.
    let square = AspectRatioOption.square.canvasSize(for: shot, padding: 300, alignmentSpace: 0)
    XCTAssertEqual(square.width, square.height, accuracy: 0.001)
    XCTAssertEqual(square.width, 1400, accuracy: 0.001)
  }

  func testCornersНа60ДаютНепрерывныйУголРадиусом135() throws {
    // ANN-289: у эталона серый снимка на верхней кромке начинается в ≈150 px от угла.
    XCTAssertEqual(AnnotateBackgroundCorners.radius(forSlider: 60), 135, accuracy: 0.001)
    XCTAssertEqual(AnnotateBackgroundCorners.radius(forSlider: 0), 0)
    XCTAssertEqual(AnnotateBackgroundCorners.radius(forSlider: -5), 0)
    let width = 800, height = 450
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.addPath(AnnotateBackgroundCorners.path(in: CGRect(x: 0, y: 0, width: width, height: height),
      radius: AnnotateBackgroundCorners.radius(forSlider: 60)))
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fillPath()
    let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    // Верхняя строка буфера – верх изображения.
    let firstOpaque = (0..<400).first { data[$0 * 4 + 3] > 128 } ?? -1
    XCTAssertEqual(firstOpaque, 150, accuracy: 4)
    let at30 = (0..<400).first { data[(30 * width + $0) * 4 + 3] > 128 } ?? -1
    XCTAssertEqual(at30, 50, accuracy: 3)
  }

  func testТеньХолстаПовторяетПрофильЭталона() throws {
    // ANN-288: Shadow 100 на прозрачном фоне, альфа под нижним краем 203, на 30 px 166,
    // на 100 px 94, на 150 px 58, над верхним краем на 10 px ≈40.
    let size = CGSize(width: 1400, height: 1050)
    let image = NSImage(size: size)
    let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 1050,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    image.addRepresentation(rep)
    let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
    let context = graphics.cgContext
    // Тот же порядок слоёв, что и в AnnotateExporter.drawCanvasShadow.
    let silhouette = CGRect(x: 300, y: 300, width: 800, height: 450)
    context.saveGState()
    let outside = CGMutablePath()
    outside.addRect(CGRect(origin: .zero, size: size))
    outside.addRect(silhouette)
    context.addPath(outside)
    context.clip(using: .evenOdd)
    for layer in AnnotateCanvasShadowProfile.layers {
      context.setShadow(offset: CGSize(width: 0, height: -layer.offsetY),
        blur: layer.sigma * AnnotateCanvasShadowProfile.coreGraphicsBlurPerSigma,
        color: NSColor.black.withAlphaComponent(layer.opacity).cgColor)
      context.setFillColor(NSColor.black.cgColor)
      context.fill(silhouette)
    }
    context.restoreGState()
    // NSBitmapImageRep: строка 0 – верх; силуэт в координатах CG снизу, верх снимка – строка 300.
    func alpha(_ x: Int, _ yFromTop: Int) -> Int { rep.colorAt(x: x, y: yFromTop).map { Int(($0.alphaComponent * 255).rounded()) } ?? -1 }
    XCTAssertEqual(alpha(700, 750), 203, accuracy: 20)
    XCTAssertEqual(alpha(700, 780), 166, accuracy: 20)
    XCTAssertEqual(alpha(700, 850), 94, accuracy: 15)
    XCTAssertEqual(alpha(700, 900), 58, accuracy: 15)
    XCTAssertEqual(alpha(700, 289), 40, accuracy: 15)
    XCTAssertLessThan(alpha(700, 1045), 12, "хвост тени ≈250–300 px")
  }

  // MARK: Blur (smooth) и Pixelate

  func testBlurSmoothСлайдер3_30ИСилаПоЭталону() {
    // ANN-109: слайдер 3…30, сила почти не меняет размытие (σ ≈ 8 → 7,5 pt).
    XCTAssertEqual(BlurEffectRenderer.smoothBlurStrengthRange, 3 ... 30)
    for strength: CGFloat in [3, 10, 30] {
      let control = AnnotationProperties.secureBlurControlValue(for: strength)
      let effect = AnnotationProperties.gaussianBlurRadius(for: control)
      XCTAssertEqual(BlurEffectRenderer.smoothBlurStrength(forEffectValue: effect), strength, accuracy: 0.01)
    }
    XCTAssertEqual(BlurEffectRenderer.smoothBlurSigmaPoints(forStrength: 3), 8.05, accuracy: 0.001)
    XCTAssertEqual(BlurEffectRenderer.smoothBlurSigmaPoints(forStrength: 10), 7.65, accuracy: 0.001)
    XCTAssertEqual(BlurEffectRenderer.smoothBlurSigmaPoints(forStrength: 30), 7.55, accuracy: 0.001)
    XCTAssertEqual(BlurEffectRenderer.smoothBlurSigmaPoints(forStrength: 100), 7.55, accuracy: 0.001)
  }

  func testBlurSmoothНаМаксимумеОставляетТекстуру() throws {
    // У OwnShot максимум стирал маску в ровный серый (std 1,6), у эталона текстура остаётся.
    let source = try makeStripes(width: 400, height: 100, period: 24)
    let context = try makeContext(width: 400, height: 100)
    let control = AnnotationProperties.secureBlurControlValue(for: 30)
    BlurEffectRenderer.drawGaussianRegion(in: context, sourceCGImage: source, sourceSize: CGSize(width: 400, height: 100),
      sourceRegion: CGRect(x: 0, y: 0, width: 400, height: 100), destRegion: CGRect(x: 0, y: 0, width: 400, height: 100),
      radius: Double(AnnotationProperties.gaussianBlurRadius(for: control)))
    XCTAssertGreaterThan(try luminanceDeviation(context, row: 50), 3)
  }

  func testPixelateСидМеняетБлокиИСтабиленДляОднойМаски() throws {
    // ANN-780: две маски на одной области различаются, повторный рендер той же маски совпадает.
    let source = try makeStripes(width: 120, height: 60, period: 3)
    func render(seed: UInt64?) throws -> [UInt8] {
      let context = try makeContext(width: 120, height: 60)
      BlurEffectRenderer.drawPixelatedRegion(in: context, sourceCGImage: source, sourceSize: CGSize(width: 120, height: 60),
        sourceRegion: CGRect(x: 0, y: 0, width: 120, height: 60), destRegion: CGRect(x: 0, y: 0, width: 120, height: 60),
        pixelSize: 12, seed: seed)
      let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      return Array(UnsafeBufferPointer(start: data, count: 120 * 60 * 4))
    }
    let first = BlurEffectRenderer.secureSeed(for: UUID())
    let second = BlurEffectRenderer.secureSeed(for: UUID())
    XCTAssertEqual(try render(seed: first), try render(seed: first))
    XCTAssertNotEqual(try render(seed: first), try render(seed: second))
    XCTAssertEqual(try render(seed: nil), try render(seed: nil), "без сида рендер прежний и детерминированный")
  }

  // MARK: Палитра и нижняя панель

  func testКнопкаDeleteПалитрыВсплываетВТочкеКлика() {
    // ANN-208: окно 74×34 pt, левый верхний угол в точке клика.
    let frame = AnnotateSavedColorDeletePopup.frame(at: NSPoint(x: 1094, y: 800))
    XCTAssertEqual(frame, NSRect(x: 1094, y: 766, width: 74, height: 34))
  }

  func testРазделительНижнейПанелиБледнеетВНеактивномОкне() {
    // ANN-650: 205 в активном окне, 230 в неактивном, линия 230.
    XCTAssertEqual(AnnotateBottomBarSeparator.lightColors(isActive: true).hairline, 0xCDCDCD)
    XCTAssertEqual(AnnotateBottomBarSeparator.lightColors(isActive: false).hairline, 0xE6E6E6)
    XCTAssertEqual(AnnotateBottomBarSeparator.lightColors(isActive: true).line, 0xE6E6E6)
  }

  // MARK: Вспомогательное

  private func makeContext(width: Int, height: Int) throws -> CGContext {
    try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  }

  /// Вертикальные чёрно-белые полосы – грубая модель строки текста.
  private func makeStripes(width: Int, height: Int, period: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width where (x / period + y / (period * 2)).isMultiple(of: 2) {
        let offset = (y * width + x) * 4
        bytes[offset] = 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = 0
      }
    }
    return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)), decode: nil,
      shouldInterpolate: false, intent: .defaultIntent))
  }

  private func luminanceDeviation(_ context: CGContext, row: Int) throws -> Double {
    let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let values = (40..<(context.width - 40)).map { Double(data[(row * context.width + $0) * 4]) }
    let mean = values.reduce(0, +) / Double(values.count)
    return sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
  }
}
