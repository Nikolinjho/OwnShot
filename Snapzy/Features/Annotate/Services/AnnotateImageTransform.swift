import AppKit

extension NSImage {
  var backingPixelSize: CGSize {
    guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return size }
    return CGSize(width: image.width, height: image.height)
  }

  func resizedToPixels(width: Int, height: Int, pixelScale: CGFloat? = nil) -> NSImage? {
    guard width > 0, height > 0, width <= 32768, height <= 32768,
          let image = cgImage(forProposedRect: nil, context: nil, hints: nil), size.width > 0 else { return nil }
    let scale = pixelScale ?? CGFloat(image.width) / size.width
    guard scale.isFinite, scale > 0 else { return nil }
    return transformedBitmap(image: image, width: width, height: height,
      pointSize: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)) { context in
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  func flippedImage(horizontal: Bool) -> NSImage? {
    guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return transformedBitmap(image: image, width: image.width, height: image.height, pointSize: size) { context in
      context.translateBy(x: horizontal ? CGFloat(image.width) : 0, y: horizontal ? 0 : CGFloat(image.height))
      context.scaleBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
  }

  private func transformedBitmap(image: CGImage, width: Int, height: Int, pointSize: CGSize,
    draw: (CGContext) -> Void) -> NSImage? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    draw(context)
    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: pointSize)
  }
}

nonisolated enum AnnotateResizeDimensions {
  static func initial(pixelSize: CGSize) -> (width: Int, height: Int, ratio: Double) {
    let width = max(1, Int(pixelSize.width))
    let height = max(1, Int(pixelSize.height))
    return (width, height, Double(width) / Double(height))
  }

  static func editWidth(_ width: Int, ratio: Double, locked: Bool, height: Int) -> (width: Int, height: Int) {
    (width, locked ? max(1, Int((Double(width) / ratio).rounded())) : height)
  }

  static func editHeight(_ height: Int, ratio: Double, locked: Bool, width: Int) -> (width: Int, height: Int) {
    (locked ? max(1, Int((Double(height) * ratio).rounded())) : width, height)
  }
}

nonisolated enum AnnotateResizeUnit: String, CaseIterable {
  case pixels, percent

  /// Ноль и отрицательные значения поднимаются до 1 px: у эталона 0 + Tab даёт 1 × 1 (spec-039 editor-image-size-zero).
  func pixels(value: Double, reference: Int) -> Int {
    guard value.isFinite else { return 1 }
    let result = self == .percent ? value * Double(reference) / 100 : value
    return Int(min(32769, max(1, result.rounded())))
  }

  func value(pixels: Int, reference: Int) -> Double {
    self == .percent ? Double(pixels) / Double(max(1, reference)) * 100 : Double(pixels)
  }
}

/// Состояние окна Image size, которое переживает повторное открытие в том же
/// редакторе: у эталона pixels, lockedProportions и flatten – поля контроллера ANResizeControl.
nonisolated struct AnnotateImageSizeMemory: Equatable {
  var unit: AnnotateResizeUnit = .pixels
  var locksAspectRatio = true
  var flattenAnnotations = false
}

/// Поля Image size и Ratio эталона – IntTextField: дробные значения не принимаются.
nonisolated enum AnnotateIntegerInput {
  static func formatter(minimum: Int? = nil) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.allowsFloats = false
    formatter.maximumFractionDigits = 0
    formatter.usesGroupingSeparator = false
    if let minimum { formatter.minimum = NSNumber(value: minimum) }
    return formatter
  }

  /// Целое положительное значение из строки поля; дробь, ноль и мусор дают nil.
  static func positiveInteger(from text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit), let value = Int(trimmed), value > 0 else { return nil }
    return value
  }
}

private extension Character {
  var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
