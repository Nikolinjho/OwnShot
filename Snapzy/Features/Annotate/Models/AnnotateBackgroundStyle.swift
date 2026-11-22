//
//  AnnotateBackgroundStyle.swift
//  Snapzy
//
//  Background style types and presets for annotation canvas
//

import Foundation
import SwiftUI

/// Background style types
nonisolated enum BackgroundStyle: Equatable, Sendable {
  case none
  case gradient(GradientPreset)
  case wallpaper(URL)
  case blurred(URL)
  case solidColor(Color)

  var supportsBlurredBackgroundEffect: Bool {
    switch self {
    case .wallpaper, .blurred, .solidColor:
      true
    case .none, .gradient:
      false
    }
  }

  var blurredEffectImageURL: URL? {
    switch self {
    case .wallpaper(let url), .blurred(let url):
      url
    case .none, .gradient, .solidColor:
      nil
    }
  }
}

/// Blur presets for applying a soft effect to the selected background layer.
nonisolated enum BlurredBackgroundEffect: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
  case soft
  case frosted
  case vivid
  case dim

  var id: String {
    rawValue
  }

  /// Плитки секции Blurred: в эталоне их три. vivid остаётся в модели,
  /// чтобы сохранённые пресеты и проекты с ним по-прежнему рендерились.
  static let sidebarEffects: [BlurredBackgroundEffect] = [.soft, .frosted, .dim]

  var displayName: String {
    switch self {
    case .soft:
      L10n.AnnotateUI.blurredBackgroundSoft
    case .frosted:
      L10n.AnnotateUI.blurredBackgroundFrosted
    case .vivid:
      L10n.AnnotateUI.blurredBackgroundVivid
    case .dim:
      L10n.AnnotateUI.blurredBackgroundDim
    }
  }

  var blurRadius: CGFloat {
    switch self {
    case .soft:
      18
    case .frosted:
      30
    case .vivid:
      22
    case .dim:
      24
    }
  }

  var saturation: Double {
    switch self {
    case .soft:
      1.0
    case .frosted:
      0.85
    case .vivid:
      1.35
    case .dim:
      0.9
    }
  }

  var brightness: Double {
    switch self {
    case .soft:
      0
    case .frosted:
      0.06
    case .vivid:
      0.02
    case .dim:
      -0.06
    }
  }

  var tintColor: Color {
    switch self {
    case .soft, .frosted:
      .white
    case .vivid:
      .orange
    case .dim:
      .black
    }
  }

  var tintOpacity: Double {
    switch self {
    case .soft:
      0.08
    case .frosted:
      0.28
    case .vivid:
      0.10
    case .dim:
      0.24
    }
  }
}

/// Плитки сетки Gradients эталона, bg1…bg20 слева направо, сверху вниз (9–20 – ANN-519…530).
/// rawValue первых 8 плиток остались от Snapzy: на них ссылаются сохранённые пресеты холста.
/// Числовые описания градиентов – в AnnotateGradientPresetData.swift.
nonisolated enum GradientPreset: String, CaseIterable, Identifiable, Sendable {
  case pinkOrange
  case bluePurple
  case greenBlue
  case orangeRed
  case purplePink
  case blueGreen
  case yellowOrange
  case cyanBlue
  case skyLilac
  case midnightIndigo
  case deepSeaSand
  case periwinkleRose
  case lavenderMist
  case plumCrimson
  case nightViolet
  case violetPink
  case scarletCream
  case blueApricot
  case magentaWine
  case roseApricot

  var id: String {
    rawValue
  }
}

/// Параметры холста, которые эталон выставляет при выборе градиента (ANN-763):
/// один клик по первой плитке из None дал Padding 63, Shadow 28, Corners 15, Inset 0.
nonisolated enum AnnotateGradientCanvasDefaults {
  static let padding: CGFloat = 63
  /// Слайдер Shadow в OwnShot работает в диапазоне 0…1, эталонные 28 из 100 – это 0.28.
  static let shadowIntensity: CGFloat = 0.28
  static let cornerRadius: CGFloat = 15
}

