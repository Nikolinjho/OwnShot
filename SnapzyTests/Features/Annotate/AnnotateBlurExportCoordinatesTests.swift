import AppKit
import SwiftUI
import CoreImage
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateBlurExportCoordinatesTests: XCTestCase {
  private static var retainedStates: [AnnotateState] = []
  private let sourceSize = CGSize(width: 200, height: 150)
  private let crop = CGRect(x: 80, y: 50, width: 100, height: 80)
  private let annotationBounds = CGRect(x: 110, y: 80, width: 55, height: 35)

  func testЭкспортРазмытияПослеОбрезкиСПолямиБерётИсходныеКоординаты() throws {
    let source = try makeAsymmetricSource()
    for type in [BlurType.secure, .gaussian, .pixelated] {
      let (snapshot, annotation, cached) = try makeSnapshot(source: source, type: type, padding: 18)
      let exported = try XCTUnwrap(AnnotateExporter.renderFlatFinalImage(snapshot: snapshot))
      let cgImage = try XCTUnwrap(AnnotateExporter.bestCGImage(from: exported))
      XCTAssertEqual(cgImage.width, 272)
      XCTAssertEqual(cgImage.height, 232)
      let destination = annotation.bounds.offsetBy(dx: 18 - crop.minX, dy: 18 - crop.minY)
      assertMatchesCache(cgImage, destination: destination, cached: cached, type: type)
    }
  }

  func testПлоскоеИзображениеМакетаПослеОбрезкиБерётИсходныеКоординатыРазмытия() throws {
    let source = try makeAsymmetricSource()
    for type in [BlurType.secure, .gaussian, .pixelated] {
      let (snapshot, annotation, cached) = try makeSnapshot(source: source, type: type, padding: 0)
      let exported = try XCTUnwrap(AnnotateExporter.renderMockupFlatImage(snapshot: snapshot))
      let cgImage = try XCTUnwrap(AnnotateExporter.bestCGImage(from: exported))
      XCTAssertEqual(cgImage.width, 200)
      XCTAssertEqual(cgImage.height, 160)
      let destination = annotation.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY)
      assertMatchesCache(cgImage, destination: destination, cached: cached, type: type)
    }
  }

  private func makeSnapshot(source: NSImage, type: BlurType, padding: CGFloat) throws -> (AnnotateRenderSnapshot, AnnotationItem, CGImage) {
    let defaults = UserDefaults(suiteName: "blur-export-coordinates.\(UUID().uuidString)")!
    let state = AnnotateState(defaults: defaults)
    Self.retainedStates.append(state)
    state.loadImage(source)
    var snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let control = type == .secure ? AnnotationProperties.secureBlurControlValue(for: 10) : 3
    let effect: CGFloat
    switch type {
    case .secure: effect = 10
    case .gaussian: effect = AnnotationProperties.gaussianBlurRadius(for: control)
    default: effect = AnnotationProperties.pixelatedBlurSize(for: control)
    }
    let annotation = AnnotationItem(id: UUID(uuidString: "13A85233-6A1C-42B5-95CD-E1C066DD18F2")!,
      type: .blur(type), bounds: annotationBounds, properties: AnnotationProperties(strokeWidth: control))
    snapshot.annotations = [annotation]
    // Соль 0 повторяет сетку холста: тест сверяет координаты, а не случайность экспорта.
    snapshot.secureExportSalt = 0
    snapshot.cropRect = crop
    snapshot.padding = padding
    snapshot.backgroundStyle = .solidColor(.white)
    snapshot.cornerRadius = 0
    snapshot.shadowIntensity = 0
    snapshot.drawObjectShadow = false
    snapshot.imageAlignment = .center
    snapshot.aspectRatio = .free
    let cached = try XCTUnwrap(BlurCacheManager().getCachedBlur(for: annotation.id,
      bounds: annotation.bounds, sourceImage: source, blurType: type, effectValue: effect, quality: .export))
    return (snapshot, annotation, cached)
  }

  private func makeAsymmetricSource() throws -> NSImage {
    // Справа синий цвет, слева красный. Верх и низ различаются зелёным каналом.
    // Ошибка переноса маски в координаты холста меняет оба канала, а не только край.
    var bytes = [UInt8](repeating: 255, count: 400 * 300 * 4)
    for y in 0..<300 {
      for x in 0..<400 {
        let offset = (y * 400 + x) * 4
        let detail = x.isMultiple(of: 2) ? 8 : -8
        bytes[offset] = UInt8((x < 200 ? 220 : 30) + detail)
        bytes[offset + 1] = y < 150 ? 50 : 200
        bytes[offset + 2] = x < 200 ? 30 : 220
      }
    }
    let cgImage = try XCTUnwrap(CGImage(width: 400, height: 300, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: 400 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return NSImage(cgImage: cgImage, size: sourceSize)
  }

  private func assertMatchesCache(_ exported: CGImage, destination: CGRect, cached: CGImage, type: BlurType,
    file: StaticString = #filePath, line: UInt = #line) {
    let context = CIContext()
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let rect = destination.applying(CGAffineTransform(scaleX: 2, y: 2))
    let width = Int(rect.width)
    let height = Int(rect.height)
    var actual = [UInt8](repeating: 0, count: width * height * 4)
    var expected = actual
    context.render(CIImage(cgImage: exported), toBitmap: &actual, rowBytes: width * 4,
      bounds: rect, format: .RGBA8, colorSpace: colorSpace)
    context.render(CIImage(cgImage: cached), toBitmap: &expected, rowBytes: width * 4,
      bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
    var error = 0.0
    var samples = 0
    for y in 2..<(height - 2) {
      for x in 2..<(width - 2) {
        let pixel = (y * width + x) * 4
        XCTAssertEqual(actual[pixel + 3], 255, file: file, line: line)
        for channel in 0..<3 {
          error += abs(Double(actual[pixel + channel]) - Double(expected[pixel + channel]))
          samples += 1
        }
      }
    }
    XCTAssertLessThan(error / Double(samples), 0.5,
      "\(type) должен брать те же исходные пиксели и сетку, что и кэш до обрезки и добавления полей", file: file, line: line)
  }
}
