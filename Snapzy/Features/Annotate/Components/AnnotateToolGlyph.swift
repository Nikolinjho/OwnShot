import SwiftUI

enum OwnShotEditorChrome {
  static func color(_ rgb: UInt32) -> Color {
    Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
      green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
  }

  static func nsColor(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255, alpha: alpha)
  }

  /// Акцент темы эталона (spec-066 R04, решение C1): в кадрах raw #CE4745 в светлой
  /// и raw #EC5F5D в тёмной теме, это sRGB #E0383E и #FF5257
  /// (spec-063-live/ref-bottombar-active-on-808080.png – Save as… #CE4745,
  /// spec-050-visual/dark/editor-idle-on-000000.png – Save as… #EC5F5D, b3r-text-ref-1.png – каретка).
  /// Выбранный инструмент сюда не относится: его капсула одна в обеих темах (R05).
  static let lightAccentRGB: UInt32 = 0xE0383E
  static let darkAccentRGB: UInt32 = 0xFF5257

  static func accentRGB(for scheme: ColorScheme) -> UInt32 {
    scheme == .dark ? darkAccentRGB : lightAccentRGB
  }

  static func accent(for scheme: ColorScheme) -> Color {
    color(accentRGB(for: scheme))
  }

  /// Тот же акцент для AppKit: подстраивается под оформление вида, где рисуется.
  static let accentNSColor = NSColor(name: "OwnShotEditorAccent") { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return nsColor(isDark ? darkAccentRGB : lightAccentRGB)
  }

  /// Неактивное окно гасит акценты в серый (spec-066 R14, решение C2):
  /// spec-063-live/ref-bottombar-inactive-on-808080.png и
  /// spec-051-pairs/reference-{light,dark}/editor-inactive-on-000000.png.
  /// Основная кнопка: #BFBFBF / #545251, текст остаётся белым.
  static let inactiveLightPrimaryButtonRGB: UInt32 = 0xBFBFBF
  static let inactiveDarkPrimaryButtonRGB: UInt32 = 0x545251
  /// Выбранный инструмент: капсула #C0C0C0 с глифом #606060 / #656463 с глифом #C9C9C8.
  static let inactiveLightSelectedToolRGB: UInt32 = 0xC0C0C0
  static let inactiveLightSelectedGlyphRGB: UInt32 = 0x606060
  static let inactiveDarkSelectedToolRGB: UInt32 = 0x656463
  static let inactiveDarkSelectedGlyphRGB: UInt32 = 0xC9C9C8
  /// Глифы невыбранных инструментов группы в неактивном окне светлеют: #191919 → #787878,
  /// #E5E5E5 → #BBBBBB. Кнопки захвата и нижней панели при этом не меняются (R15).
  static let inactiveLightToolGlyphRGB: UInt32 = 0x787878
  static let inactiveDarkToolGlyphRGB: UInt32 = 0xBBBBBB

  /// Разделители группы инструментов (R18): 1×14 pt, чёрный 10 % в светлой теме
  /// (#ADADAD на #C0C0C0) и белый 10 % в тёмной (#4B4A49 на #373635),
  /// spec-050-visual/{light,dark}/editor-idle-on-000000.png, шаг 36 pt.
  static let toolSeparatorSize = CGSize(width: 1, height: 14)
  static let toolSeparatorOpacity: Double = 0.1
  /// Наведённая ячейка – нейтральная капсула: чёрный 7 % (#C0C0C0 → #B3B3B3) и белый 7 %
  /// (#373635 → #454443), spec-050-visual/*/editor-hover-tool-on-000000.png (N07).
  static let toolHoverOpacity: Double = 0.07

  static func toolSeparatorColor(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(toolSeparatorOpacity) : Color.black.opacity(toolSeparatorOpacity)
  }

  static func toolHoverColor(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(toolHoverOpacity) : Color.black.opacity(toolHoverOpacity)
  }

  /// Разделитель перед ячейкой `index` виден, только если ни она, ни левая соседка
  /// не выбраны и не под указателем (R18). У первой ячейки разделителя нет.
  static func showsToolSeparator(beforeIndex index: Int, selectedIndex: Int?, hoveredIndex: Int?) -> Bool {
    guard index > 0 else { return false }
    let hidden: Set<Int?> = [selectedIndex, hoveredIndex]
    return !hidden.contains(index) && !hidden.contains(index - 1)
  }
}

/// Свои кнопки редактора фокус клавиатуры не берут: у эталона `acceptsFirstResponder = false`
/// у 15 классов кнопок, фокус получают только числовые и Hex-поля (spec-066 R37, focus.md §7).
struct OwnShotNonFocusableControl: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.focusable(false).focusEffectDisabled()
    } else {
      content.focusable(false)
    }
  }
}

extension View {
  func ownShotNonFocusable() -> some View {
    modifier(OwnShotNonFocusableControl())
  }
}

struct OwnShotEditorCapsule: ViewModifier {
  var isActive = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.controlActiveState) private var controlActiveState

  func body(content: Content) -> some View {
    if colorScheme == .dark {
      // Активная панель полупрозрачна: белый 20 % на фоне #BEBEBE даёт #696968, как у эталона.
      // Неактивная панель непрозрачна #292726, тот же белый 20 % на ней – #545251.
      content.background(controlActiveState == .inactive
        ? OwnShotEditorChrome.color(0x545251)
        : Color.white.opacity(AnnotateEditorBarMetrics.darkControlWhiteOpacity), in: Capsule())
    } else {
      content.liquidGlassControl(isActive: isActive, in: Capsule(),
        showsRestingSurface: true, activeGlassTint: nil)
    }
  }
}

struct AnnotateToolGlyph: View {
  let tool: AnnotationToolType

  var body: some View {
    if let resourceName {
      OwnShotSymbols.image(resourceName).renderingMode(.template)
    } else {
      Image(systemName: tool.icon)
    }
  }

  private var resourceName: String? {
    switch tool {
    case .selection: "annotateCursorTool"
    case .rectangle: "annotateRectangleTool"
    case .filledRectangle: "annotateFilledRectangleTool"
    case .oval: "annotateEllipseTool"
    case .line: "annotateLineTool"
    case .arrow: "annotateArrowTool"
    case .text: "annotateTextTool"
    case .blur: "annotatePixelateTool"
    case .spotlight: "annotateHighlightTool"
    case .counter: "annotateCounterTool"
    case .pencil: "annotateDrawTool"
    case .highlighter: "annotateDrawHighlightTool"
    default: nil
    }
  }
}

struct AnnotateCaptureGlyph: View {
  enum Kind {
    case crop, addImage, background

    var accessibilityLabel: String {
      switch self {
      case .crop: "Crop & Resize"
      case .addImage: "Add screenshot"
      case .background: "Add background"
      }
    }
  }
  let kind: Kind

  var body: some View {
    OwnShotSymbols.image(resourceName).renderingMode(.template).accessibilityHidden(true)
  }

  private var resourceName: String {
    switch kind {
    case .crop: "annotateCrop"
    case .addImage: "annotateAddImageButton"
    case .background: "annotateFrameTool"
    }
  }
}
