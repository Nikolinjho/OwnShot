import AppKit
import CoreImage
import ImageIO
import SwiftUI
import XCTest
@testable import Snapzy

final class AnnotateSecureReferenceTests: XCTestCase {
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  @MainActor
  func testКэшSecureБезЯвнойСилыСовпадаетСПрямымРендеромСилы10() throws {
    let annotationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let source = try loadFixture("source")
    let size = CGSize(width: 400, height: 200)
    let bounds = CGRect(x: 23, y: 143, width: 140, height: 40)
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 280, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.scaleBy(x: 2, y: 2)
    BlurEffectRenderer.drawSecureRegion(
      in: context, sourceCGImage: source, sourceSize: size, sourceRegion: bounds,
      destRegion: CGRect(origin: .zero, size: bounds.size), effectValue: 10,
      seed: BlurEffectRenderer.secureSeed(for: annotationId)
    )
    let direct = try XCTUnwrap(context.makeImage())
    let cached = try XCTUnwrap(BlurCacheManager().getCachedBlur(
      for: annotationId, bounds: bounds, sourceImage: NSImage(cgImage: source, size: size), blurType: .secure
    ))
    XCTAssertEqual(cached.width, direct.width)
    XCTAssertEqual(cached.height, direct.height)
    let ciContext = CIContext()
    let extent = CGRect(x: 0, y: 0, width: 280, height: 80)
    XCTAssertEqual(rgba(CIImage(cgImage: cached), bounds: extent, context: ciContext),
      rgba(CIImage(cgImage: direct), bounds: extent, context: ciContext),
      "Кэш должен использовать ту же начальную силу, что и прямой рендер Secure")
  }

  @MainActor
  func testSecureПовторяетСеткуПослеОчисткиКэша() throws {
    let source = NSImage(cgImage: try loadFixture("impulse-comb"), size: CGSize(width: 400, height: 200))
    let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let cache = BlurCacheManager()
    let bounds = CGRect(x: 20, y: 20, width: 360, height: 160)
    let first = try XCTUnwrap(cache.getCachedBlur(for: id, bounds: bounds,
      sourceImage: source, blurType: .secure, effectValue: 10))
    cache.clearAll()
    let restored = try XCTUnwrap(cache.getCachedBlur(for: id, bounds: bounds,
      sourceImage: source, blurType: .secure, effectValue: 10))
    let context = CIContext()
    let extent = CGRect(x: 0, y: 0, width: 720, height: 320)
    XCTAssertEqual(rgba(CIImage(cgImage: first), bounds: extent, context: context),
      rgba(CIImage(cgImage: restored), bounds: extent, context: context),
      "Восстановление одного UUID должно сохранять сетку независимо от кэша")
  }

  @MainActor
  func testSecureРазныеUUIDМеняютСеткуИУдаляютЧастьПиксельныхЛиний() throws {
    let source = NSImage(cgImage: try loadFixture("impulse-comb"), size: CGSize(width: 400, height: 200))
    let cache = BlurCacheManager()
    let context = CIContext()
    let positions = [82, 183, 284, 385, 486, 587, 688]
    var deleted = false
    var amplified = false
    var firstProfile: [UInt8]?
    var maximumDifference = 0.0
    for index in 1...16 {
      let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!
      let image = try XCTUnwrap(cache.getCachedBlur(for: id,
        bounds: CGRect(x: 20, y: 20, width: 360, height: 160), sourceImage: source,
        blurType: .secure, effectValue: 10))
      let bytes = rgba(CIImage(cgImage: image), bounds: CGRect(x: 0, y: 159, width: 720, height: 1), context: context)
      XCTAssertTrue((0..<720).allSatisfy { bytes[$0 * 4 + 3] == 255 }, "Маска должна оставаться непрозрачной")
      for position in positions {
        let local = position - 40
        let peak = ((local - 40)...(local + 40)).map { Int(bytes[$0 * 4]) }.max()!
        deleted = deleted || peak < 2
        amplified = amplified || peak > 50
      }
      if let firstProfile {
        let error = (0..<720).reduce(0) { $0 + abs(Int(bytes[$1 * 4]) - Int(firstProfile[$1 * 4])) }
        maximumDifference = max(maximumDifference, Double(error) / 720)
      } else {
        firstProfile = bytes
      }
    }
    // В двух нативных экспортах одинаковой маски остаются разные линии, остальные исчезают.
    // Обычный Gaussian сохраняет все семь линий с одинаковым пиком около 39/255.
    XCTAssertTrue(deleted, "Сетка должна удалять часть исходных однопиксельных линий")
    XCTAssertTrue(amplified, "Часть захваченных сеткой линий должна расширяться перед размытием")
    XCTAssertGreaterThan(maximumDifference, 2, "UUID должен влиять на сетку, а не только на ключ кэша")
  }

