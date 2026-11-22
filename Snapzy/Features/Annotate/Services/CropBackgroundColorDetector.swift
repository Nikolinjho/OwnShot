//
//  CropBackgroundColorDetector.swift
//  Snapzy
//
//  Цвет фона снимка по его краю: им эталон заливает рамку Crop, вытянутую
//  за пределы изображения (ANCropController.initColor, ANN-792).
//

import AppKit
import CoreGraphics

nonisolated enum CropBackgroundColorDetector {
  /// Доля пикселей края, которую должен занимать преобладающий цвет.
  static let minimumDominantShare: Double = 0.25
  /// Шаг группировки цвета: оттенки в пределах 8 уровней канала считаются одним цветом.
  private static let bucketShift: UInt8 = 3

  /// Преобладающий цвет внешнего ряда пикселей снимка (sRGB) или nil, если край
  /// пёстрый либо прозрачный – тогда расширение остаётся прозрачным.
  static func dominantEdgeColor(of image: CGImage) -> NSColor? {
    let width = image.width, height = image.height
    guard width > 0, height > 0,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }

    var edge: [Int] = []
    edge.reserveCapacity(2 * (width + height))
    for x in 0..<width {
      edge.append(x)
      if height > 1 { edge.append((height - 1) * width + x) }
    }
    if height > 2 {
      for y in 1..<(height - 1) {
        edge.append(y * width)
        if width > 1 { edge.append(y * width + width - 1) }
      }
    }

    var buckets: [UInt32: (count: Int, r: Int, g: Int, b: Int)] = [:]
    for index in edge {
      let offset = index * 4
      // Прозрачный край не даёт цвета фона: заливка осталась бы видна сквозь снимок.
      guard pixels[offset + 3] >= 250 else { return nil }
      let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2]
      let key = UInt32(r >> bucketShift) << 16 | UInt32(g >> bucketShift) << 8 | UInt32(b >> bucketShift)
      var entry = buckets[key] ?? (0, 0, 0, 0)
      entry.count += 1
      entry.r += Int(r)
      entry.g += Int(g)
      entry.b += Int(b)
      buckets[key] = entry
    }
    guard let dominant = buckets.values.max(by: { $0.count < $1.count }),
          Double(dominant.count) / Double(edge.count) >= minimumDominantShare else { return nil }
    let count = Double(dominant.count)
    return NSColor(
      srgbRed: CGFloat((Double(dominant.r) / count).rounded()) / 255,
      green: CGFloat((Double(dominant.g) / count).rounded()) / 255,
      blue: CGFloat((Double(dominant.b) / count).rounded()) / 255,
      alpha: 1
    )
  }
}
