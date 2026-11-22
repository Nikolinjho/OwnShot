//
//  AnnotateBackgroundInset.swift
//  Snapzy
//
//  Inset и Auto-balance панели Background: внутренний отступ изображения внутри фона
//

import AppKit
import CoreGraphics

/// Подписи панели Background, которых нет в общих каталогах L10n.
nonisolated enum AnnotateBackgroundPanelStrings {
  static var presetsPlaceholder: String {
    L10n.string(
      "annotate.background-presets-placeholder",
      defaultValue: "Presets...",
      comment: "Placeholder of the Background presets popup when no preset is selected"
    )
  }

  static var plainColor: String {
    L10n.string(
      "annotate.background-plain-color",
      defaultValue: "Plain color",
      comment: "Section title for solid background colors"
    )
  }

  static var showLess: String {
    L10n.string(
      "annotate.background-show-less",
      defaultValue: "Show less",
      comment: "Collapses the gradient list in the Background panel"
    )
  }

  static var showMore: String {
    L10n.string(
      "annotate.background-show-more",
      defaultValue: "Show more",
      comment: "Expands the gradient list in the Background panel"
    )
  }

  static var ratio: String {
    L10n.string(
      "annotate.background-ratio-short",
      defaultValue: "Ratio",
      comment: "Label of the Background ratio popup"
    )
  }

  static var ratioAuto: String {
    L10n.string(
      "annotate.background-ratio-auto",
      defaultValue: "Auto",
      comment: "Automatic background ratio"
    )
  }

  static var defaultPreset: String {
    L10n.string(
      "annotate.background-default-preset",
      defaultValue: "Default Preset",
      comment: "Submenu of the Background presets menu that picks the preset applied to new screenshots"
    )
  }

  static var autoApplyPresetHeader: String {
    L10n.string(
      "annotate.background-auto-apply-preset",
      defaultValue: "Automatically apply preset to all screenshots:",
      comment: "Header of the Default Preset submenu in the Background presets menu"
    )
  }

  static var addNewPresetMenuItem: String {
    L10n.string(
      "annotate.background-add-new-preset-menu",
      defaultValue: "Add New Preset...",
      comment: "Last item of the Background presets menu"
    )
  }

  static var enterPresetName: String {
    L10n.string(
      "annotate.background-enter-preset-name",
      defaultValue: "Enter preset name:",
      comment: "Message of the dialog that creates a Background preset"
    )
  }

  static var savePresetChanges: String {
    L10n.string(
      "annotate.background-save-preset-changes",
      defaultValue: "Save changes to the preset",
      comment: "Tooltip of the button that saves Background changes into the selected preset"
    )
  }
}

/// Отступы карточки изображения по сторонам, в точках изображения. top – визуальный верх.
nonisolated struct AnnotateInsetEdges: Equatable, Sendable {
  var top: CGFloat
  var left: CGFloat
  var bottom: CGFloat
  var right: CGFloat

  static let zero = AnnotateInsetEdges(top: 0, left: 0, bottom: 0, right: 0)

  static func uniform(_ value: CGFloat) -> AnnotateInsetEdges {
    AnnotateInsetEdges(top: value, left: value, bottom: value, right: value)
  }

  var horizontal: CGFloat { left + right }
  var vertical: CGFloat { top + bottom }
  var minimum: CGFloat { min(top, left, bottom, right) }

  var isZero: Bool {
    max(top, left, bottom, right) <= 0.0001
  }

  /// Размер карточки: изображение плюс отступы.
  func expandedSize(_ size: CGSize) -> CGSize {
    CGSize(width: size.width + horizontal, height: size.height + vertical)
  }
}

/// Края изображения: цвет каймы и однотонные поля, которые уже есть в картинке.
nonisolated struct AnnotateImageEdgeAnalysis: Equatable, Sendable {
  /// Преобладающий цвет пикселей по периметру.
  var edgeColor: RGBAColor?
  /// Ширина однотонных полей цвета каймы по сторонам, в точках изображения.
  var margins: AnnotateInsetEdges

  static let empty = AnnotateImageEdgeAnalysis(edgeColor: nil, margins: .zero)
}

