import CoreGraphics
import Foundation

/// Настройки применяются один раз, при первом сохранении готового снимка.
nonisolated struct OwnShotCaptureOutputOptions {
  var convertToSRGB = false
  var scaleRetinaTo1x = false
  var addPixelBorder = false

  init(convertToSRGB: Bool = false, scaleRetinaTo1x: Bool = false, addPixelBorder: Bool = false) {
    self.convertToSRGB = convertToSRGB
    self.scaleRetinaTo1x = scaleRetinaTo1x
    self.addPixelBorder = addPixelBorder
  }

  init(defaults: UserDefaults) {
    convertToSRGB = defaults.bool(forKey: "ownshot.capture.export.convertToSRGB")
    scaleRetinaTo1x = defaults.bool(forKey: "ownshot.capture.export.scaleRetinaTo1x")
    addPixelBorder = defaults.bool(forKey: "ownshot.capture.export.addPixelBorder")
  }
}

nonisolated enum OwnShotCaptureOutput {
  struct Result {
    let image: CGImage
    let scaleFactor: CGFloat?
  }

  static func process(_ image: CGImage, scaleFactor: CGFloat?, options: OwnShotCaptureOutputOptions) -> Result? {
    // Плотность результата, а не дисплея: после Scale Retina to 1x рамка тоже 1×.
    // Не допускаем нечисловую/нулевую плотность в геометрии и последующей записи DPI.
    let sourceScale = scaleFactor.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
    let downsample = options.scaleRetinaTo1x && sourceScale > 1
    let effectiveScale: CGFloat = downsample ? 1 : sourceScale
    let reportedScale = scaleFactor.map { _ in effectiveScale }
    guard options.convertToSRGB || downsample || options.addPixelBorder else {
      return Result(image: image, scaleFactor: reportedScale)
    }
    let resizeScale = downsample ? sourceScale : 1
    let width = max(1, Int((CGFloat(image.width) / resizeScale).rounded()))
    let height = max(1, Int((CGFloat(image.height) / resizeScale).rounded()))
    // Нативные PNG с рамкой экспортируются в sRGB даже при исходном Display P3.
    guard let space = options.convertToSRGB || options.addPixelBorder
      ? CGColorSpace(name: CGColorSpace.sRGB) : image.colorSpace,
          let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
    if options.addPixelBorder {
      // CAP-044: внутренние 1/2 px при 1×/2×, без изменения размеров.
      // Gray [120,130,140] → [124,129,134], white → [191,191,191].
      // Одно кольцо исключает повторное наложение полупрозрачного цвета в углах.
      let thickness = min(effectiveScale, CGFloat(min(width, height)) / 2)
      context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))
      context.addRect(bounds)
      let interior = bounds.insetBy(dx: thickness, dy: thickness)
      if interior.width > 0 && interior.height > 0 { context.addRect(interior) }
      context.fillPath(using: .evenOdd)
    }
    guard let output = context.makeImage() else { return nil }
    return Result(image: output, scaleFactor: reportedScale)
  }
}