/// Палитра Plain color эталона: сетка 2 × 9 (ANN-535…552).
/// Цвета сняты пипеткой в sRGB с evidence/spec-043-live/background-open.png (центр swatch).
/// Точные NSColor эталона не измерены, это приближение по скриншоту.
nonisolated enum AnnotateBackgroundPalette {
  /// Первый ряд: 8 насыщенных цветов, девятая ячейка – прозрачный фон (checkerboard).
  static let primaryRow: [Color] = [
    0x121212, 0xFFFFFF, 0xE33345, 0xF78521, 0xF2A81A, 0x178F51, 0x0D8CE8, 0x8A38F5,
  ].map(color(hex:))

  /// Второй ряд: 8 светлых оттенков, девятая ячейка – кнопка своего цвета.
  static let secondaryRow: [Color] = [
    0x383838, 0xEBEBEB, 0xFABDB5, 0xFFC570, 0xFADE8F, 0xA0E8BB, 0xA9D6F9, 0xD7B5FA,
  ].map(color(hex:))

  /// Прозрачный фон: холст с отступами без заливки.
  static let transparent = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0)

  static func color(hex: Int) -> Color {
    Color(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}

/// Image alignment within background
nonisolated enum ImageAlignment: String, CaseIterable, Sendable {
  case topLeft, top, topRight
  case left, center, right
  case bottomLeft, bottom, bottomRight
}

/// Predefined wallpaper presets (abstract gradient patterns)
nonisolated enum WallpaperPreset: String, CaseIterable, Identifiable {
  case oceanBreeze
  case sunsetGlow
  case forestMist

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .oceanBreeze: L10n.AnnotateContext.wallpaperOcean
    case .sunsetGlow: L10n.AnnotateContext.wallpaperSunset
    case .forestMist: L10n.AnnotateContext.wallpaperForest
    }
  }

  var colors: [Color] {
    switch self {
    case .oceanBreeze: [
        Color(red: 0.1, green: 0.4, blue: 0.6),
        Color(red: 0.2, green: 0.6, blue: 0.8),
        Color(red: 0.4, green: 0.8, blue: 0.9),
      ]
    case .sunsetGlow: [
        Color(red: 0.9, green: 0.3, blue: 0.2),
        Color(red: 0.95, green: 0.5, blue: 0.3),
        Color(red: 1.0, green: 0.7, blue: 0.4),
      ]
    case .forestMist: [
        Color(red: 0.1, green: 0.3, blue: 0.2),
        Color(red: 0.2, green: 0.5, blue: 0.3),
        Color(red: 0.4, green: 0.7, blue: 0.5),
      ]
    }
  }

  var gradient: LinearGradient {
    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }
}

/// Orientation for fixed aspect ratio presets.
nonisolated enum AspectRatioOrientation: String, CaseIterable, Identifiable, Sendable {
  case horizontal
  case vertical

  var id: String {
    rawValue
  }

  var systemImageName: String {
    switch self {
    case .horizontal:
      "rectangle"
    case .vertical:
      "rectangle.portrait"
    }
  }
}