/// Итог для рендера: отступы по сторонам и заливка карточки.
nonisolated struct AnnotateBackgroundInsetLayout: Equatable, Sendable {
  var edges: AnnotateInsetEdges
  /// Цвет заливки отступа. nil – отступ прозрачный, тень и скругление остаются у изображения.
  var fillColor: RGBAColor?

  static let none = AnnotateBackgroundInsetLayout(edges: .zero, fillColor: nil)

  /// Карточка рисуется, только когда есть отступ и непрозрачная заливка.
  var drawsCard: Bool {
    guard !edges.isZero, let fillColor else { return false }
    return fillColor.alpha > 0.01
  }

  /// Скругление изображения внутри карточки: концентрично внешнему углу.
  func innerCornerRadius(outer: CGFloat) -> CGFloat {
    guard drawsCard else { return outer }
    return max(outer - edges.minimum, 0)
  }
}

/// Inset у CleanShot X уменьшает изображение внутри фона и заливает освободившееся место
/// цветом края картинки. Auto-balance выравнивает поля: стороны, где контент упирается
/// в край, получают добавку до ширины самого широкого собственного поля картинки.
nonisolated enum AnnotateBackgroundInset {
  /// Диапазон слайдера Inset эталона.
  static let range: ClosedRange<CGFloat> = 0 ... 100
  /// Собственное поле картинки учитывается не шире этой доли стороны.
  static let maximumMarginFraction: CGFloat = 0.25
  /// Допуск по каналу (0…255), в пределах которого пиксель считается цветом каймы.
  static let colorTolerance = 12
  /// Длинная сторона уменьшенной копии для анализа.
  static let analysisMaxDimension: CGFloat = 320

  static func clampedInset(_ value: CGFloat) -> CGFloat {
    min(max(value, range.lowerBound), range.upperBound)
  }

  /// Отступы по сторонам для заданного Inset и Auto-balance.
  static func edges(
    inset: CGFloat,
    autoBalance: Bool,
    margins: AnnotateInsetEdges
  ) -> AnnotateInsetEdges {
    let base = clampedInset(inset)
    guard autoBalance else { return .uniform(base) }
    let target = max(margins.top, margins.left, margins.bottom, margins.right)
    return AnnotateInsetEdges(
      top: base + max(target - margins.top, 0),
      left: base + max(target - margins.left, 0),
      bottom: base + max(target - margins.bottom, 0),
      right: base + max(target - margins.right, 0)
    )
  }

  static func layout(
    inset: CGFloat,
    autoBalance: Bool,
    analysis: AnnotateImageEdgeAnalysis
  ) -> AnnotateBackgroundInsetLayout {
    let edges = edges(inset: inset, autoBalance: autoBalance, margins: analysis.margins)
    guard !edges.isZero else { return .none }
    return AnnotateBackgroundInsetLayout(edges: edges, fillColor: analysis.edgeColor)
  }

  /// Анализ видимой части изображения. visibleBounds – в координатах изображения (y вверх).
  static func analyze(image: NSImage, visibleBounds: CGRect) -> AnnotateImageEdgeAnalysis {
    let imageBounds = CGRect(origin: .zero, size: image.size)
    let visible = visibleBounds.standardized.intersection(imageBounds)
    guard !visible.isNull, visible.width >= 1, visible.height >= 1,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return .empty
    }

    let scaleX = CGFloat(cgImage.width) / max(image.size.width, 1)
    let scaleY = CGFloat(cgImage.height) / max(image.size.height, 1)
    // Пиксели CGImage идут сверху вниз, координаты изображения – снизу вверх.
    let pixelRect = CGRect(
      x: floor(visible.minX * scaleX),
      y: floor((image.size.height - visible.maxY) * scaleY),
      width: ceil(visible.width * scaleX),
      height: ceil(visible.height * scaleY)
    )
    .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    .integral
    guard !pixelRect.isNull, !pixelRect.isEmpty,
          let cropped = cgImage.cropping(to: pixelRect) else {
      return .empty
    }
    return analyze(cgImage: cropped, pointSize: visible.size)
  }

  /// Анализ готового CGImage, pointSize – его размер в точках изображения.
  static func analyze(cgImage: CGImage, pointSize: CGSize) -> AnnotateImageEdgeAnalysis {
    guard cgImage.width > 0, cgImage.height > 0 else { return .empty }

    let longSide = CGFloat(max(cgImage.width, cgImage.height))
    let downscale = min(1, analysisMaxDimension / longSide)
    let width = max(1, Int((CGFloat(cgImage.width) * downscale).rounded()))
    let height = max(1, Int((CGFloat(cgImage.height) * downscale).rounded()))
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.interpolationQuality = .low
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard didDraw else { return .empty }

    // Строка 0 буфера – верх изображения.
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
      let offset = y * bytesPerRow + x * 4
      return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
    }

    // Цвет каймы: самая частая корзина цветов по периметру, затем среднее внутри неё.
    var buckets: [Int: (count: Int, r: Int, g: Int, b: Int, a: Int)] = [:]
    func addBorderPixel(_ x: Int, _ y: Int) {
      let (r, g, b, a) = pixel(x, y)
      let key = (r >> 4) << 12 | (g >> 4) << 8 | (b >> 4) << 4 | (a >> 4)
      var entry = buckets[key] ?? (0, 0, 0, 0, 0)
      entry.count += 1
      entry.r += r
      entry.g += g
      entry.b += b
      entry.a += a
      buckets[key] = entry
    }
    for x in 0 ..< width {
      addBorderPixel(x, 0)
      if height > 1 { addBorderPixel(x, height - 1) }
    }
    if height > 2 {
      for y in 1 ..< height - 1 {
        addBorderPixel(0, y)
        if width > 1 { addBorderPixel(width - 1, y) }
      }
    }
    guard let dominant = buckets.values.max(by: { $0.count < $1.count }), dominant.count > 0 else {
      return .empty
    }
    let edge = (
      dominant.r / dominant.count,
      dominant.g / dominant.count,
      dominant.b / dominant.count,
      dominant.a / dominant.count
    )

    func matchesEdge(_ x: Int, _ y: Int) -> Bool {
      let (r, g, b, a) = pixel(x, y)
      return abs(r - edge.0) <= colorTolerance
        && abs(g - edge.1) <= colorTolerance
        && abs(b - edge.2) <= colorTolerance
        && abs(a - edge.3) <= colorTolerance
    }
    func rowMatches(_ y: Int) -> Bool {
      (0 ..< width).allSatisfy { matchesEdge($0, y) }
    }
    func columnMatches(_ x: Int) -> Bool {
      (0 ..< height).allSatisfy { matchesEdge(x, $0) }
    }

    let maxRows = Int(CGFloat(height) * maximumMarginFraction)
    let maxColumns = Int(CGFloat(width) * maximumMarginFraction)
    var topRows = 0
    while topRows < maxRows, rowMatches(topRows) { topRows += 1 }
    var bottomRows = 0
    while bottomRows < maxRows, rowMatches(height - 1 - bottomRows) { bottomRows += 1 }
    var leftColumns = 0
    while leftColumns < maxColumns, columnMatches(leftColumns) { leftColumns += 1 }
    var rightColumns = 0
    while rightColumns < maxColumns, columnMatches(width - 1 - rightColumns) { rightColumns += 1 }

    let pointsPerColumn = pointSize.width / CGFloat(width)
    let pointsPerRow = pointSize.height / CGFloat(height)
    let margins = AnnotateInsetEdges(
      top: CGFloat(topRows) * pointsPerRow,
      left: CGFloat(leftColumns) * pointsPerColumn,
      bottom: CGFloat(bottomRows) * pointsPerRow,
      right: CGFloat(rightColumns) * pointsPerColumn
    )

    // Буфер premultiplied: возвращаем цвет без домножения на альфу.
    let alpha = Double(edge.3) / 255
    let edgeColor: RGBAColor
    if alpha > 0 {
      edgeColor = RGBAColor(
        red: Double(edge.0) / 255 / alpha,
        green: Double(edge.1) / 255 / alpha,
        blue: Double(edge.2) / 255 / alpha,
        alpha: alpha
      )
    } else {
      edgeColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
    return AnnotateImageEdgeAnalysis(edgeColor: edgeColor, margins: margins)
  }
}

extension RGBAColor {
  /// sRGB CGColor для заливки отступа при экспорте.
  nonisolated var cgColor: CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }
}
