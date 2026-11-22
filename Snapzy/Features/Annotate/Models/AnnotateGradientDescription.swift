//
//  AnnotateGradientDescription.swift
//  Snapzy
//
//  Числовое описание градиентов фона и их растеризация для превью и экспорта
//

import CoreGraphics
import Foundation
import os

/// Градиент фона в пространстве исходной картинки эталона: x вправо от 0 до aspect, y вниз от 0 до 1.
/// На холст и в плитку ложится как aspect fill с центровкой, так же как картинка в CleanShot.
/// Формулы совпадают с docs/parity-spec/scripts/measure-gradients.py, по которому подобраны числа.
nonisolated struct GradientDescription: Equatable, Sendable {
  nonisolated enum Shape: Equatable, Sendable {
    /// Линейный: угол в градусах от оси x по часовой стрелке (y вниз), равномерные стопы
    /// от угла, где проекция минимальна, до противоположного.
    case linear(angle: Double, stops: [Int])
    /// Радиальный: центр в долях ширины и высоты, равномерные стопы от центра до дальнего угла.
    case radial(centerX: Double, centerY: Double, stops: [Int])
    /// Сетка size × size узлов по строкам сверху вниз, между узлами тензорный Catmull-Rom.
    case mesh(size: Int, nodes: [Int])
  }

  /// Соотношение сторон исходной картинки, ширина к высоте.
  let aspect: Double
  let shape: Shape

  static func linear(aspect: Double, angle: Double, stops: [Int]) -> Self {
    Self(aspect: aspect, shape: .linear(angle: angle, stops: stops))
  }

  static func radial(aspect: Double, centerX: Double, centerY: Double, stops: [Int]) -> Self {
    Self(aspect: aspect, shape: .radial(centerX: centerX, centerY: centerY, stops: stops))
  }

  static func mesh(aspect: Double, size: Int, nodes: [Int]) -> Self {
    Self(aspect: aspect, shape: .mesh(size: size, nodes: nodes))
  }

  var isValid: Bool {
    guard aspect > 0 else { return false }
    switch shape {
    case .linear(_, let stops), .radial(_, _, let stops):
      return stops.count >= 2
    case .mesh(let size, let nodes):
      return size >= 2 && nodes.count == size * size
    }
  }

  /// Цвет в точке (u, v) в долях картинки, компоненты sRGB 0…1.
  func color(u: Double, v: Double) -> SIMD3<Double> {
    switch shape {
    case .linear(let angle, let stops):
      let radians = angle * .pi / 180
      let dx = cos(radians)
      let dy = sin(radians)
      let corners = [0, aspect * dx, dy, aspect * dx + dy]
      let low = corners.min() ?? 0
      let high = corners.max() ?? 1
      let t = (u * aspect * dx + v * dy - low) / max(high - low, .ulpOfOne)
      return Self.profile(stops, at: t)

    case .radial(let centerX, let centerY, let stops):
      var far = 0.0
      for x in [0.0, 1.0] {
        for y in [0.0, 1.0] {
          far = max(far, hypot((x - centerX) * aspect, y - centerY))
        }
      }
      let t = hypot((u - centerX) * aspect, v - centerY) / max(far, .ulpOfOne)
      return Self.profile(stops, at: t)

    case .mesh(let size, let nodes):
      let wu = Self.catmullRomWeights(u, count: size)
      let wv = Self.catmullRomWeights(v, count: size)
      var result = SIMD3<Double>()
      for (row, rowWeight) in wv {
        for (column, columnWeight) in wu {
          result += Self.rgb(nodes[row * size + column]) * (rowWeight * columnWeight)
        }
      }
      return Self.clamped(result)
    }
  }

  // MARK: - Интерполяция

  private static func profile(_ stops: [Int], at t: Double) -> SIMD3<Double> {
    let s = min(1, max(0, t)) * Double(stops.count - 1)
    let index = min(stops.count - 2, Int(s))
    let fraction = s - Double(index)
    return rgb(stops[index]) * (1 - fraction) + rgb(stops[index + 1]) * fraction
  }

  /// Веса узлов Catmull-Rom для координаты 0…1, узлы равномерно, за краями повторяется крайний узел.
  static func catmullRomWeights(_ t: Double, count: Int) -> [(index: Int, weight: Double)] {
    let s = min(1, max(0, t)) * Double(count - 1)
    let index = min(count - 2, Int(s))
    let f = s - Double(index)
    guard count > 2 else {
      return [(0, 1 - f), (1, f)]
    }
    let f2 = f * f
    let f3 = f2 * f
    let weights = [
      (-f3 + 2 * f2 - f) / 2,
      (3 * f3 - 5 * f2 + 2) / 2,
      (-3 * f3 + 4 * f2 + f) / 2,
      (f3 - f2) / 2,
    ]
    var merged: [(index: Int, weight: Double)] = []
    for (offset, weight) in weights.enumerated() {
      let node = min(count - 1, max(0, index - 1 + offset))
      if let last = merged.indices.last, merged[last].index == node {
        merged[last].weight += weight
      } else {
        merged.append((node, weight))
      }
    }
    return merged
  }

  static func rgb(_ hex: Int) -> SIMD3<Double> {
    SIMD3(
      Double((hex >> 16) & 0xFF) / 255,
      Double((hex >> 8) & 0xFF) / 255,
      Double(hex & 0xFF) / 255
    )
  }

  private static func clamped(_ value: SIMD3<Double>) -> SIMD3<Double> {
    value.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
  }
}

