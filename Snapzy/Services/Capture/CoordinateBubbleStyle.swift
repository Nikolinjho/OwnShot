//
//  CoordinateBubbleStyle.swift
//  Snapzy
//
//  Shared visual style for the small coordinate "bubble" tooltips shown during area
//  selection — used by both `AreaSelectionOverlayView` (plain area screenshot) and
//  `InlineAreaMagnifierHostView` (screenshot-and-annotate's coordinate bubble). Kept in one
//  place so the two entry points can't drift out of sync with each other. Matches Snapzy's
//  existing, near-native presentation (transparent background, dark text, a hairline white
//  shadow for legibility) per maintainer feedback on #466 to stay close to the built-in macOS
//  screenshot tool's look, rather than the solid dark pill this used to be.
//

import AppKit

enum CoordinateBubbleStyle {
  static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
  static let textColor = NSColor(white: 0.05, alpha: 1.0)
  static let backgroundColor = NSColor.clear
  static let cornerRadius: CGFloat = 4
  static let horizontalInset: CGFloat = 4
  static let verticalInset: CGFloat = 2
  static let shadowColor = NSColor.white
  /// Светлая копия цифр сдвинута вправо-вниз (R26). На кадрах эталона при размере указателя
  /// 2,09 сдвиг 5 px = 2,5 pt, белый ≈85 % (spec-063-live/ref-area-open-cursor.png,
  /// spec-062-live/ref-capture-area-cursor.png). Здесь – значение для обычного размера указателя,
  /// подпись умножает его на свой масштаб.
  static let shadowOffset = CGSize(width: 1.2, height: -1.2)
  static let shadowRadius: CGFloat = 0.1
  static let shadowOpacity: Float = 0.85

  /// Смещение цифр от центра прицела при обычном размере указателя: по X до левого края цифр,
  /// по Y вниз до их верха. На тех же кадрах при размере 2,09 это 31 px и 14 px, то есть
  /// ≈15,5 pt и ≈7 pt (R26). Подпись умножает смещение на свой масштаб.
  static let labelOffset = CGSize(width: 7.4, height: 3.35)

  /// Ключ размера указателя в «Универсальном доступе» (1 – обычный размер).
  static let cursorSizePreferenceKey = "mouseDriverCursorSize"
  static let cursorSizePreferenceDomain = "com.apple.universalaccess"
  static let maximumCursorScale: CGFloat = 4

  /// Шрифт подписи координат с учётом масштаба: у эталона цифры растут вместе с курсором.
  static func font(scale: CGFloat) -> NSFont {
    let scale = normalizedScale(scale)
    return scale == 1 ? font : NSFont.systemFont(ofSize: font.pointSize * scale, weight: .medium)
  }

  /// Масштаб системного курсора из настройки «Размер указателя».
  static func systemCursorScale() -> CGFloat {
    cursorScale(fromPreference: CFPreferencesCopyAppValue(
      cursorSizePreferenceKey as CFString,
      cursorSizePreferenceDomain as CFString
    ))
  }

  /// Разбор значения настройки: всё нечисловое и меньше 1 – обычный размер, сверху предел системы.
  static func cursorScale(fromPreference value: Any?) -> CGFloat {
    guard let number = value as? NSNumber else { return 1 }
    return normalizedScale(CGFloat(number.doubleValue))
  }

  /// Масштаб подписи координат. Эталон рисует цифры рядом с курсором-прицелом, и они растут
  /// вместе с ним (R26). Прицел теперь один и тот же во всех режимах (тёмный системный крест),
  /// поэтому и подпись масштабируется одинаково. При лупе подпись скрыта, координаты в её панели.
  static func coordinateLabelScale(crosshairMode: OwnShotCrosshairMode, cursorScale: CGFloat) -> CGFloat {
    normalizedScale(cursorScale)
  }

  private static func normalizedScale(_ scale: CGFloat) -> CGFloat {
    guard scale.isFinite else { return 1 }
    return min(max(scale, 1), maximumCursorScale)
  }
}

/// Прицел и затемнение оверлея захвата по кадрам эталона (R24, R26).
enum OwnShotCrosshairStyle {
  /// Затемнение вне выделения – чёрный 50 % (множитель яркости 0,476–0,502).
  static let dimAlpha: CGFloat = 0.5
  /// Чёрная линия прицела 1 pt (#000–#0E0E0E на кадрах).
  static let lineColor = NSColor.black
  static let lineWidth: CGFloat = 1
  /// Белый ореол ≈18 % по 2 pt с каждой стороны линии (80 → 110 и 44 → 84 на кадрах).
  static let haloColor = NSColor.white.withAlphaComponent(0.18)
  static let haloWidth: CGFloat = 2
}