/// Aspect ratio options for export.
nonisolated enum AspectRatioOption: String, CaseIterable, Identifiable, Sendable {
  case auto = "Auto"
  case free = "Free"
  case square = "1:1"
  case ratio4x3 = "4:3"
  case ratio3x2 = "3:2"
  case ratio16x9 = "16:9"
  // Добавлен для popup Ratio эталона, rawValue новый, старые сборки прочитают его как Auto.
  case ratio5x4 = "5:4"

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .auto:
      L10n.Common.original
    case .free:
      L10n.Common.free
    case .square, .ratio4x3, .ratio16x9, .ratio3x2, .ratio5x4:
      rawValue
    }
  }

  var supportsOrientation: Bool {
    switch self {
    case .ratio4x3, .ratio16x9, .ratio3x2, .ratio5x4:
      true
    case .auto, .free, .square:
      false
    }
  }

  func effectiveDisplayName(orientation: AspectRatioOrientation) -> String {
    guard orientation == .vertical else {
      return displayName
    }

    switch self {
    case .ratio4x3:
      return "3:4"
    case .ratio3x2:
      return "2:3"
    case .ratio16x9:
      return "9:16"
    case .ratio5x4:
      return "4:5"
    case .auto, .free, .square:
      return displayName
    }
  }

  func targetRatio(
    for foregroundSize: CGSize,
    orientation: AspectRatioOrientation = .horizontal
  ) -> CGFloat? {
    let baseRatio: CGFloat?
    switch self {
    // Ratio Auto эталона не держит пропорцию снимка: Padding добавляет равные поля
    // со всех сторон, 800×450 и Padding 300 дают 1400×1050 (ANN-287, ANN-793).
    case .auto, .free:
      baseRatio = nil
    case .square:
      baseRatio = 1
    case .ratio4x3:
      baseRatio = 4.0 / 3.0
    case .ratio16x9:
      baseRatio = 16.0 / 9.0
    case .ratio3x2:
      baseRatio = 3.0 / 2.0
    case .ratio5x4:
      baseRatio = 5.0 / 4.0
    }

    guard let baseRatio else { return nil }
    if supportsOrientation, orientation == .vertical {
      return 1 / baseRatio
    }
    return baseRatio
  }

  func canvasSize(
    for foregroundSize: CGSize,
    padding: CGFloat,
    alignmentSpace: CGFloat,
    orientation: AspectRatioOrientation = .horizontal
  ) -> CGSize {
    let normalizedWidth = max(foregroundSize.width, 1)
    let normalizedHeight = max(foregroundSize.height, 1)
    let minimumWidth = normalizedWidth + max(padding, 0) * 2 + max(alignmentSpace, 0)
    let minimumHeight = normalizedHeight + max(padding, 0) * 2 + max(alignmentSpace, 0)

    guard let targetRatio = targetRatio(
      for: CGSize(width: normalizedWidth, height: normalizedHeight),
      orientation: orientation
    ),
      targetRatio > 0 else {
      return CGSize(width: minimumWidth, height: minimumHeight)
    }

    let minimumRatio = minimumWidth / minimumHeight
    if minimumRatio < targetRatio {
      return CGSize(width: minimumHeight * targetRatio, height: minimumHeight)
    }

    return CGSize(width: minimumWidth, height: minimumWidth / targetRatio)
  }
}

