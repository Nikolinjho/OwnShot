import CoreGraphics
import Foundation
import Testing
@testable import Snapzy

struct OwnShotCaptureOutputTests {
  private func image(width: Int = 8, height: Int = 6, alpha: CGFloat = 0.5,
    space: CFString = CGColorSpace.displayP3, rgb: [CGFloat] = [1, 0, 0]) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: space)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  @Test("Выключенные настройки сохраняют исходный растр и профиль")
  func disabledOptionsPreserveOriginalImageAndProfile() throws {
    let source = try image()
    let result = try #require(OwnShotCaptureOutput.process(source, scaleFactor: 2, options: .init()))
    #expect(result.image === source)
    #expect(result.image.colorSpace?.name == CGColorSpace.displayP3)
    #expect(result.scaleFactor == 2)
  }

  @Test("Внутренняя рамка повторяет оба нативных фона при плотности 1× и 2×",
    arguments: [1, 2], [false, true])
  func nativeInnerBorder(scale: Int, white: Bool) throws {
    let rgb: [CGFloat] = white ? [1, 1, 1] : [120 / 255, 130 / 255, 140 / 255]
    let source = try image(width: 10, height: 8, alpha: 1, space: CGColorSpace.sRGB, rgb: rgb)
    let result = try #require(OwnShotCaptureOutput.process(source, scaleFactor: CGFloat(scale),
      options: .init(addPixelBorder: true)))
    #expect(result.image.width == 10)
    #expect(result.image.height == 8)
    #expect(result.scaleFactor == CGFloat(scale))
    let pixels = try srgbPixels(result.image)
    let input = try srgbPixels(source)
    // build/cap044-native/ref-border-{on,on-1x,white-on-1x}.png:
    // размеры прежние, ширина внутри 1/2 px; углы не получают повторную alpha.
    let expectedEdge: [UInt8] = white ? [191, 191, 191, 255] : [124, 129, 134, 255]
    var incorrectEdgePixels = 0
    var changedInteriorPixels = 0
    for y in 0..<8 {
      for x in 0..<10 {
        guard x < result.image.width, y < result.image.height else { continue }
        let index = (y * result.image.width + x) * 4
        let actual = Array(pixels[index..<(index + 4)])
        if min(x, y, 9 - x, 7 - y) < scale {
          if actual != expectedEdge { incorrectEdgePixels += 1 }
        } else {
          let original = (y * 10 + x) * 4
          if actual != Array(input[original..<(original + 4)]) { changedInteriorPixels += 1 }
        }
      }
    }
    #expect(incorrectEdgePixels == 0)
    #expect(changedInteriorPixels == 0)
  }

  @Test("Уменьшение до 1× выполняется перед рамкой без внешних полей")
  func downsamplingPrecedesOneOutputPixelBorder() throws {
    let result = try #require(OwnShotCaptureOutput.process(try image(), scaleFactor: 2,
      options: .init(convertToSRGB: true, scaleRetinaTo1x: true, addPixelBorder: true)))
    #expect(result.image.width == 4)
    #expect(result.image.height == 3)
    #expect(result.scaleFactor == 1)
    #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
    let pixels = try srgbPixels(result.image)
    // При исходных 2× второй ряд уже interior: рамка должна использовать итоговый 1×.
    let alpha = Int(pixels[(result.image.width + 1) * 4 + 3])
    #expect(abs(alpha - 128) <= 1)
  }

  @Test("Исходник 1× сохраняет размеры и плотность, рамка выводится в sRGB")
  func nativeOneXIsNotReducedAndBorderDoesNotChangeScale() throws {
    let result = try #require(OwnShotCaptureOutput.process(try image(), scaleFactor: 1,
      options: .init(scaleRetinaTo1x: true, addPixelBorder: true)))
    #expect(result.image.width == 8)
    #expect(result.image.height == 6)
    #expect(result.scaleFactor == 1)
    #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
  }

  @Test("Дробная плотность сохраняется, внутренняя рамка симметрична и не меняет центр",
    arguments: [CGFloat(0.5), 1.25, 1.5])
  func fractionalScalePreservesDensityAndSymmetry(scale: CGFloat) throws {
    let source = try image(width: 20, height: 16, alpha: 1, space: CGColorSpace.sRGB,
      rgb: [120 / 255, 130 / 255, 140 / 255])
    let result = try #require(OwnShotCaptureOutput.process(source, scaleFactor: scale,
      options: .init(addPixelBorder: true)))
    #expect(result.image.width == 20)
    #expect(result.image.height == 16)
    #expect(result.scaleFactor == scale)
    let pixels = try srgbPixels(result.image)
    var asymmetricPixels = 0
    for y in 0..<16 {
      for x in 0..<20 {
        let index = (y * result.image.width + x) * 4
        let horizontal = (y * result.image.width + 19 - x) * 4
        let vertical = ((15 - y) * result.image.width + x) * 4
        var isAsymmetric = false
        for channel in 0..<4 {
          let horizontalDelta = abs(Int(pixels[index + channel]) - Int(pixels[horizontal + channel]))
          let verticalDelta = abs(Int(pixels[index + channel]) - Int(pixels[vertical + channel]))
          if horizontalDelta > 1 || verticalDelta > 1 { isAsymmetric = true }
        }
        if isAsymmetric { asymmetricPixels += 1 }
      }
    }
    #expect(asymmetricPixels == 0)
    let center = (8 * result.image.width + 10) * 4
    #expect(Array(pixels[center..<(center + 4)]) == [120, 130, 140, 255])
  }

  @Test("Полупрозрачная рамка компонуется source-over один раз, не меняя прозрачный interior",
    arguments: [CGFloat(0), 0.5])
  func transparentAndHalfAlphaEdges(alpha: CGFloat) throws {
    let source = try image(alpha: alpha, space: CGColorSpace.sRGB)
    let result = try #require(OwnShotCaptureOutput.process(source, scaleFactor: 1,
      options: .init(addPixelBorder: true)))
    let output = try srgbPixels(result.image)
    let original = try srgbPixels(source)
    // Premultiplied RGBA8: gray 0,5 × alpha 0,5 даёт [64,64,64,128].
    // Поверх half-alpha red [128,0,0,128] source-over даёт [128,64,64,192].
    let expectedEdge: [UInt8] = alpha == 0 ? [64, 64, 64, 128] : [128, 64, 64, 192]
    #expect(Array(output[0..<4]) == expectedEdge)
    let side = 3 * 4
    #expect(Array(output[side..<(side + 4)]) == expectedEdge)
    let interior = (result.image.width + 1) * 4
    #expect(Array(output[interior..<(interior + 4)]) == Array(original[interior..<(interior + 4)]))
  }

  @Test("Некорректная плотность безопасно заменяется на 1× перед рамкой и записью DPI",
    arguments: [CGFloat.nan, .infinity, 0, -1])
  func invalidScaleUsesOneX(scale: CGFloat) throws {
    let result = try #require(OwnShotCaptureOutput.process(try image(alpha: 1), scaleFactor: scale,
      options: .init(addPixelBorder: true)))
    #expect(result.scaleFactor == 1)
    #expect(result.image.width == 8)
    #expect(result.image.height == 6)
    let pixels = try srgbPixels(result.image)
    #expect(pixels[3] == 255)
  }

  @Test("Выходные настройки выключены по умолчанию и читают прежние ключи")
  func defaultsAreOptInAndUseExportKeys() throws {
    let name = "OwnShotCaptureOutputTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(OwnShotCaptureOutputOptions(defaults: defaults).convertToSRGB == false)
    #expect(OwnShotCaptureOutputOptions(defaults: defaults).scaleRetinaTo1x == false)
    #expect(OwnShotCaptureOutputOptions(defaults: defaults).addPixelBorder == false)
    defaults.set(true, forKey: "ownshot.capture.export.convertToSRGB")
    defaults.set(true, forKey: "ownshot.capture.export.scaleRetinaTo1x")
    defaults.set(true, forKey: "ownshot.capture.export.addPixelBorder")
    let options = OwnShotCaptureOutputOptions(defaults: defaults)
    #expect(options.convertToSRGB && options.scaleRetinaTo1x && options.addPixelBorder)
  }

  private func srgbPixels(_ image: CGImage) throws -> [UInt8] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
  }

}