/// Растеризует описание градиента в sRGB-картинку с пропорциями исходника.
/// Одна и та же картинка рисуется в плитке сайдбара, на холсте и в экспорте, поэтому они совпадают.
nonisolated enum GradientPresetRasterizer {
  /// Длинная сторона растра. Градиенты гладкие, при увеличении интерполяция не даёт ступенек.
  static let longSide = 512

  private static let cache = OSAllocatedUnfairLock<[GradientPreset: CGImage]>(initialState: [:])

  static func image(for preset: GradientPreset) -> CGImage? {
    if let cached = cache.withLock({ $0[preset] }) {
      return cached
    }
    guard let image = render(preset.gradient) else { return nil }
    cache.withLock { $0[preset] = image }
    return image
  }

  /// Рисует пресет в прямоугольник CG-контекста с осью y вверх как aspect fill.
  static func draw(_ preset: GradientPreset, in context: CGContext, rect: CGRect) {
    guard let image = image(for: preset), rect.width > 0, rect.height > 0 else { return }
    let imageAspect = CGFloat(image.width) / CGFloat(image.height)
    var target = rect
    if rect.width / rect.height > imageAspect {
      target.size.height = rect.width / imageAspect
      target.origin.y = rect.midY - target.height / 2
    } else {
      target.size.width = rect.height * imageAspect
      target.origin.x = rect.midX - target.width / 2
    }
    context.saveGState()
    context.clip(to: rect)
    context.interpolationQuality = .high
    context.draw(image, in: target)
    context.restoreGState()
  }

  static func render(_ description: GradientDescription, longSide: Int = longSide) -> CGImage? {
    guard description.isValid else { return nil }
    let width: Int
    let height: Int
    if description.aspect >= 1 {
      width = longSide
      height = max(1, Int((Double(longSide) / description.aspect).rounded()))
    } else {
      height = longSide
      width = max(1, Int((Double(longSide) * description.aspect).rounded()))
    }

    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    if case .mesh(let size, let nodes) = description.shape {
      fillMesh(size: size, nodes: nodes, width: width, height: height, into: &pixels)
    } else {
      for y in 0..<height {
        let v = (Double(y) + 0.5) / Double(height)
        for x in 0..<width {
          let u = (Double(x) + 0.5) / Double(width)
          store(description.color(u: u, v: v), at: (y * width + x) * 4, in: &pixels)
        }
      }
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  }

  /// Сетка считается раздельно: сначала строки узлов по x, потом по y. Результат тот же,
  /// что у GradientDescription.color(u:v:), но без пересчёта весов в каждом пикселе.
  private static func fillMesh(size: Int, nodes: [Int], width: Int, height: Int, into pixels: inout [UInt8]) {
    let colors = nodes.map(GradientDescription.rgb)
    var rows = [SIMD3<Double>](repeating: SIMD3(), count: size * width)
    for x in 0..<width {
      let weights = GradientDescription.catmullRomWeights((Double(x) + 0.5) / Double(width), count: size)
      for row in 0..<size {
        var sum = SIMD3<Double>()
        for (column, weight) in weights {
          sum += colors[row * size + column] * weight
        }
        rows[row * width + x] = sum
      }
    }
    for y in 0..<height {
      let weights = GradientDescription.catmullRomWeights((Double(y) + 0.5) / Double(height), count: size)
      for x in 0..<width {
        var sum = SIMD3<Double>()
        for (row, weight) in weights {
          sum += rows[row * width + x] * weight
        }
        store(sum, at: (y * width + x) * 4, in: &pixels)
      }
    }
  }

  private static func store(_ color: SIMD3<Double>, at offset: Int, in pixels: inout [UInt8]) {
    let clamped = color.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
    pixels[offset] = UInt8((clamped.x * 255).rounded())
    pixels[offset + 1] = UInt8((clamped.y * 255).rounded())
    pixels[offset + 2] = UInt8((clamped.z * 255).rounded())
  }
}