/// Пункт popup Ratio панели Background. Порядок и подписи – как в эталоне:
/// Auto, 1 : 1, 5 : 4, 4 : 3, 3 : 2, 16 : 9, разделитель, 4 : 5, 3 : 4, 9 : 16.
nonisolated enum AnnotateBackgroundRatioChoice: String, CaseIterable, Identifiable, Sendable {
  case auto
  case square
  case ratio5x4
  case ratio4x3
  case ratio3x2
  case ratio16x9
  case ratio4x5
  case ratio3x4
  case ratio9x16

  var id: String {
    rawValue
  }

  /// Горизонтальная группа до разделителя.
  static let landscapeChoices: [AnnotateBackgroundRatioChoice] = [.auto, .square, .ratio5x4, .ratio4x3, .ratio3x2, .ratio16x9]
  /// Вертикальная группа после разделителя.
  static let portraitChoices: [AnnotateBackgroundRatioChoice] = [.ratio4x5, .ratio3x4, .ratio9x16]

  var title: String {
    switch self {
    case .auto: AnnotateBackgroundPanelStrings.ratioAuto
    case .square: "1 : 1"
    case .ratio5x4: "5 : 4"
    case .ratio4x3: "4 : 3"
    case .ratio3x2: "3 : 2"
    case .ratio16x9: "16 : 9"
    case .ratio4x5: "4 : 5"
    case .ratio3x4: "3 : 4"
    case .ratio9x16: "9 : 16"
    }
  }

  var option: AspectRatioOption {
    switch self {
    case .auto: .auto
    case .square: .square
    case .ratio5x4, .ratio4x5: .ratio5x4
    case .ratio4x3, .ratio3x4: .ratio4x3
    case .ratio3x2: .ratio3x2
    case .ratio16x9, .ratio9x16: .ratio16x9
    }
  }

  var orientation: AspectRatioOrientation {
    switch self {
    case .ratio4x5, .ratio3x4, .ratio9x16: .vertical
    default: .horizontal
    }
  }

  /// Пункт для текущей пары option + orientation. Free и 2 : 3 из старых пресетов
  /// в popup эталона нет, для них возвращается nil.
  init?(option: AspectRatioOption, orientation: AspectRatioOrientation) {
    let isVertical = option.supportsOrientation && orientation == .vertical
    switch option {
    case .auto: self = .auto
    case .free: return nil
    case .square: self = .square
    case .ratio5x4: self = isVertical ? .ratio4x5 : .ratio5x4
    case .ratio4x3: self = isVertical ? .ratio3x4 : .ratio4x3
    case .ratio3x2:
      guard !isVertical else { return nil }
      self = .ratio3x2
    case .ratio16x9: self = isVertical ? .ratio9x16 : .ratio16x9
    }
  }
}

/// Скругление холста. Слайдер Corners эталона 0…60, при 60 экспорт снимка 800×450 даёт
/// непрерывный (continuous) угол радиусом ≈135 pt: серый снимка на верхней кромке
/// начинается в 150–162 px от угла (spec-063-live/b4-ref-exp-bg-corners.png, ANN-289).
/// Зависимость от размера снимка не замерялась, пересчёт линейный.
nonisolated enum AnnotateBackgroundCorners {
  static let sliderRange: ClosedRange<CGFloat> = 0 ... 60
  static let radiusPerSliderUnit: CGFloat = 2.25

  /// Радиус угла в пунктах снимка для значения слайдера.
  static func radius(forSlider value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 0 }
    return max(0, value) * radiusPerSliderUnit
  }

  /// Силуэт с непрерывным углом, как RoundedRectangle(style: .continuous) в превью.
  static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
    let clamped = min(max(radius, 0), min(rect.width, rect.height) / 2)
    guard clamped > 0 else { return CGPath(rect: rect, transform: nil) }
    return RoundedRectangle(cornerRadius: clamped, style: .continuous).path(in: rect).cgPath
  }
}

/// Тень холста эталона на Shadow 100 (прозрачный фон, spec-063-live/b4-ref-exp-bg-shadowT.png):
/// под нижним краем альфа 203, на 30 px 166, на 100 px 94, на 150 px 58, хвост ≈250 px,
/// сверху на 10 px всего 40. Профиль раскладывается на два чёрных гауссовых слоя со
/// смещением вниз (ANN-288). Непрозрачность слоёв пропорциональна слайдеру.
nonisolated enum AnnotateCanvasShadowProfile {
  struct Layer: Equatable {
    /// Непрозрачность слоя на Shadow 100.
    let opacity: CGFloat
    /// Сигма гауссова размытия в пунктах снимка.
    let sigma: CGFloat
    /// Смещение вниз в пунктах снимка.
    let offsetY: CGFloat
  }

  static let layers: [Layer] = [
    Layer(opacity: 0.79, sigma: 102.6, offsetY: 90),
    Layer(opacity: 0.48, sigma: 17.3, offsetY: 23),
  ]

  /// Насколько тень выходит за силуэт: 3σ широкого слоя плюс его смещение.
  static let extent: CGFloat = 400

  /// setShadow Core Graphics: blur ≈ 2,2 σ (замер профиля тени на растре).
  static let coreGraphicsBlurPerSigma: CGFloat = 2.2
}