  @MainActor
  func testSecureКэшИЭкспортИспользуютОднуСеткуОбъекта() throws {
    let sourceCG = try loadFixture("impulse-comb")
    let source = NSImage(cgImage: sourceCG, size: CGSize(width: 400, height: 200))
    let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let bounds = CGRect(x: 20, y: 20, width: 360, height: 160)
    let cached = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: id, bounds: bounds,
      sourceImage: source, blurType: .secure, effectValue: 10))
    let exportContext = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    exportContext.scaleBy(x: 2, y: 2)
    let annotation = AnnotationItem(id: id, type: .blur(.secure), bounds: bounds,
      properties: AnnotationProperties(strokeWidth: AnnotationProperties.secureBlurControlValue(for: 10)))
    AnnotationRenderer(context: exportContext, drawsObjectShadow: false,
      sourceImage: source, sourceCGImage: sourceCG).draw(annotation)
    let exported = try XCTUnwrap(exportContext.makeImage())
    let context = CIContext()
    XCTAssertEqual(rgba(CIImage(cgImage: cached), bounds: CGRect(x: 0, y: 0, width: 720, height: 320), context: context),
      rgba(CIImage(cgImage: exported), bounds: CGRect(x: 40, y: 40, width: 720, height: 320), context: context),
      "Рендер без соли экспорта должен повторять сетку холста из UUID")
  }

  @MainActor
  func testSecureНезависимыеЭкспортыМеняютСеткуИНеВосстанавливаютИсходник() throws {
    let sourceCG = try loadFixture("impulse-comb")
    let source = NSImage(cgImage: sourceCG, size: CGSize(width: 400, height: 200))
    let state = AnnotateState(defaults: UserDefaults(suiteName: "secure-export-repeat.\(UUID().uuidString)")!)
    state.loadImage(source)
    var snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    snapshot.annotations = [AnnotationItem(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
      type: .blur(.secure), bounds: CGRect(x: 20, y: 20, width: 360, height: 160),
      properties: AnnotationProperties(strokeWidth: AnnotationProperties.secureBlurControlValue(for: 10)))]
    snapshot.padding = 0
    snapshot.backgroundStyle = .solidColor(.white)
    snapshot.cornerRadius = 0
    snapshot.shadowIntensity = 0
    snapshot.drawObjectShadow = false
    XCTAssertNil(snapshot.secureExportSalt, "Обычный экспорт должен брать новую соль на каждый рендер")

    func export(_ snapshot: AnnotateRenderSnapshot) throws -> [UInt8] {
      let image = try XCTUnwrap(AnnotateExporter.renderFlatFinalImage(snapshot: snapshot))
      let cgImage = try XCTUnwrap(AnnotateExporter.bestCGImage(from: image))
      XCTAssertEqual(cgImage.width, 800)
      XCTAssertEqual(cgImage.height, 400)
      return rgba(CIImage(cgImage: cgImage), bounds: CGRect(x: 44, y: 44, width: 712, height: 312), context: CIContext())
    }
    let first = try export(snapshot)
    let second = try export(snapshot)

    // Сетка может пропустить все редкие линии и дать одинаковую чёрную маску с разными солями.
    // Изменчивость проверяем на текстурном источнике, безопасность – на линиях.
    // Даже на текстуре одна случайная пара может иметь близкие сетки. Сравниваем первый
    // экспорт с семью независимыми и проверяем наиболее различную пару с прежними порогами.
    // Одна постоянная соль между рендерами даст нулевое различие во всей серии.
    var variationSnapshot = snapshot
    variationSnapshot.sourceImage = NSImage(cgImage: try loadFixture("source"), size: CGSize(width: 400, height: 200))
    let variationFirst = try export(variationSnapshot)
    var maximumError = 0.0
    var changedInMostDifferentPair = 0
    for _ in 0..<7 {
      let variationNext = try export(variationSnapshot)
      var error = 0.0
      var changed = 0
      for pixel in 0..<(712 * 312) {
        let delta = (0..<3).map { abs(Int(variationFirst[pixel * 4 + $0]) - Int(variationNext[pixel * 4 + $0])) }
        error += Double(delta.reduce(0, +)) / 3
        if delta.max()! > 2 { changed += 1 }
      }
      if error > maximumError {
        maximumError = error
        changedInMostDifferentPair = changed
      }
    }
    // У эталона два экспорта одной маски различаются: MAE 17,7, 102672 пикселя.
    XCTAssertGreaterThan(maximumError / Double(712 * 312), 0.5, "Независимые экспорты Secure должны менять случайную сетку")
    XCTAssertGreaterThan(changedInMostDifferentPair, 1_000, "Различие должно охватывать заметную часть маски")

    // Исходник – белые однопиксельные линии на чёрном. Маска не должна возвращать ни яркость, ни резкий край.
    for bytes in [first, second] {
      for y in 0..<312 {
        for x in 0..<712 {
          let pixel = (y * 712 + x) * 4
          XCTAssertEqual(bytes[pixel + 3], 255, "Маска должна оставаться непрозрачной")
          XCTAssertLessThan(bytes[pixel], 160, "Однопиксельная линия не должна сохранять исходную яркость")
          if x + 1 < 712 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[pixel]) - Int(bytes[pixel + 4])), 12,
              "Соседние пиксели не должны выдавать положение исходной линии")
          }
        }
      }
    }

    // Фиксированная соль повторяет растр: случайность задаёт только экспорт, а не сам алгоритм.
    snapshot.secureExportSalt = 7
    XCTAssertEqual(try export(snapshot), try export(snapshot), "Одна соль должна давать один растр")
  }

  func testSecureСилы3И10И30СохраняютШиринуПерехода() throws {
    for strength in [3.0, 10, 30] {
      let image = try renderStep(scale: 2, strength: strength)
      let measured = try stepSigma(image)
      let expected = max(5, strength) * 2
      XCTAssertEqual(measured, expected, accuracy: max(2, expected * 0.15),
        "Сила \(strength) должна задавать ширину сглаженного перехода")
    }
  }

  func testSecureУчитываетПлотность1xИ2xОдинРаз() throws {
    let one = try stepSigma(renderStep(scale: 1, strength: 10))
    let two = try stepSigma(renderStep(scale: 2, strength: 10))
    XCTAssertEqual(one, 10, accuracy: 2)
    XCTAssertEqual(two, 20, accuracy: 3)
    XCTAssertEqual(two / one, 2, accuracy: 0.2)
  }

  func testSecureПриОшибкеГеометрииЗаполняетМаскуНепрозрачнымЧёрным() throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16,
      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setAlpha(0.1)
    BlurEffectRenderer.drawSecureRegion(in: context, sourceCGImage: try loadFixture("source"),
      sourceSize: .zero, sourceRegion: CGRect(x: 0, y: 0, width: 32, height: 16),
      destRegion: CGRect(x: 0, y: 0, width: 32, height: 16))
    let bytes = rgba(CIImage(cgImage: try XCTUnwrap(context.makeImage())),
      bounds: CGRect(x: 0, y: 0, width: 32, height: 16), context: CIContext())
    for pixel in 0..<(32 * 16) {
      XCTAssertEqual(Array(bytes[(pixel * 4)..<(pixel * 4 + 4)]), [0, 0, 0, 255])
    }
  }

  private func renderStep(scale: Int, strength: Double) throws -> CGImage {
    let width = 400 * scale
    let height = 200 * scale
    let sourceContext = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    sourceContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    sourceContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
    sourceContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    sourceContext.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
    BlurEffectRenderer.drawSecureRegion(in: context,
      sourceCGImage: try XCTUnwrap(sourceContext.makeImage()), sourceSize: bounds.size,
      sourceRegion: bounds, destRegion: bounds, effectValue: strength, seed: 42)
    return try XCTUnwrap(context.makeImage())
  }

  private func stepSigma(_ image: CGImage) throws -> Double {
    let bytes = rgba(CIImage(cgImage: image),
      bounds: CGRect(x: 0, y: image.height / 2, width: image.width, height: 1), context: CIContext())
    func linear(_ value: UInt8) -> Double {
      let encoded = Double(value) / 255
      return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
    let lower = try XCTUnwrap((0..<image.width).first { linear(bytes[$0 * 4]) >= 0.1 })
    let upper = try XCTUnwrap((0..<image.width).first { linear(bytes[$0 * 4]) >= 0.9 })
    // Для нормального распределения расстояние между квантилями 10% и 90% равно 2,563σ.
    return Double(upper - lower) / 2.5631031311
  }

  private func loadFixture(_ name: String) throws -> CGImage {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Images/SecureRedaction/\(name).png")
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  private func rgba(_ image: CIImage, bounds: CGRect, context: CIContext) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
    context.render(image, toBitmap: &bytes, rowBytes: Int(bounds.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: colorSpace)
    return bytes
  }
}
